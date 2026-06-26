import Foundation

/// clash_api 访问助手：本进程启动时生成一次随机 secret，写入内核配置（experimental.clash_api.secret），
/// 所有对 clash_api 的请求都带上 `Authorization: Bearer <secret>`。
/// 防止本机其它进程（含恶意软件）直接读流量/连接、甚至切换节点。
enum ClashAPI {
    /// 每次启动随机生成，仅本进程与它拉起的内核知道。无需持久化。
    nonisolated static let secret = UUID().uuidString

    /// 构造带鉴权头的请求。
    nonisolated static func request(_ url: URL, timeout: TimeInterval? = nil) -> URLRequest {
        var req = timeout.map { URLRequest(url: url, timeoutInterval: $0) } ?? URLRequest(url: url)
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// clash_api 配置块（写入内核配置用）。
    nonisolated static func config(port: Int) -> [String: Any] {
        ["external_controller": "127.0.0.1:\(port)", "secret": secret]
    }

    /// 向系统申请一个空闲 TCP 端口（bind 到 127.0.0.1:0 让内核分配后读回）；失败回退 19090。
    /// close 到内核 bind 之间有极小 TOCTOU 窗口，但内核会立即占用——远胜固定端口：
    /// 固定 9090 会与其它 Clash 系客户端（ClashX / Verge / Mihomo 默认的 external-controller）确定性相撞 → bind 失败 FATAL。
    nonisolated static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 19090 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 19090 }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { return 19090 }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
