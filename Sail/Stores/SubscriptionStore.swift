import Foundation
import Observation

/// 一条订阅：名称 + 链接 + 解析出的节点 + 机场返回的流量/到期信息。
struct Subscription: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
    var nodes: [ProxyNode] = []
    var updatedAt: Date?
    var lastError: String?

    // 抓取参数（对齐 Clash Verge）
    var userAgent: String = "clash-verge/v2.5.0"  // 空 = 用默认 UA 链
    var timeoutSec: Int = 60                       // HTTP 请求超时
    var autoUpdate: Bool = true                    // 允许自动更新
    var updateIntervalMin: Int = 1440              // 更新间隔（分钟）
    var updateViaProxy: Bool = false               // 更新时经内核混合端口拉取（默认直连；内核未运行时自动回退直连）

    // 来自 subscription-userinfo 头（字节）
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0
    var expire: Date?

    var used: Int64 { upload + download }
    var hasTraffic: Bool { total > 0 }
    var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

/// 抓取结果：节点 + 机场用量信息 + 远端名称（Content-Disposition 文件名）。
struct SubFetchResult {
    var nodes: [ProxyNode]
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0
    var expire: TimeInterval = 0
    var remoteName: String?
    var clashText: String?   // 原始 Clash YAML（用于导入订阅自带 rules/rule-providers）
}

/// 订阅存储：增删改查 + 抓取解析 + 持久化到 <应用支持目录>/Sail/subscriptions.json。
@MainActor
@Observable
final class SubscriptionStore {
    static let shared = SubscriptionStore()

    private(set) var subscriptions: [Subscription] = []
    private(set) var busyIDs: Set<UUID> = []
    /// 当前选中（用于内核出站）的节点；按 outboundJSON 作稳定标识，刷新后仍可匹配。
    private(set) var selectedNode: ProxyNode?
    /// 当前选中的订阅 ID（决定首页节点列表的范围）。
    private(set) var selectedSubscriptionID: UUID?
    /// 每个订阅上次选中的节点（subID → outboundJSON）；「使用」时据此恢复。
    private(set) var lastNodeBySub: [UUID: String] = [:]

    private var fileURL: URL { KernelPaths.supportDir.appendingPathComponent("subscriptions.json") }
    private var selectionURL: URL { KernelPaths.supportDir.appendingPathComponent("selected-node.json") }
    private var subSelectionURL: URL { KernelPaths.supportDir.appendingPathComponent("selected-subscription.json") }
    private var lastNodesURL: URL { KernelPaths.supportDir.appendingPathComponent("last-nodes.json") }

    private init() { load(); loadSelection(); loadSubSelection(); loadLastNodes() }

    var allNodes: [ProxyNode] { subscriptions.flatMap(\.nodes) }

    /// 当前订阅：优先用显式选中的；否则回退到「含当前节点的订阅」；都没有则未选择（nil）。
    var selectedSubscription: Subscription? {
        if let id = selectedSubscriptionID, let s = subscriptions.first(where: { $0.id == id }) { return s }
        if let node = selectedNode, let s = subscriptions.first(where: { $0.nodes.contains(node) }) { return s }
        return nil
    }

    func isBusy(_ id: UUID) -> Bool { busyIDs.contains(id) }

    func isSelected(_ node: ProxyNode) -> Bool { selectedNode?.outboundJSON == node.outboundJSON }

    /// 选中节点；同步把所属订阅记为当前订阅、并记住该订阅的此次选择；运行中则热切换。
    func selectNode(_ node: ProxyNode) async {
        selectedNode = node
        saveSelection()
        if let sub = subscriptions.first(where: { $0.nodes.contains(node) }) {
            selectedSubscriptionID = sub.id
            saveSubSelection()
            lastNodeBySub[sub.id] = node.outboundJSON
            saveLastNodes()
        }
        if KernelRunner.shared.isRunning {
            await KernelRunner.shared.restart()
        }
    }

    /// 使用某订阅：恢复它上次选过的节点；没选过则用第一个。
    func selectSubscription(_ id: UUID) async {
        selectedSubscriptionID = id
        saveSubSelection()
        guard let sub = subscriptions.first(where: { $0.id == id }) else { return }
        let remembered = lastNodeBySub[id].flatMap { json in sub.nodes.first { $0.outboundJSON == json } }
        if let node = remembered ?? sub.nodes.first { await selectNode(node) }
    }

    /// 测速该订阅全部节点，选用延迟最低的可用节点。
    func useFastest(in sub: Subscription) async {
        await LatencyTester.shared.testAll(sub.nodes)
        let results = LatencyTester.shared.results
        var best: (node: ProxyNode, ms: Int)?
        for node in sub.nodes {
            if case .ok(let ms) = results[node.outboundJSON], best == nil || ms < best!.ms {
                best = (node, ms)
            }
        }
        if let best { await selectNode(best.node) }
    }

    // MARK: 动作

    func add(name: String, url: String,
             userAgent: String = "clash-verge/v2.5.0", timeoutSec: Int = 60,
             autoUpdate: Bool = true, updateIntervalMin: Int = 1440, updateViaProxy: Bool = false) async {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // 名称留空 → 抓取后用机场返回的名字，再不行才用「订阅 N」
        var sub = Subscription(name: name.trimmingCharacters(in: .whitespaces), url: trimmedURL)
        sub.userAgent = userAgent.trimmingCharacters(in: .whitespaces)
        sub.timeoutSec = max(5, timeoutSec)
        sub.autoUpdate = autoUpdate
        sub.updateIntervalMin = max(1, updateIntervalMin)
        sub.updateViaProxy = updateViaProxy
        let index = subscriptions.count
        subscriptions.append(sub)
        save()
        await refresh(sub.id, autoNameIndex: index)
    }

    func refresh(_ id: UUID, autoNameIndex: Int? = nil, viaProxy: Bool = false) async {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let url = subscriptions[idx].url
        let ua = subscriptions[idx].userAgent
        let timeout = subscriptions[idx].timeoutSec
        // 「更新(代理)」：经本地混合端口拉取（直连被墙时可用，需内核在运行）
        let proxyPort = (viaProxy && KernelRunner.shared.isRunning) ? SettingsStore.shared.mixedPort : nil
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        do {
            let result = try await Self.fetchNodes(from: url, userAgent: ua, timeoutSec: timeout, proxyPort: proxyPort)
            guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
            // 替换节点前记下：当前选中节点是否来自本订阅（按内容判等）
            let selectedWasHere = selectedNode.map { subscriptions[i].nodes.contains($0) } ?? false
            subscriptions[i].nodes = result.nodes
            subscriptions[i].updatedAt = Date()
            subscriptions[i].lastError = nil
            subscriptions[i].upload = result.upload
            subscriptions[i].download = result.download
            subscriptions[i].total = result.total
            subscriptions[i].expire = result.expire > 0 ? Date(timeIntervalSince1970: result.expire) : nil
            // 名称为空时自动命名：远端名 > 「订阅 N」
            if subscriptions[i].name.isEmpty {
                subscriptions[i].name = result.remoteName ?? "订阅 \(autoNameIndex ?? i)"
            }
            save()
            // 导入订阅自带规则（rules/rule-providers）→ 转 sing-box route 落盘。仅在开关开启时下载转换（联网较重）。
            if SettingsStore.shared.importSubscriptionRules, let yaml = result.clashText {
                await ClashRuleImport.build(yaml: yaml, into: Self.subrulesDir(id), hasProxy: true, proxyPort: proxyPort)
                if KernelRunner.shared.isRunning, selectedSubscriptionID == id || selectedWasHere {
                    await KernelRunner.shared.restart()
                }
            }
            // 选中态对账：选中节点原属本订阅、但刷新后已不存在 → 回退到本订阅第一个（运行中会热切换）
            if selectedWasHere, let sel = selectedNode, !subscriptions[i].nodes.contains(sel),
               let first = subscriptions[i].nodes.first {
                await selectNode(first)
            }
            return
        } catch {
            guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
            subscriptions[i].lastError = (error as? KernelError)?.description ?? error.localizedDescription
            if subscriptions[i].name.isEmpty {
                subscriptions[i].name = "订阅 \(autoNameIndex ?? i)"
            }
        }
        save()
    }

    func refreshAll() async {
        for sub in subscriptions { await refresh(sub.id, viaProxy: sub.updateViaProxy) }
    }

    // MARK: 自动更新

    private var autoUpdateTask: Task<Void, Never>?

    /// 启动自动更新调度：每分钟检查一次，到期且开启自动更新的订阅就刷新（内核在跑则经代理）。
    func startAutoUpdate() {
        autoUpdateTask?.cancel()
        autoUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { break }
                await self.runDueAutoUpdates()
            }
        }
    }

    private func runDueAutoUpdates() async {
        let now = Date()
        for sub in subscriptions where sub.autoUpdate && !isBusy(sub.id) {
            let due = sub.updatedAt.map { now.timeIntervalSince($0) >= Double(sub.updateIntervalMin) * 60 } ?? true
            if due { await refresh(sub.id, viaProxy: sub.updateViaProxy) }
        }
    }

    /// 某订阅的导入规则缓存目录（route.json + rule_set 源文件）。
    nonisolated static func subrulesDir(_ id: UUID) -> URL {
        KernelPaths.supportDir.appendingPathComponent("subrules/\(id.uuidString)", isDirectory: true)
    }

    func remove(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        lastNodeBySub[id] = nil
        saveLastNodes()
        try? FileManager.default.removeItem(at: Self.subrulesDir(id))   // 清理导入规则缓存
        if selectedSubscriptionID == id {
            selectedSubscriptionID = nil
            saveSubSelection()
        }
        // 选中的节点若已不属于任何订阅（其订阅被删）→ 清空，首页回到「未选择」
        if let node = selectedNode, !subscriptions.contains(where: { $0.nodes.contains(node) }) {
            selectedNode = nil
            saveSelection()
            if KernelRunner.shared.isRunning {
                Task { await KernelRunner.shared.restart() }
            }
        }
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        subscriptions[i].name = trimmed
        save()
    }

    /// 编辑订阅信息：名称 / 链接 / 抓取参数（UA、超时、更新间隔、自动更新、是否经内核代理）。链接变更则重新抓取。
    func update(_ id: UUID, name: String, url: String,
                userAgent: String, timeoutSec: Int, autoUpdate: Bool,
                updateIntervalMin: Int, updateViaProxy: Bool) async {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlChanged = !trimmedURL.isEmpty && trimmedURL != subscriptions[i].url
        if !trimmedName.isEmpty { subscriptions[i].name = trimmedName }
        if urlChanged { subscriptions[i].url = trimmedURL }
        subscriptions[i].userAgent = userAgent.trimmingCharacters(in: .whitespaces)
        subscriptions[i].timeoutSec = max(5, timeoutSec)
        subscriptions[i].autoUpdate = autoUpdate
        subscriptions[i].updateIntervalMin = max(1, updateIntervalMin)
        subscriptions[i].updateViaProxy = updateViaProxy
        save()
        if urlChanged { await refresh(id, viaProxy: updateViaProxy) }
    }

    // MARK: 抓取

    /// 不同机场按 UA 决定格式/是否放行/版本门槛。优先用 sing-box UA 拿原生配置
    /// （零转换、节点最全），失败或解析不出再退回较新的 clash-verge UA。
    private static let userAgents = ["sing-box/1.13.0", "clash-verge/v2.5.0"]

    private static func fetchNodes(from urlString: String, userAgent: String, timeoutSec: Int, proxyPort: Int?) async throws -> SubFetchResult {
        // UA：用户指定的优先，再用默认链兜底（去重）
        var uas: [String] = []
        let custom = userAgent.trimmingCharacters(in: .whitespaces)
        if !custom.isEmpty { uas.append(custom) }
        for u in userAgents where !uas.contains(u) { uas.append(u) }
        var lastError: Error = KernelError.message("未解析到节点（暂不支持该订阅格式？）")
        for ua in uas {
            let text: String
            let resp: HTTPURLResponse
            do {
                (text, resp) = try await fetchText(urlString, userAgent: ua, timeoutSec: timeoutSec, proxyPort: proxyPort)
            } catch {
                lastError = error
                continue
            }
            if let nodes = await parse(text, userAgent: ua, timeoutSec: timeoutSec, proxyPort: proxyPort), !nodes.isEmpty {
                var result = SubFetchResult(nodes: nodes)
                applyHeaders(resp, into: &result)
                if ClashYAMLParser.looksLikeClash(text) { result.clashText = text }
                return result
            }
        }
        throw lastError
    }

    /// 解析 subscription-userinfo（流量/到期）与 content-disposition（名称）。
    private static func applyHeaders(_ resp: HTTPURLResponse, into result: inout SubFetchResult) {
        if let info = resp.value(forHTTPHeaderField: "subscription-userinfo") {
            for pair in info.split(whereSeparator: { $0 == ";" || $0 == "," }) {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                let val = Int64(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
                switch key {
                case "upload": result.upload = val
                case "download": result.download = val
                case "total": result.total = val
                case "expire": result.expire = TimeInterval(val)
                default: break
                }
            }
        }
        if let cd = resp.value(forHTTPHeaderField: "content-disposition") {
            result.remoteName = filename(fromContentDisposition: cd)
        }
    }

    /// 从 Content-Disposition 解析文件名：filename*=UTF-8''<percent> 或 filename="..."。
    private static func filename(fromContentDisposition cd: String) -> String? {
        if let range = cd.range(of: "filename*=") {
            var v = String(cd[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let semi = v.firstIndex(of: ";") { v = String(v[..<semi]) }
            // 形如 UTF-8''%E7...
            if let tick = v.range(of: "''") { v = String(v[tick.upperBound...]) }
            return recoverUTF8(v.removingPercentEncoding ?? v)
        }
        if let range = cd.range(of: "filename=") {
            var v = String(cd[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let semi = v.firstIndex(of: ";") { v = String(v[..<semi]) }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return recoverUTF8(v.removingPercentEncoding ?? v)
        }
        return nil
    }

    /// HTTP 头按 Latin-1 解码，若原始是 UTF-8 字节会变乱码；尝试按 Latin-1→UTF-8 还原。
    /// 正常 UTF-8 字符串（含中文）无法编成 Latin-1，会原样返回，故安全。
    private static func recoverUTF8(_ s: String) -> String {
        if let data = s.data(using: .isoLatin1), let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        return s
    }

    /// 依次尝试 base64 分享链接 / 原生 sing-box JSON / Clash YAML（含跟随 provider）。
    private static func parse(_ text: String, userAgent ua: String, timeoutSec: Int, proxyPort: Int?) async -> [ProxyNode]? {
        // 1) base64 / 分享链接
        let shareNodes = ShareLinkParser.parseSubscription(text)
        if !shareNodes.isEmpty { return dedup(shareNodes) }

        // 2) 原生 sing-box JSON 配置（最优）
        if SingBoxConfigParser.looksLikeJSON(text) {
            let sbNodes = SingBoxConfigParser.parseOutbounds(text)
            if !sbNodes.isEmpty { return dedup(sbNodes) }
        }

        // 3) Clash / Clash.Meta YAML（跟随 proxy-providers）
        if ClashYAMLParser.looksLikeClash(text) {
            var nodes = ClashYAMLParser.parseProxies(text)
            for providerURL in ClashYAMLParser.providerURLs(text) {
                if let (providerText, _) = try? await fetchText(providerURL, userAgent: ua, timeoutSec: timeoutSec, proxyPort: proxyPort) {
                    nodes += ClashYAMLParser.parseProxies(providerText)
                }
            }
            let result = dedup(nodes)
            if !result.isEmpty { return result }
        }
        return nil
    }

    private static func fetchText(_ urlString: String, userAgent: String, timeoutSec: Int = 60, proxyPort: Int? = nil) async throws -> (String, HTTPURLResponse) {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            throw KernelError.message("订阅链接无效")
        }
        var req = URLRequest(url: url, timeoutInterval: TimeInterval(max(5, timeoutSec)))
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let session: URLSession
        if let port = proxyPort {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
            session = URLSession(configuration: cfg)
        } else {
            session = URLSession.shared
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw KernelError.message("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return (String(data: data, encoding: .utf8) ?? "", http)
    }

    /// 按出站内容去重（不同分组/provider 可能含重复节点）。
    private static func dedup(_ nodes: [ProxyNode]) -> [ProxyNode] {
        var seen = Set<String>()
        return nodes.filter { seen.insert($0.outboundJSON).inserted }
    }

    // MARK: 持久化

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL) else { return }  // 文件不存在：正常空状态
        do {
            subscriptions = try decoder.decode([Subscription].self, from: data)
        } catch {
            // 文件存在但解码失败（损坏/字段不兼容）：备份原文件，避免随后的 save() 用空数据覆盖、订阅全丢
            Self.backupCorruptFile(fileURL)
        }
    }

    /// 把损坏的持久化文件备份为 *.corrupt，保留用户数据以便手工恢复，而不是被空状态静默覆盖。
    private static func backupCorruptFile(_ url: URL) {
        let backup = url.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
    }


    private func save() {
        do {
            try FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(subscriptions)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            // 尽力而为
        }
    }

    private func loadSelection() {
        guard let data = try? Data(contentsOf: selectionURL),
              let node = try? JSONDecoder().decode(ProxyNode.self, from: data) else { return }
        selectedNode = node
    }

    private func saveSelection() {
        do {
            try FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
            guard let node = selectedNode else {
                try? FileManager.default.removeItem(at: selectionURL)
                return
            }
            let data = try JSONEncoder().encode(node)
            try data.write(to: selectionURL)
        } catch {
            // 尽力而为
        }
    }

    private func loadSubSelection() {
        guard let data = try? Data(contentsOf: subSelectionURL),
              let id = try? JSONDecoder().decode(UUID.self, from: data) else { return }
        selectedSubscriptionID = id
    }

    private func loadLastNodes() {
        guard let data = try? Data(contentsOf: lastNodesURL),
              let map = try? JSONDecoder().decode([UUID: String].self, from: data) else { return }
        lastNodeBySub = map
    }

    private func saveLastNodes() {
        try? FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(lastNodeBySub) { try? data.write(to: lastNodesURL) }
    }

    private func saveSubSelection() {
        do {
            try FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
            guard let id = selectedSubscriptionID else {
                try? FileManager.default.removeItem(at: subSelectionURL)
                return
            }
            let data = try JSONEncoder().encode(id)
            try data.write(to: subSelectionURL)
        } catch {
            // 尽力而为
        }
    }
}
