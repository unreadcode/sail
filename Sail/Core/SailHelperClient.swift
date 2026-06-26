import Foundation

/// 与特权 helper 通信的 UDS 客户端。所有阻塞 socket I/O 都在专用后台队列，绝不上 main（防沙滩球）。
/// enum + 静态方法，无实例/无闭包捕获 self → 不存在 ARC 强引用环。
enum SailHelperClient {
    static let socketPath = "/var/run/com.unreadcode.Sail.helper.sock"
    private static let queue = DispatchQueue(label: "com.unreadcode.Sail.helper.ipc")

    // MARK: 公开命令

    static func ping() async -> Bool {
        (await request(["cmd": "ping"]))?["ok"] as? Bool == true
    }

    /// 已安装 helper 的自身版本；旧版（不认识 version 命令）返回 nil。
    static func helperVersion() async -> String? {
        let r = await request(["cmd": "version"])
        guard r?["ok"] as? Bool == true else { return nil }
        return r?["version"] as? String
    }

    static func kernelRunning() async -> Bool {
        let r = await request(["cmd": "status"])
        return (r?["ok"] as? Bool == true) && (r?["running"] as? Bool == true)
    }

    /// 让 helper 以 root 起内核。返回 (是否成功, 错误信息)。
    static func startKernel(config: String) async -> (Bool, String?) {
        guard let r = await request(["cmd": "start", "config": config]) else { return (false, "无法连接 helper") }
        if r["ok"] as? Bool == true { return (true, nil) }
        return (false, r["error"] as? String ?? "未知错误")
    }

    static func stopKernel() async -> Bool {
        (await request(["cmd": "stop"]))?["ok"] as? Bool == true
    }

    /// 同步停内核：仅供 app 退出收尾（applicationWillTerminate 不能 await，可短暂阻塞）。
    /// 在调用线程做一次带 6s 超时的 socket 往返，确保 root TUN 内核被停掉。
    static func stopKernelSync() {
        _ = sendSync(["cmd": "stop"])
    }

    // MARK: 底层

    /// 后台队列发请求、读一行响应；任何路径都 close(fd)。
    private static func request(_ obj: [String: Any]) async -> [String: Any]? {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: sendSync(obj)) }
        }
    }

    private static func sendSync(_ obj: [String: Any]) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }   // FD 必关，所有退出路径

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                _ = socketPath.withCString { strncpy(dst, $0, cap - 1) }
            }
        }
        // 读写超时，避免卡死拖住后台队列
        var tv = timeval(tv_sec: 6, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connected == 0 else { return nil }

        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        data.append(0x0A)   // 换行结尾，helper 按行读
        // 循环写满：UDS SOCK_STREAM 的单次 write 不保证写全。startKernel 把整份 config JSON 塞进来，
        // 大机场订阅（几百节点）可达数十~上百 KB，发送缓冲一满就短写 → 旧代码 wrote != count 直接判失败
        // → TUN 静默起不来。这里按偏移循环写完，被信号打断(EINTR)重试，超时/出错(EAGAIN 等)才失败。
        let ok = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var off = 0
            while off < raw.count {
                let n = write(fd, base + off, raw.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        guard ok else { return nil }

        // 读一行响应（响应很小，4KB 足够）
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(buf[0..<n]))) as? [String: Any]
    }
}
