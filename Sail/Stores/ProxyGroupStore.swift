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
        var proto: String = "" // 协议类型（tuic/anytls/vless… 小写）；组成员为空
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

    /// 用户对各分组的手动选择，**按订阅分别记忆**（subID → {groupName: 成员 tag}）。
    /// 持久化：离线也能选、跨重启不丢、切回原订阅恢复其选择，且作为 makeConfig 里 selector 的 default。
    private var overridesBySub: [String: [String: String]] = [:]
    private static var overridesURL: URL { KernelPaths.supportDir.appendingPathComponent("group-selections.json") }

    /// 当前选中订阅的分组选择（makeConfig/groupOutbounds 与各处读取用）。
    var overrides: [String: String] { overridesBySub[subKey] ?? [:] }
    private var subKey: String { SubscriptionStore.shared.selectedSubscriptionID?.uuidString ?? "default" }

    /// 原本是 url-test（自动）的组名（来自订阅 route.json）。手动固定后 clash_api 会把它报成 selector，
    /// 靠这个集合才知道它「本可自动」，从而给出「恢复自动」。按订阅缓存，订阅变了才重算。
    private(set) var autoGroups: Set<String> = []
    private var autoGroupsSubID: UUID?

    private func updateAutoGroupsIfNeeded() {
        let sid = SubscriptionStore.shared.selectedSubscriptionID
        guard sid != autoGroupsSubID else { return }
        autoGroupsSubID = sid
        guard let sub = SubscriptionStore.shared.selectedSubscription,
              let r = ClashRuleImport.importedRoute(dir: SubscriptionStore.subrulesDir(sub.id)) else { autoGroups = []; return }
        autoGroups = Set(r.groups.compactMap { ($0["type"] as? String) == "urltest" ? $0["tag"] as? String : nil })
    }

    /// 某组是否「被手动固定的自动组」（可恢复自动）。
    func isPinnedAuto(_ name: String) -> Bool { autoGroups.contains(name) && overrides[name] != nil }

    private init() { loadOverrides() }

    private func loadOverrides() {
        guard let data = try? Data(contentsOf: Self.overridesURL) else { return }
        if let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            overridesBySub = dict                                   // 新格式：按订阅
        } else if let flat = try? JSONDecoder().decode([String: String].self, from: data) {
            overridesBySub["default"] = flat                        // 旧格式迁移到 default 桶
        }
    }

    private func setOverride(_ group: String, _ member: String) {
        overridesBySub[subKey, default: [:]][group] = member
        saveOverrides()
    }

    private func clearOverride(_ group: String) {
        overridesBySub[subKey]?[group] = nil
        saveOverrides()
    }

    private func saveOverrides() {
        try? FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(overridesBySub) {
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
        updateAutoGroupsIfNeeded()
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
        // 节点 tag → 协议类型（离线时给成员标协议）
        var protoByTag: [String: String] = [:]
        for o in nodeOuts {
            if let t = o["tag"] as? String, let p = (o["type"] as? String)?.lowercased() { protoByTag[t] = p }
        }
        let groupOuts = KernelRunner.groupOutbounds(r.groups, allNodeTags: nodeTags, nameToTag: nameToTag, overrides: overrides)
        let parsed = Self.parsePersisted(groupOuts, protoByTag: protoByTag)
        if parsed != groups { groups = parsed }
        live = false; loaded = true
    }

    /// 把 groupOutbounds 产出的 selector/url-test 出站字典解析成 Group（离线：无延迟，now 取 default/首个）。
    nonisolated private static func parsePersisted(_ groupOuts: [[String: Any]], protoByTag: [String: String]) -> [Group] {
        let groupTags = Set(groupOuts.compactMap { $0["tag"] as? String })
        let result: [Group] = groupOuts.compactMap { o in
            guard let tag = o["tag"] as? String, let type = (o["type"] as? String)?.lowercased() else { return nil }
            let kind: Group.Kind = (type == "selector") ? .selector : .urltest
            let memberTags = (o["outbounds"] as? [String]) ?? []
            let now = (o["default"] as? String) ?? memberTags.first ?? ""
            let members = memberTags.map { Member(name: $0, delay: nil, isGroup: groupTags.contains($0), proto: protoByTag[$0] ?? "") }
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
        let nonProto: Set<String> = ["selector", "urltest", "fallback", "loadbalance", "direct", "block", "dns", "reject"]
        func isGroup(_ name: String) -> Bool {
            guard let p = proxies[name] as? [String: Any],
                  let t = (p["type"] as? String)?.lowercased() else { return false }
            return ["selector", "urltest", "fallback", "loadbalance"].contains(t)
        }
        func protoOf(_ name: String) -> String {   // 协议类型（组/特殊出站返回空）
            guard let p = proxies[name] as? [String: Any],
                  let t = (p["type"] as? String)?.lowercased(), !nonProto.contains(t) else { return "" }
            return t
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
            let members = all.map { Member(name: $0, delay: lastDelay($0), isGroup: isGroup($0), proto: protoOf($0)) }
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
        guard group.now != member else { return }
        setOverride(group.name, member)                          // 持久化选择（离线也记住，配置生成时作 selector default）
        if let i = groups.firstIndex(where: { $0.id == group.id }) {
            groups[i].now = member                               // 立即反映
        }
        if group.kind == .selector {
            if live { _ = await Self.put(port: port, group: group.name, name: member) }   // selector：运行时即时切，无需重启
        } else {
            // url-test：sing-box 不支持手动切 → 持久化选择后重启，makeConfig 会把该组退化成 selector 固定此节点
            await KernelRunner.shared.restartIfConfigChanged()
        }
        await refresh()
    }

    /// 把某个被手动固定的自动组恢复为「按延迟自动选择」：清掉持久化选择并重启应用。
    func resetToAuto(_ group: Group) async {
        guard overrides[group.name] != nil else { return }
        clearOverride(group.name)
        await KernelRunner.shared.restartIfConfigChanged()
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

        // 内核没跑：测速不需要主内核——把成员映射回订阅节点，走 LatencyTester 冷路径（临时实例）。
        guard live else { await testGroupOffline(group); return }

        let timeout = SettingsStore.shared.latencyTimeoutMs
        let names = group.members.map(\.name)
        let port = self.port
        let results: [String: Int?] = await withTaskGroup(of: (String, Int?).self) { tg in
            for n in names { tg.addTask { (n, await Self.delayBest(port: port, name: n, timeoutMs: timeout)) } }
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

    /// 内核未运行时的整组测速：成员 tag → 订阅节点（嵌套组成员跳过），交给 LatencyTester
    /// 冷路径（独立临时 sing-box 实例测、与主内核无关），完成后把延迟写回成员。
    private func testGroupOffline(_ group: Group) async {
        guard let sub = SubscriptionStore.shared.selectedSubscription, !sub.nodes.isEmpty else { return }
        let tagToNode = Self.tagToNodeMap(sub.nodes)
        // 真实节点成员（非嵌套组）才能直接测；保留 tag→node 以便写回。
        let pairs = group.members.compactMap { m -> (tag: String, node: ProxyNode)? in
            guard !m.isGroup, let n = tagToNode[m.name] else { return nil }
            return (m.name, n)
        }
        guard !pairs.isEmpty else { return }
        await LatencyTester.shared.testAll(pairs.map(\.node))
        guard let gi = groups.firstIndex(where: { $0.id == group.id }) else { return }
        for (tag, node) in pairs {
            guard let mi = groups[gi].members.firstIndex(where: { $0.name == tag }) else { continue }
            switch LatencyTester.shared.result(for: node) {
            case .ok(let ms): groups[gi].members[mi].delay = ms
            case .timeout:    groups[gi].members[mi].delay = nil
            default: break
            }
        }
    }

    /// 重建「成员 tag → 节点」映射，与 KernelRunner.nodeOutbounds 的取 tag/去重逻辑完全一致，
    /// 保证离线成员名能对回正确的节点。
    nonisolated private static func tagToNodeMap(_ nodes: [ProxyNode]) -> [String: ProxyNode] {
        var map: [String: ProxyNode] = [:]
        var used = Set<String>()
        for node in nodes {
            guard let data = node.outboundJSON.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else { continue }
            let base = node.label.isEmpty ? "node" : node.label
            var tag = base, i = 2
            while used.contains(tag) { tag = "\(base) \(i)"; i += 1 }
            used.insert(tag)
            map[tag] = node
        }
        return map
    }

    /// 连测 3 次取最小（与单节点/离线一致）：首发常含冷启动握手，取最小更接近真实延迟。超时即止。
    nonisolated private static func delayBest(port: Int, name: String, timeoutMs: Int) async -> Int? {
        var best: Int?
        for _ in 0..<3 {
            guard let ms = await delay(port: port, name: name, timeoutMs: timeoutMs) else { break }
            best = min(best ?? ms, ms)
        }
        return best
    }

    nonisolated private static func delay(port: Int, name: String, timeoutMs: Int) async -> Int? {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        let testURL = "http://cp.cloudflare.com/generate_204"   // Cloudflare 更普遍可达，gstatic 不少节点连不上
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
