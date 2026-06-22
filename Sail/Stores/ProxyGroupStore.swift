import Foundation
import Observation

/// 代理分组（出站 selector / url-test）的运行态：从内核 clash_api `/proxies` 读取，
/// selector 组支持手动切换（PUT /proxies/{group}），整组可一键测速（/proxies/{member}/delay）。
/// 分组本身由订阅的 proxy-groups 在规则模式 + 开启「应用订阅自带规则」时生成（见 ClashRuleImport / KernelRunner）。
@MainActor
@Observable
final class ProxyGroupStore {
    static let shared = ProxyGroupStore()

    struct Member: Identifiable, Equatable {
        let name: String
        var delay: Int?        // 最近一次延迟（ms）；nil = 未知 / 超时
        let isGroup: Bool      // 成员本身是不是另一个组（嵌套）
        var id: String { name }
    }

    struct Group: Identifiable, Equatable {
        enum Kind: Equatable { case selector, urltest }
        let name: String
        let kind: Kind
        var now: String        // 当前生效成员
        var members: [Member]
        var id: String { name }
    }

    private(set) var groups: [Group] = []
    private(set) var loaded = false
    private(set) var testing: Set<String> = []   // 正在测速的组名

    private init() {}

    private var port: Int { TrafficMonitor.apiPort }

    /// 本地 clash_api 不能走系统代理（否则请求被塞进 Sail 自己），显式绕过。
    nonisolated private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
        ]
        return URLSession(configuration: cfg)
    }()

    // MARK: 拉取

    func refresh() async {
        guard KernelRunner.shared.isRunning else {
            if !groups.isEmpty { groups = [] }
            loaded = true
            return
        }
        guard let raw = await Self.fetchProxies(port: port) else { return }
        let parsed = Self.parse(raw)
        if parsed != groups { groups = parsed }   // 内容不变就不触发重排（轮询时常态）
        loaded = true
    }

    nonisolated private static func fetchProxies(port: Int) async -> [String: Any]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/proxies") else { return nil }
        let req = ClashAPI.request(url, timeout: 4)
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = obj["proxies"] as? [String: Any] else { return nil }
        return proxies
    }

    nonisolated private static func parse(_ proxies: [String: Any]) -> [Group] {
        func lastDelay(_ name: String) -> Int? {
            guard let p = proxies[name] as? [String: Any],
                  let hist = p["history"] as? [[String: Any]],
                  let d = hist.last?["delay"] as? Int, d > 0 else { return nil }
            return d
        }
        func isGroup(_ name: String) -> Bool {
            guard let p = proxies[name] as? [String: Any],
                  let t = (p["type"] as? String)?.lowercased() else { return false }
            return ["selector", "urltest", "fallback", "loadbalance"].contains(t)
        }
        var result: [Group] = []
        for (name, v) in proxies {
            guard name != "GLOBAL",
                  let p = v as? [String: Any],
                  let typeStr = (p["type"] as? String)?.lowercased() else { continue }
            let kind: Group.Kind
            switch typeStr {
            case "selector": kind = .selector
            case "urltest", "fallback", "loadbalance": kind = .urltest
            default: continue
            }
            let all = (p["all"] as? [String]) ?? []
            let members = all.map { Member(name: $0, delay: lastDelay($0), isGroup: isGroup($0)) }
            result.append(Group(name: name, kind: kind, now: (p["now"] as? String) ?? "", members: members))
        }
        // selector（可手动切）排前，其余按名称稳定排序
        return result.sorted { a, b in
            if (a.kind == .selector) != (b.kind == .selector) { return a.kind == .selector }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: 切换 selector

    func select(_ group: Group, _ member: String) async {
        guard group.kind == .selector, group.now != member else { return }
        if await Self.put(port: port, group: group.name, name: member),
           let i = groups.firstIndex(where: { $0.id == group.id }) {
            groups[i].now = member   // 立即反映，随后 refresh 再校准
        }
        await refresh()
    }

    nonisolated private static func put(port: Int, group: String, name: String) async -> Bool {
        let enc = group.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? group
        guard let url = URL(string: "http://127.0.0.1:\(port)/proxies/\(enc)") else { return false }
        var req = ClashAPI.request(url, timeout: 5)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        guard let (_, resp) = try? await session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        return code == 204 || code == 200
    }

    // MARK: 整组测速

    func testGroup(_ group: Group) async {
        guard !testing.contains(group.name) else { return }
        testing.insert(group.name)
        defer { testing.remove(group.name) }

        let timeout = SettingsStore.shared.latencyTimeoutMs
        let names = group.members.map(\.name)
        let port = self.port
        let results: [String: Int?] = await withTaskGroup(of: (String, Int?).self) { tg in
            for n in names { tg.addTask { (n, await Self.delay(port: port, name: n, timeoutMs: timeout)) } }
            var acc: [String: Int?] = [:]
            for await r in tg { acc[r.0] = r.1 }
            return acc
        }
        if let gi = groups.firstIndex(where: { $0.id == group.id }) {
            for mi in groups[gi].members.indices where results[groups[gi].members[mi].name] != nil {
                groups[gi].members[mi].delay = results[groups[gi].members[mi].name] ?? nil
            }
        }
        await refresh()   // url-test 组测速后会自动改 now，刷新拿到最新选择
    }

    nonisolated private static func delay(port: Int, name: String, timeoutMs: Int) async -> Int? {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        let testURL = "http://www.gstatic.com/generate_204"
        let urlEnc = testURL.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? testURL
        guard let url = URL(string: "http://127.0.0.1:\(port)/proxies/\(enc)/delay?timeout=\(timeoutMs)&url=\(urlEnc)") else { return nil }
        let req = ClashAPI.request(url, timeout: Double(timeoutMs) / 1000 + 3)
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ms = obj["delay"] as? Int else { return nil }
        return ms
    }
}
