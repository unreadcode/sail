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
}
