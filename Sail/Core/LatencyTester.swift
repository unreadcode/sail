import Foundation
import Observation

/// 节点延迟测试。两条路径：
/// - 热路径：测「当前选中节点」且主内核在跑时，直接用运行中内核的 clash_api（连接已温）；
/// - 冷路径：其余情况临时起一个带相关节点 + clash_api 的 sing-box 实例（独立进程/端口/无入站）。
/// 两条路径都对 /proxies/{tag}/delay 连测多次取最小，规避冷启动握手把数值拉高。
@MainActor
@Observable
final class LatencyTester {
    static let shared = LatencyTester()

    enum Result: Equatable, Sendable {
        case testing
        case ok(Int)   // 毫秒
        case timeout
    }

    /// key = node.outboundJSON（稳定标识）
    private(set) var results: [String: Result] = [:]
    private(set) var running = false

    // 连通性探测地址：Cloudflare 比 gstatic 更普遍可达（不少节点连不上 www.gstatic.com → 测速全超时）
    private let testURL = "http://cp.cloudflare.com/generate_204"

    private init() {}

    func result(for node: ProxyNode) -> Result? { results[node.outboundJSON] }

    func testAll(_ nodes: [ProxyNode]) async { await runTest(nodes) }
    func testOne(_ node: ProxyNode) async { await runTest([node]) }

    // MARK: 自动延迟检查

    private var autoTask: Task<Void, Never>?

    /// 按设置开关与间隔，周期性自动测当前订阅的节点延迟。
    func restartAuto() {
        autoTask?.cancel()
        autoTask = nil
        guard SettingsStore.shared.autoLatencyCheck else { return }
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = max(10, SettingsStore.shared.latencyIntervalSec)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { break }
                let nodes = SubscriptionStore.shared.selectedSubscription?.nodes ?? []
                if !nodes.isEmpty, !self.running { await self.testAll(nodes) }
            }
        }
    }

    private func runTest(_ nodes: [ProxyNode]) async {
        guard !running, !nodes.isEmpty else { return }
        running = true
        defer { running = false }

        for node in nodes { results[node.outboundJSON] = .testing }
        let timeoutMs = SettingsStore.shared.latencyTimeoutMs

        // 热路径：只测「当前选中节点」且主内核正在运行时，直接用运行中内核的 clash_api
        // （连接是温的，不必另起实例），测多次取最小，结果更接近 Clash Verge。
        if nodes.count == 1,
           KernelRunner.shared.isRunning,
           SubscriptionStore.shared.isSelected(nodes[0]) {
            let res = await Self.delayBest(tag: "proxy", port: TrafficMonitor.apiPort, testURL: testURL, timeoutMs: timeoutMs)
            results[nodes[0].outboundJSON] = res
            return
        }

        // 冷路径：组装临时配置，每个节点 tag = n{i} + clash_api（无入站）
        var outbounds: [[String: Any]] = []
        for (i, node) in nodes.enumerated() {
            guard let data = node.outboundJSON.data(using: .utf8),
                  var ob = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            ob["tag"] = "n\(i)"
            outbounds.append(ob)
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        // 每次申请一个空闲端口：固定端口会在连续测速（手动+自动）时与上一实例撞，导致 clash_api 起不来 → 全部误报超时。
        let apiPort = Self.freePort()
        let config: [String: Any] = [
            "log": ["level": "error"],
            // 测速 URL 解析按配置策略（默认 ipv4_only）：否则可能解析到 AAAA、
            // 经代理走 IPv6 连不通而一直等到超时。
            "dns": ["strategy": SettingsStore.shared.dnsStrategy],
            "outbounds": outbounds,
            "experimental": ["clash_api": ClashAPI.config(port: apiPort)],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: config) else {
            markTimeout(nodes); return
        }
        let cfgURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sail-latency-\(UUID().uuidString).json")
        do { try data.write(to: cfgURL) } catch { markTimeout(nodes); return }
        defer { try? FileManager.default.removeItem(at: cfgURL) }

        let proc = Process()
        proc.executableURL = KernelPaths.binary
        proc.arguments = ["run", "-c", cfgURL.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { markTimeout(nodes); return }
        defer {
            proc.terminate()
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            proc.waitUntilExit()   // 回收进程，确保端口释放、不留僵尸，避免影响下一次测速
        }

        // 等 clash_api 就绪（最多 ~3s）
        var ready = false
        for _ in 0..<20 {
            if await Self.apiReady(port: apiPort) { ready = true; break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard ready else { markTimeout(nodes); return }

        // 并发测速（限并发，避免一次性打满）
        let port = apiPort, url = testURL
        await withTaskGroup(of: (Int, Result).self) { group in
            var next = 0
            let limit = min(8, nodes.count)
            func schedule() {
                guard next < nodes.count else { return }
                let i = next; next += 1
                group.addTask { (i, await Self.delayBest(tag: "n\(i)", port: port, testURL: url, timeoutMs: timeoutMs)) }
            }
            for _ in 0..<limit { schedule() }
            for await (i, res) in group {
                results[nodes[i].outboundJSON] = res
                schedule()
            }
        }
    }

    private func markTimeout(_ nodes: [ProxyNode]) {
        for node in nodes { results[node.outboundJSON] = .timeout }
    }

    /// 向系统申请一个空闲 TCP 端口（bind 到 0 让内核分配后读回）。
    /// 失败则回退 19090。close 到内核 bind 之间有极小 TOCTOU 窗口，但临时内核会立即占用，远胜固定端口。
    nonisolated private static func freePort() -> Int {
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

    // MARK: - clash_api 调用（后台）

    /// 专用会话：显式绕过系统代理，否则连接中（系统代理已指向 Sail）时，
    /// 对本地 clash_api 的请求会被塞进代理而全部失败。
    nonisolated private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
        ]
        return URLSession(configuration: cfg)
    }()

    nonisolated private static func apiReady(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/version") else { return false }
        let req = ClashAPI.request(url, timeout: 2)
        guard let (_, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    /// 连测次数，取最小值：第一发常含冷启动握手，后几发连接已温。
    nonisolated private static let tries = 3

    /// 连测多次取最小值；一旦某次超时/失败就停止（避免 N×超时的漫长等待）。
    nonisolated private static func delayBest(tag: String, port: Int, testURL: String, timeoutMs: Int) async -> Result {
        var best: Int?
        for _ in 0..<tries {
            if case .ok(let ms) = await delay(tag: tag, port: port, testURL: testURL, timeoutMs: timeoutMs) {
                best = min(best ?? ms, ms)
            } else {
                break   // 超时/失败不再重试
            }
        }
        if let best { return .ok(best) }
        return .timeout
    }

    nonisolated private static func delay(tag: String, port: Int, testURL: String, timeoutMs: Int) async -> Result {
        let encoded = testURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? testURL
        let tagEnc = tag.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tag
        guard let url = URL(string: "http://127.0.0.1:\(port)/proxies/\(tagEnc)/delay?timeout=\(timeoutMs)&url=\(encoded)") else {
            return .timeout
        }
        let req = ClashAPI.request(url, timeout: Double(timeoutMs) / 1000 + 3)
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = obj["delay"] as? Int else {
            return .timeout
        }
        return .ok(ms)
    }
}
