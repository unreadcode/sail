// Sail 特权 helper（LaunchDaemon 以 root 拉起）。
// 唯一职责：受控地以 root 起/停内置 sing-box，替代 setuid。绝不执行调用方传来的任意命令。
// 安全要点：
//  - UDS socket 落在 /var/run，chown 给「安装时记录的那个用户」、0600 → 仅该用户可连；
//  - 每个连接再用 getpeereid 复核调用方 uid；
//  - 只运行 root-only 路径下、且属主为 root 的 sing-box；配置由 helper 写到 root-only 路径（不读用户可写的）。
import Foundation
import os

let kHelperVersion = "5"   // helper 自身版本：改 helper 行为时 +1，app 据此判旧并自动重装（5：fd CLOEXEC + storePID 时序）
let kSocketPath = "/var/run/com.unreadcode.Sail.helper.sock"
let kSupportDir = "/Library/Application Support/Sail"
let kSingBoxPath = kSupportDir + "/sing-box"      // root 所有的可信副本
let kConfigPath  = kSupportDir + "/config.run.json"
let kLogPath     = kSupportDir + "/kernel.log"    // 内核输出（0644，app 端 tail 读）
let kLogMaxBytes: Int64 = 5 << 20                 // 单文件超过 5MB 即轮转（rename 到 .1，重开新文件）

// 允许的调用方 uid，由 plist 的 --uid 传入
var allowedUID: uid_t = {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--uid"), i + 1 < a.count, let u = UInt32(a[i + 1]) { return u }
    return 0
}()

// 当前 sing-box 子进程 pid，用极短临界区的 unfair lock 保护：只在读/写的一瞬持锁，
// 绝不在 SIGTERM 等待等阻塞操作期间持锁 → 看门狗线程永不被命令执行(start/stop)阻塞。
let pidLock = OSAllocatedUnfairLock(initialState: pid_t(0))
func loadPID() -> pid_t { pidLock.withLock { $0 } }
func storePID(_ p: pid_t) { pidLock.withLock { $0 = p } }
/// 仅当当前值仍是 expected 时清零（避免把刚启动的新内核 pid 误清）。
func clearPID(ifEqual expected: pid_t) { pidLock.withLock { if $0 == expected { $0 = 0 } } }

func elog(_ s: String) { FileHandle.standardError.write(Data(("sail-helper: " + s + "\n").utf8)) }

/// 安装时记录的那个用户(allowedUID)是否仍有名为 "Sail" 的进程在跑。
/// 查询失败一律返回 true（保守：绝不因查询出错而误停用户正在用的内核）。
func isOwnerAlive() -> Bool {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: allowedUID)]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return true }
    let stride = MemoryLayout<kinfo_proc>.stride
    var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 1)
    var got = size + stride
    guard sysctl(&mib, 4, &buf, &got, nil, 0) == 0 else { return true }
    for i in 0..<(got / stride) {
        var p = buf[i].kp_proc
        let name = withUnsafePointer(to: &p.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        if name == "Sail" { return true }
    }
    return false
}

/// 内核日志唯一写入者。sing-box 的 stdout/stderr 经管道汇到这里、由 helper 独占写入 kernel.log，
/// 因此轮转可安全地「rename + 重开自己的 fd」——不存在原来「两个写入者竞争截断」的 race。
final class LogWriter {
    static let shared = LogWriter()
    private struct State { var fd: Int32 = -1; var written: Int64 = 0 }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private func reopen(_ s: inout State, truncate: Bool) {
        if s.fd >= 0 { close(s.fd); s.fd = -1 }
        let flags = O_WRONLY | O_CREAT | O_APPEND | (truncate ? O_TRUNC : 0)
        let fd = open(kLogPath, flags, 0o644)
        guard fd >= 0 else { return }
        chmod(kLogPath, 0o644)   // app（安装者）需可读
        s.fd = fd
        var st = stat()
        s.written = truncate ? 0 : (stat(kLogPath, &st) == 0 ? st.st_size : 0)
    }

    /// 内核启动时调用：开一份全新（截断）日志。
    func reset() { lock.withLock { reopen(&$0, truncate: true) } }

    /// 追加一段内核输出；超过上限就轮转（rename 到 .1，重开新文件）。全程持锁串行，多个排空线程并存也安全。
    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.withLock { s in
            if s.fd < 0 { reopen(&s, truncate: false) }
            guard s.fd >= 0 else { return }
            bytes.withUnsafeBytes { _ = write(s.fd, $0.baseAddress, $0.count) }
            s.written += Int64(bytes.count)
            if s.written > kLogMaxBytes {
                close(s.fd); s.fd = -1
                rename(kLogPath, kLogPath + ".1")   // 覆盖旧 .1，仅留一份备份
                reopen(&s, truncate: true)
            }
        }
    }
}

// MARK: 起 / 停 sing-box（root）

func reapIfExited() {
    let pid = loadPID()
    guard pid > 0 else { return }
    var status: Int32 = 0
    if waitpid(pid, &status, WNOHANG) == pid { clearPID(ifEqual: pid) }
}

/// 停内核：读 pid（瞬时持锁）→ kill + 等待退出（全程不持锁）→ 清 pid（瞬时持锁）。
/// 阻塞的等待循环不在锁内，故不会卡住看门狗或其它命令。
func stopSingBox() {
    let pid = loadPID()
    guard pid > 0 else { return }
    kill(pid, SIGTERM)
    var status: Int32 = 0
    var exited = false
    for _ in 0..<30 { if waitpid(pid, &status, WNOHANG) == pid { exited = true; break }; usleep(100_000) }
    if !exited { kill(pid, SIGKILL); waitpid(pid, &status, 0) }
    clearPID(ifEqual: pid)
}

func startSingBox(_ configJSON: String) -> (Bool, String) {
    // 可信二进制必须存在且属主为 root —— 杜绝「用户换二进制再骗授权」
    var st = stat()
    guard stat(kSingBoxPath, &st) == 0 else { return (false, "内核未安装到特权目录") }
    guard st.st_uid == 0 else { return (false, "内核二进制非 root 所有，拒绝") }
    // 配置写到 root-only 路径
    try? FileManager.default.createDirectory(atPath: kSupportDir, withIntermediateDirectories: true)
    guard (try? configJSON.write(toFile: kConfigPath, atomically: true, encoding: .utf8)) != nil else {
        return (false, "写配置失败")
    }
    chown(kConfigPath, 0, 0); chmod(kConfigPath, 0o600)

    stopSingBox()

    // 内核 stdout/stderr 接管道，由 helper 独占写日志（避免「内核 + helper 同时写一个文件」的截断 race）。
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return (false, "建管道失败") }
    let readFD = fds[0], writeFD = fds[1]
    // 管道两端标 CLOEXEC：file_actions 已在本次子进程里 dup 到 1/2 后关掉它们（dup 后的 1/2 不带 CLOEXEC，日志照常），
    // 这里再防「后续/并发 spawn 误继承旧管道 fd」。
    fcntl(readFD, F_SETFD, FD_CLOEXEC)
    fcntl(writeFD, F_SETFD, FD_CLOEXEC)

    LogWriter.shared.reset()   // 每次启动开一份全新日志

    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_adddup2(&fa, writeFD, 1)   // stdout → 管道写端
    posix_spawn_file_actions_adddup2(&fa, writeFD, 2)   // stderr → 同一管道
    posix_spawn_file_actions_addclose(&fa, readFD)      // 子进程不读管道
    posix_spawn_file_actions_addclose(&fa, writeFD)     // 原始写端已 dup 到 1/2，关掉
    defer { posix_spawn_file_actions_destroy(&fa) }

    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] =
        [strdup(kSingBoxPath), strdup("run"), strdup("-c"), strdup(kConfigPath), nil]
    defer { for p in argv where p != nil { free(p) } }
    let rc = posix_spawn(&pid, kSingBoxPath, &fa, nil, argv, environ)
    // 紧跟 spawn 成功立刻记录 pid（在 close(writeFD) 之前），把「子进程已在跑但 helper 仍以为 pid=0」的窗口压到最小：
    // 该窗口内若看门狗判属主离线触发 stopSingBox，会因 loadPID()==0 直接返回、漏杀这刚起的 root 内核成孤儿。
    if rc == 0 { storePID(pid) }
    close(writeFD)   // 父进程必须关掉写端，否则子进程退出后读端永远等不到 EOF
    guard rc == 0 else { close(readFD); return (false, "spawn 失败(\(rc))") }

    // 排空线程：读管道 → 写日志。子进程关闭写端(退出) → read 返回 0(EOF) → 线程结束。
    Thread.detachNewThread {
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(readFD, &buf, buf.count)
            if n <= 0 { break }
            LogWriter.shared.append(Array(buf[0..<n]))
        }
        close(readFD)
    }
    return (true, "")
}

// MARK: 请求处理

func handle(_ line: String) -> String {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cmd = obj["cmd"] as? String else { return "{\"ok\":false,\"error\":\"bad request\"}\n" }
    switch cmd {
    case "ping":
        return "{\"ok\":true}\n"
    case "version":
        return "{\"ok\":true,\"version\":\"\(kHelperVersion)\"}\n"
    case "status":
        reapIfExited(); let running = loadPID() > 0
        return "{\"ok\":true,\"running\":\(running)}\n"
    case "stop":
        stopSingBox()
        return "{\"ok\":true}\n"
    case "start":
        let cfg = obj["config"] as? String ?? ""
        guard !cfg.isEmpty else { return "{\"ok\":false,\"error\":\"empty config\"}\n" }
        // 严格校验：必须是合法 JSON 对象，畸形数据直接拒（也避免把垃圾喂给 sing-box）
        guard let d = cfg.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: d)) is [String: Any] else {
            return "{\"ok\":false,\"error\":\"invalid config json\"}\n"
        }
        let (ok, err) = startSingBox(cfg)
        return ok ? "{\"ok\":true}\n" : "{\"ok\":false,\"error\":\"\(err)\"}\n"
    default:
        return "{\"ok\":false,\"error\":\"unknown cmd\"}\n"
    }
}

// MARK: CLI 版本查询
// app 用 `sail-helper --version` 问内置 helper 的版本（与装着的对比判旧），故必须在起 socket 服务前先应答并退出。
// 这让 kHelperVersion 成为版本号的唯一来源：app 不再手写期望值，杜绝两处漂移导致每次启动重装弹密码。
if CommandLine.arguments.contains("--version") {
    print(kHelperVersion)
    exit(0)
}

// MARK: socket 服务

signal(SIGPIPE, SIG_IGN)

unlink(kSocketPath)
let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard listenFD >= 0 else { elog("socket() 失败"); exit(1) }
fcntl(listenFD, F_SETFD, FD_CLOEXEC)   // 别让 posix_spawn 起的 root 内核继承这个特权监听 socket

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutablePointer(to: &addr.sun_path) { p in
    p.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) { dst in
        _ = kSocketPath.withCString { strncpy(dst, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }
    }
}
let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
let bindOK = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, addrLen) }
}
guard bindOK == 0 else { elog("bind() 失败"); exit(1) }
// 仅安装时记录的那个用户可连
chown(kSocketPath, allowedUID, 0)
chmod(kSocketPath, 0o600)
guard listen(listenFD, 8) == 0 else { elog("listen() 失败"); exit(1) }
elog("就绪，allowedUID=\(allowedUID)")

// 后台线程：看门狗——属主 Sail 退出/被强杀就停内核，避免 root TUN 残留占路由表 → 整机断网。
// （日志轮转已由 LogWriter 在写入时处理，看门狗不再管日志。）accept 阻塞主循环，故独立线程。
Thread.detachNewThread {
    var ownerMissing = 0   // 连续判定属主不在的次数
    while true {
        sleep(2)
        // 看门狗不持有任何跨阻塞操作的锁：reapIfExited/loadPID/stopSingBox 内部各自只瞬时持 pidLock，
        // isOwnerAlive 是纯 sysctl 不持锁。故命令端的阻塞（如 stop 的 SIGTERM 等待）永不卡住看门狗。
        reapIfExited()
        if loadPID() > 0 {
            if isOwnerAlive() {
                ownerMissing = 0
            } else {
                ownerMissing += 1
                // ~6s 宽限：避开 Sail「退出→立刻重开」的瞬断，避免误停
                if ownerMissing >= 3 {
                    elog("属主 Sail 已退出，停止内核（撤 TUN）")
                    stopSingBox()
                    ownerMissing = 0
                }
            }
        } else {
            ownerMissing = 0
        }
    }
}

while true {
    let conn = accept(listenFD, nil, nil)
    if conn < 0 { continue }
    defer { close(conn) }   // 任何分支退出本次迭代都关闭连接 FD，杜绝泄露
    fcntl(conn, F_SETFD, FD_CLOEXEC)   // 处理 start 命令时起的内核不应继承这条客户端连接
    // 复核调用方 uid（socket 0600 已限到该用户，这里再核一道）
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(conn, &uid, &gid) == 0, uid == allowedUID else {
        elog("拒绝非法调用方 uid"); continue
    }
    // 读超时，防卡死的客户端拖住单线程守护进程
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    // 累积读到换行；上限 4MB（大配置也够，且挡住无限灌数据的 DoS）
    let maxReq = 4 << 20
    var reqData = [UInt8](); reqData.reserveCapacity(8192)
    var chunk = [UInt8](repeating: 0, count: 8192)
    var newlineAt: Int? = nil
    while reqData.count < maxReq {
        let n = read(conn, &chunk, chunk.count)
        if n <= 0 { break }   // 0=对端关闭，<0=超时/错误
        if let j = chunk[0..<n].firstIndex(of: 0x0A) { newlineAt = reqData.count + j }  // 只扫新块 → O(n)
        reqData.append(contentsOf: chunk[0..<n])
        if newlineAt != nil { break }
    }
    guard let nl = newlineAt else { continue }   // 无完整请求（超时/超限/截断）→ 丢弃
    let line = String(decoding: reqData[0..<nl], as: UTF8.self)
    let resp = handle(line.trimmingCharacters(in: .whitespacesAndNewlines))
    _ = resp.withCString { write(conn, $0, strlen($0)) }
}
