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
        let wrote = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base, raw.count)
        }
        guard wrote == data.count else { return nil }

        // 读一行响应（响应很小，4KB 足够）
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(buf[0..<n]))) as? [String: Any]
    }
}
