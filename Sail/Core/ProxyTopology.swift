import Foundation

/// 出站拓扑构建：把「选中订阅的节点 + 订阅自带 proxy-groups（或合成的默认组）」统一构建成
/// sing-box 出站数组 + 主选择器 tag。`KernelRunner.makeConfig`（运行配置）与
/// `ProxyGroupStore`（离线分组展示）共用同一套，保证运行态与离线态、配置与 UI 完全一致。
///
/// 核心原则：**分组永远存在，与路由模式 / 导入开关解耦**（对齐 Clash Verge / sing-box 官方）。
/// - 订阅自带 proxy-groups（已转换落盘到 route.json）→ 用机场原组，主选择器 = MATCH 去向组。
/// - 否则 → 合成 `Proxy`(selector, 含 `Auto` + 全部节点) + `Auto`(urltest, 全部节点)，主选择器 = `Proxy`。
enum ProxyTopology {
    /// 合成模式的主选择器 / 自动组 tag（机场模式用机场原组名，不走这俩）。
    static let masterTag = "Proxy"
    static let autoTag = "Auto"

    /// url-test 健康检查地址：订阅常写死 www.gstatic.com，但不少节点连不上它 → url-test 全超时、
    /// 选不出节点 → 走该组的流量直接断。统一覆盖成更普遍可达的 Cloudflare。
    static let healthCheckURL = "http://cp.cloudflare.com/generate_204"

    struct Result {
        /// 节点出站 + 组出站（不含 direct，调用方自行追加）。
        var outbounds: [[String: Any]]
        /// 主选择器 tag：route.final / 「走代理」去向。无节点时为 "direct"。
        var master: String
        /// 仅组出站（供离线 UI 解析成 Group）。
        var groupOutbounds: [[String: Any]]
        /// 节点 tag → 协议类型（离线给成员标协议用）。
        var protoByTag: [String: String]
        /// 是否有可用节点（hasProxy）。
        var hasNodes: Bool
    }

    /// 构建出站拓扑。
    /// - nodes: 选中订阅的节点
    /// - importedGroups: route.json 里的 groups（机场自带，已转换）；空 → 合成默认组
    /// - importedFinal: route.json 的 final（机场 MATCH 去向，= 主选择器组）
    /// - overrides: 各组的手动选择（groupName → memberTag），作 selector 的 default
    nonisolated static func build(nodes: [ProxyNode],
                                  importedGroups: [[String: Any]],
                                  importedFinal: String?,
                                  overrides: [String: String]) -> Result {
        let (nodeOuts, nameToTag) = nodeOutbounds(nodes)
        let nodeTags = nodeOuts.compactMap { $0["tag"] as? String }
        var protoByTag: [String: String] = [:]
        for o in nodeOuts {
            if let t = o["tag"] as? String, let p = (o["type"] as? String)?.lowercased() { protoByTag[t] = p }
        }
        guard !nodeTags.isEmpty else {
            return Result(outbounds: [], master: "direct", groupOutbounds: [], protoByTag: [:], hasNodes: false)
        }
        let groupOuts: [[String: Any]]
        let master: String
        if !importedGroups.isEmpty {
            groupOuts = groupOutbounds(importedGroups, allNodeTags: nodeTags, nameToTag: nameToTag, overrides: overrides)
            master = importedFinal ?? (importedGroups.first?["tag"] as? String) ?? masterTag
        } else {
            groupOuts = synthesizedGroups(nodeTags: nodeTags, overrides: overrides)
            master = masterTag
        }
        return Result(outbounds: nodeOuts + groupOuts, master: master,
                      groupOutbounds: groupOuts, protoByTag: protoByTag, hasNodes: true)
    }

    /// 合成默认组（机场没给 proxy-groups 时）：
    /// `Auto`(urltest, 全部节点) + `Proxy`(selector, [Auto] + 全部节点, default = override ?? Auto)。
    /// 用户在 `Proxy` 里点 `Auto` = 按延迟自动；点某节点 = 钉住该节点。
    nonisolated static func synthesizedGroups(nodeTags: [String], overrides: [String: String]) -> [[String: Any]] {
        let auto: [String: Any] = [
            "type": "urltest", "tag": autoTag, "outbounds": nodeTags,
            "url": healthCheckURL, "interval": "300s", "idle_timeout": "2100s",   // interval ≤ idle_timeout
        ]
        let proxyMembers = [autoTag] + nodeTags
        let sel = overrides[masterTag].flatMap { proxyMembers.contains($0) ? $0 : nil }
        let proxy: [String: Any] = [
            "type": "selector", "tag": masterTag, "outbounds": proxyMembers,
            "default": sel ?? autoTag,
        ]
        return [auto, proxy]
    }

    // MARK: 节点 → 出站

    /// 把订阅节点转成 sing-box 出站（tag 唯一化）；返回出站数组 + 「原始节点名 → 唯一 tag」映射（组按名引用）。
    nonisolated static func nodeOutbounds(_ nodes: [ProxyNode]) -> (outbounds: [[String: Any]], nameToTag: [String: String]) {
        var outs: [[String: Any]] = []
        var nameToTag: [String: String] = [:]
        var used = Set<String>()
        for node in nodes {
            guard let data = node.outboundJSON.data(using: .utf8),
                  var ob = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let base = node.label.isEmpty ? "node" : node.label
            var tag = base, i = 2
            while used.contains(tag) { tag = "\(base) \(i)"; i += 1 }
            used.insert(tag)
            ob["tag"] = tag
            outs.append(ob)
            if nameToTag[node.label] == nil { nameToTag[node.label] = tag }
        }
        return (outs, nameToTag)
    }

    /// 重建「成员 tag → 节点」映射，与 `nodeOutbounds` 的取 tag / 去重逻辑完全一致，
    /// 保证离线成员名能对回正确的节点（整组测速冷路径用）。
    nonisolated static func tagToNodeMap(_ nodes: [ProxyNode]) -> [String: ProxyNode] {
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

    // MARK: proxy-group → 出站

    /// 把订阅 proxy-group 定义转成 sing-box selector / url-test 出站。成员名解析为节点 tag / 嵌套组 / direct；
    /// useAll 展开为全部节点；空组兜底为全部节点（或 direct）。
    /// url-test **永远只读自动**（sing-box / clash_api 不支持手动切 url-test）；要钉节点请切其父 selector。
    nonisolated static func groupOutbounds(_ groups: [[String: Any]], allNodeTags: [String], nameToTag: [String: String],
                                           overrides: [String: String] = [:]) -> [[String: Any]] {
        let groupTags = Set(groups.compactMap { $0["tag"] as? String })
        var outs: [[String: Any]] = []
        for g in groups {
            guard let tag = g["tag"] as? String, let type = g["type"] as? String else { continue }
            var members: [String] = []
            if (g["useAll"] as? Bool) == true {
                // filter / exclude-filter（正则按节点名 = tag 筛选 use 展开的节点池）。
                var pool = allNodeTags
                if let f = g["filter"] as? String, let re = try? NSRegularExpression(pattern: f, options: [.caseInsensitive]) {
                    pool = pool.filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
                }
                if let ex = g["excludeFilter"] as? String, let re = try? NSRegularExpression(pattern: ex, options: [.caseInsensitive]) {
                    pool = pool.filter { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }
                }
                members += pool
            }
            for name in (g["members"] as? [String] ?? []) {
                if name == "DIRECT" { members.append("direct") }
                else if name == "REJECT" || name == "REJECT-DROP" || name == "PASS" { continue }
                else if groupTags.contains(name) { members.append(name) }      // 嵌套组
                else if let t = nameToTag[name] { members.append(t) }          // 节点名
            }
            // 去重保序
            var seen = Set<String>()
            members = members.filter { seen.insert($0).inserted }
            if members.isEmpty { members = allNodeTags.isEmpty ? ["direct"] : allNodeTags }
            var o: [String: Any] = ["type": type, "tag": tag, "outbounds": members]
            if type == "urltest" {
                o["url"] = healthCheckURL
                if let iv = g["interval"] as? String {
                    o["interval"] = iv
                    // sing-box 要求 interval ≤ idle_timeout；按存的 interval 推算一个更大的 idle_timeout。
                    let n = Int(iv.dropLast()) ?? 300   // "Ns" → N
                    o["idle_timeout"] = "\(n + 1800)s"
                }
                if let tol = g["tolerance"] as? Int { o["tolerance"] = tol }
            } else {
                // selector：default 取用户手动选择（须在成员内），否则首个。
                o["type"] = "selector"
                let override = overrides[tag].flatMap { members.contains($0) ? $0 : nil }
                o["default"] = override ?? members.first
            }
            outs.append(o)
        }
        return outs
    }
}
