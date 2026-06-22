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
    private(set) var live = false                 // true=来自运行中内核的实时数据；false=离线读订阅持久化结构
    private(set) var testing: Set<String> = []   // 正在测速的组名

    /// 用户对各分组的手动选择（groupName → 成员 tag）。持久化：离线也能选，
    /// 且作为 makeConfig 里 selector 的 default —— 内核（重）启动后即生效、跨重启不丢。
    private(set) var overrides: [String: String] = [:]
    private static var overridesURL: URL { KernelPaths.supportDir.appendingPathComponent("group-selections.json") }

    private init() { loadOverrides() }

    private func loadOverrides() {
        guard let data = try? Data(contentsOf: Self.overridesURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        overrides = dict
    }

    private func setOverride(_ group: String, _ member: String) {
        overrides[group] = member
        try? FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(overrides) {
            try? data.write(to: Self.overridesURL, options: .atomic)
        }
    }

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
            loadPersisted()   // 内核没跑：展示订阅持久化的分组结构（无延迟、不可切换）
            return
        }
        guard let raw = await Self.fetchProxies(port: port) else { return }  // 内核刚起、clash_api 未应答：保留现状不清空
        // 顺序只在首屏按内核出站顺序（= 订阅定义顺序）定一次，之后固定，不每帧重排
        let order = (raw["GLOBAL"] as? [String: Any])?["all"] as? [String] ?? []
        applyKeepingOrder(Self.parse(raw), firstLoadOrder: order)
        live = true
        loaded = true
    }

    /// 把新解析的分组并入现有列表：顺序一旦确定就固定。首屏按 firstLoadOrder 排一次；
    /// 之后轮询只就地更新内容、新增排末尾、消失的移除——不再排序，省开销也不闪动。
    private func applyKeepingOrder(_ fresh: [Group], firstLoadOrder order: [String]) {
        let next: [Group]
        if groups.isEmpty {
            next = Self.orderGroups(fresh, by: order)
        } else {
            let byName = Dictionary(fresh.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            var merged = groups.compactMap { byName[$0.name] }                 // 维持现有顺序
            let existing = Set(groups.map(\.name))
            let newOnes = fresh.filter { !existing.contains($0.name) }         // 新增的按定义顺序接在末尾（parse 本身无序）
            merged += Self.orderGroups(newOnes, by: order)
            next = merged
        }
        if next != groups { groups = next }
    }

    /// 离线加载：从「选中订阅」已转换落盘的 proxy-groups（subrules/<id>/route.json）构建分组结构。
    /// 复用 KernelRunner 的 nodeOutbounds/groupOutbounds（与 makeConfig 同一套），保证成员名与运行态一致。
    func loadPersisted() {
        guard let sub = SubscriptionStore.shared.selectedSubscription, !sub.nodes.isEmpty,
              let r = ClashRuleImport.importedRoute(dir: SubscriptionStore.subrulesDir(sub.id)),
              !r.groups.isEmpty else {
            if !groups.isEmpty { groups = [] }
            live = false; loaded = true
            return
        }
        let (nodeOuts, nameToTag) = KernelRunner.nodeOutbounds(sub.nodes)
        let nodeTags = nodeOuts.compactMap { $0["tag"] as? String }
        let groupOuts = KernelRunner.groupOutbounds(r.groups, allNodeTags: nodeTags, nameToTag: nameToTag, overrides: overrides)
        let parsed = Self.parsePersisted(groupOuts)
        if parsed != groups { groups = parsed }
        live = false; loaded = true
    }

    /// 把 groupOutbounds 产出的 selector/url-test 出站字典解析成 Group（离线：无延迟，now 取 default/首个）。
    nonisolated private static func parsePersisted(_ groupOuts: [[String: Any]]) -> [Group] {
        let groupTags = Set(groupOuts.compactMap { $0["tag"] as? String })
        let result: [Group] = groupOuts.compactMap { o in
            guard let tag = o["tag"] as? String, let type = (o["type"] as? String)?.lowercased() else { return nil }
            let kind: Group.Kind = (type == "selector") ? .selector : .urltest
            let memberTags = (o["outbounds"] as? [String]) ?? []
            let now = (o["default"] as? String) ?? memberTags.first ?? ""
            let members = memberTags.map { Member(name: $0, delay: nil, isGroup: groupTags.contains($0)) }
            return Group(name: tag, kind: kind, now: now, members: members)
        }
        return result   // groupOuts 已是 route.json 里 r.groups 的定义顺序，保持不动
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
        return result   // 不在此排序：顺序由 refresh 首屏定一次后固定（见 applyKeepingOrder）
    }

    /// 按给定顺序（内核出站顺序 = 订阅 proxy-groups 定义顺序）排列分组；不在表中的稳定排末尾。
    nonisolated private static func orderGroups(_ groups: [Group], by order: [String]) -> [Group] {
        guard !order.isEmpty else { return groups }
        var index: [String: Int] = [:]
        for (i, tag) in order.enumerated() where index[tag] == nil { index[tag] = i }
        return groups.enumerated().sorted {
            let ia = index[$0.element.name] ?? Int.max
            let ib = index[$1.element.name] ?? Int.max
            return ia != ib ? ia < ib : $0.offset < $1.offset
        }.map(\.element)
    }

    // MARK: 切换 selector

    func select(_ group: Group, _ member: String) async {
        guard group.kind == .selector, group.now != member else { return }
        setOverride(group.name, member)                          // 持久化选择（离线也记住，配置生成时作 selector default）
        if let i = groups.firstIndex(where: { $0.id == group.id }) {
            groups[i].now = member                               // 立即反映
        }
        if live {
            _ = await Self.put(port: port, group: group.name, name: member)   // 内核在跑：运行时立即切换
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
