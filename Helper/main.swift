// Sail 特权 helper（LaunchDaemon 以 root 拉起）。
// 唯一职责：受控地以 root 起/停内置 sing-box，替代 setuid。绝不执行调用方传来的任意命令。
// 安全要点：
//  - UDS socket 落在 /var/run，chown 给「安装时记录的那个用户」、0600 → 仅该用户可连；
//  - 每个连接再用 getpeereid 复核调用方 uid；
//  - 只运行 root-only 路径下、且属主为 root 的 sing-box；配置由 helper 写到 root-only 路径（不读用户可写的）。
import Foundation

let kSocketPath = "/var/run/com.unreadcode.Sail.helper.sock"
let kSupportDir = "/Library/Application Support/Sail"
let kSingBoxPath = kSupportDir + "/sing-box"      // root 所有的可信副本
let kConfigPath  = kSupportDir + "/config.run.json"
let kLogPath     = kSupportDir + "/kernel.log"    // 内核输出（0644，app 端 tail 读）
let kLogMaxBytes: Int64 = 5 << 20                 // 日志超过 5MB 即裁剪
let kLogKeepBytes: UInt64 = 1 << 20               // 裁剪后保留尾部 1MB

// 允许的调用方 uid，由 plist 的 --uid 传入
var allowedUID: uid_t = {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--uid"), i + 1 < a.count, let u = UInt32(a[i + 1]) { return u }
    return 0
}()

var childPID: pid_t = 0   // 当前 sing-box 子进程

func elog(_ s: String) { FileHandle.standardError.write(Data(("sail-helper: " + s + "\n").utf8)) }

/// 日志封顶：超过上限只保留尾部，原地 truncate + 回写（不换 inode，内核 O_APPEND 继续写新末尾）。
func trimLogIfNeeded() {
    var st = stat()
    guard stat(kLogPath, &st) == 0, st.st_size > kLogMaxBytes else { return }
    guard let rh = FileHandle(forReadingAtPath: kLogPath) else { return }
    try? rh.seek(toOffset: UInt64(st.st_size) - kLogKeepBytes)
    let tail = (try? rh.readToEnd()) ?? Data()
    try? rh.close()
    guard let wh = FileHandle(forWritingAtPath: kLogPath) else { return }
    try? wh.truncate(atOffset: 0)
    try? wh.write(contentsOf: tail)
    try? wh.close()
}

// MARK: 起 / 停 sing-box（root）

func reapIfExited() {
    guard childPID > 0 else { return }
    var status: Int32 = 0
    if waitpid(childPID, &status, WNOHANG) == childPID { childPID = 0 }
}

func stopSingBox() {
    guard childPID > 0 else { return }
    kill(childPID, SIGTERM)
    var status: Int32 = 0
    for _ in 0..<30 { if waitpid(childPID, &status, WNOHANG) == childPID { childPID = 0; return }; usleep(100_000) }
    kill(childPID, SIGKILL)
    waitpid(childPID, &status, 0)
    childPID = 0
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

    // 预建日志文件并设为用户可读，把内核 stdout/stderr 重定向进去（app 端 tail 显示）
    let lfd = open(kLogPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if lfd >= 0 { close(lfd) }
    chmod(kLogPath, 0o644)
    var fa: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fa)
    posix_spawn_file_actions_addopen(&fa, 1, kLogPath, O_WRONLY | O_APPEND, 0)
    posix_spawn_file_actions_adddup2(&fa, 1, 2)   // stderr 并入同一文件
    defer { posix_spawn_file_actions_destroy(&fa) }

    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] =
        [strdup(kSingBoxPath), strdup("run"), strdup("-c"), strdup(kConfigPath), nil]
    defer { for p in argv where p != nil { free(p) } }
    let rc = posix_spawn(&pid, kSingBoxPath, &fa, nil, argv, environ)
    guard rc == 0 else { return (false, "spawn 失败(\(rc))") }
    childPID = pid
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
    case "status":
        reapIfExited()
        return "{\"ok\":true,\"running\":\(childPID > 0)}\n"
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

// MARK: socket 服务

signal(SIGPIPE, SIG_IGN)

unlink(kSocketPath)
let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard listenFD >= 0 else { elog("socket() 失败"); exit(1) }

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

// 后台定期裁剪日志，防长时间运行写爆磁盘（accept 阻塞主循环，故用独立线程）
Thread.detachNewThread { while true { sleep(30); trimLogIfNeeded() } }

while true {
    let conn = accept(listenFD, nil, nil)
    if conn < 0 { continue }
    defer { close(conn) }   // 任何分支退出本次迭代都关闭连接 FD，杜绝泄露
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
