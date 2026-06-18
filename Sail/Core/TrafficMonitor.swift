import Foundation
import Observation

/// 通过内核 clash_api 的流式接口读取实时流量 / 连接数 / 内存。
/// 仅在内核运行时工作；用绕过系统代理的会话访问本地 api。
@MainActor
@Observable
final class TrafficMonitor {
    static let shared = TrafficMonitor()
    static let apiPort = 9090
    static let historyLen = 48

    private(set) var up = 0.0          // 字节/秒
    private(set) var down = 0.0
    private(set) var totalUp = 0.0     // 累计字节
    private(set) var totalDown = 0.0
    private(set) var memory = 0.0
    private(set) var connections = 0
    private(set) var connectionList: [Conn] = []   // 实时连接明细（连接管理页消费）
    private(set) var history: [Double] = Array(repeating: 0, count: historyLen)

    private var tasks: [Task<Void, Never>] = []

    private init() {}

    /// 单条连接（来自 clash_api /connections 帧）。
    struct Conn: Identifiable, Equatable {
        let id: String
        let host: String        // 目标 host:port（无 host 时用 IP）
        let network: String     // tcp / udp
        let type: String        // 入站类型，如 mixed/tun
        let process: String     // 进程名（可能为空）
        let chain: String       // 出站链，如 proxy
        let rule: String        // 命中的路由规则
        let upload: Double
        let download: Double
        let start: Date?
    }

    func start() {
        stop()
        tasks = [
            Task { await self.stream("/traffic") { [weak self] o in
                guard let self else { return }
                self.down = (o["down"] as? Double) ?? 0
                self.up = (o["up"] as? Double) ?? 0
                self.history = Array(self.history.dropFirst()) + [self.down]
            }},
            // /connections 一帧里同时带累计上/下行与内存，无需再单开 /memory、/traffic 之外的流
            Task { await self.stream("/connections") { [weak self] o in
                guard let self else { return }
                self.totalDown = (o["downloadTotal"] as? Double) ?? self.totalDown
                self.totalUp = (o["uploadTotal"] as? Double) ?? self.totalUp
                let raw = (o["connections"] as? [[String: Any]]) ?? []
                self.connections = raw.count
                self.connectionList = Self.parse(raw)
                // 内存每秒一帧、且因 Go GC 持续 ±0.1MB 抖动 → 前端一位小数会一直闪。
                // 仅当变化超过阈值（0.5MB）才更新，滤掉 GC 噪声，稳住显示。
                if let mem = o["memory"] as? Double, abs(mem - self.memory) >= 512 * 1024 {
                    self.memory = mem
                }
            }},
        ]
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        up = 0; down = 0; totalUp = 0; totalDown = 0; memory = 0; connections = 0
        connectionList = []
        history = Array(repeating: 0, count: Self.historyLen)
    }

    // MARK: 关闭连接

    /// 关闭单条连接。
    func close(_ id: String) { deleteConnection(id) }
    /// 关闭全部连接。
    func closeAll() { deleteConnection(nil) }

    private func deleteConnection(_ id: String?) {
        let path = id.map { "/connections/\($0)" } ?? "/connections"
        guard let url = URL(string: "http://127.0.0.1:\(Self.apiPort)\(path)") else { return }
        var req = ClashAPI.request(url)
        req.httpMethod = "DELETE"
        Task { _ = try? await Self.session.data(for: req) }
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parse(_ raw: [[String: Any]]) -> [Conn] {
        raw.map { c in
            let m = c["metadata"] as? [String: Any] ?? [:]
            let host = (m["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (m["destinationIP"] as? String) ?? "—"
            let port = (m["destinationPort"] as? String) ?? ""
            let proc = (m["processPath"] as? String).map { ($0 as NSString).lastPathComponent }
                ?? (m["process"] as? String) ?? ""
            let chains = (c["chains"] as? [String]) ?? []
            return Conn(
                id: (c["id"] as? String) ?? UUID().uuidString,
                host: port.isEmpty ? host : "\(host):\(port)",
                network: (m["network"] as? String) ?? "",
                type: (m["type"] as? String) ?? "",
                process: proc,
                chain: chains.reversed().joined(separator: " → "),
                rule: (c["rule"] as? String) ?? "",
                upload: (c["upload"] as? Double) ?? 0,
                download: (c["download"] as? Double) ?? 0,
                start: (c["start"] as? String).flatMap { isoParser.date(from: $0) }
            )
        }
    }

    /// 持续读取一个换行分隔 JSON 流；断开自动重连（直到任务取消）。
    private func stream(_ path: String, handle: @escaping ([String: Any]) -> Void) async {
        guard let url = URL(string: "http://127.0.0.1:\(Self.apiPort)\(path)") else { return }
        while !Task.isCancelled {
            do {
                let (bytes, resp) = try await Self.session.bytes(for: ClashAPI.request(url))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if let data = line.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        handle(obj)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1)) // 等内核 api 就绪后重连
            }
        }
    }

    /// 绕过系统代理（连接后系统代理指向 Sail，否则访问本地 api 会被塞进代理）。
    nonisolated private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
        ]
        return URLSession(configuration: cfg)
    }()
}
