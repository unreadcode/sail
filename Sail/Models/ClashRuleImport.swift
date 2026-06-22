import Foundation

/// 把 Clash 订阅自带的 rules + rule-providers + proxy-groups 转成 sing-box 路由。
/// - rule-provider（Clash 格式 domain/ipcidr/classical）下载后转成 sing-box rule_set 源文件(本地缓存)，
///   避免把成千上万条域名内联进配置(proxy.txt 就 2.6 万条)。
/// - 每条 Clash 规则的去向按 proxy-group 的默认指向(首个 proxies 选项)递归解析为 proxy/direct/reject——
///   Sail 无出站分组，故所有「走代理」的组都归到当前选中节点(proxy)。
enum ClashRuleImport {

    // MARK: 对外：转换并落盘

    /// 把订阅的路由转成 sing-box route 片段写进 dir/route.json，rule_set 源文件同目录。
    /// 返回是否产出了规则。hasProxy=false 时丢弃「走代理」类规则。
    @discardableResult
    nonisolated static func build(yaml: String, into dir: URL, hasProxy: Bool, proxyPort: Int?) async -> Bool {
        let clashRules = ClashYAMLParser.rules(yaml)
        guard !clashRules.isEmpty else { return false }
        let providers = ClashYAMLParser.ruleProviders(yaml)

        // 去向直接指向真实组名（该组会作为 selector/url-test 出站被生成）；DIRECT→直连，REJECT→拦截(nil)。
        func outboundFor(_ target: String) -> String? {
            let t = target.trimmingCharacters(in: .whitespaces)
            if t == "DIRECT" { return "direct" }
            if t == "REJECT" || t == "REJECT-DROP" || t == "PASS" { return nil }
            return t
        }

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sbRules: [[String: Any]] = []
        var ruleSetDefs: [[String: Any]] = []
        var seenTags = Set<String>()
        var finalOutbound: String?

        for raw in clashRules {
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let type = parts.first?.uppercased() else { continue }

            if type == "MATCH" || type == "FINAL" {
                guard parts.count >= 2 else { continue }
                finalOutbound = outboundFor(parts[1]) ?? "direct"   // 兜底走 reject 极少见，退直连
                continue
            }
            guard parts.count >= 3 else { continue }
            let arg = parts[1], out = outboundFor(parts[2])

            switch type {
            case "RULE-SET":
                let tag = "sub-" + sanitize(arg)
                if !seenTags.contains(tag) {
                    guard let prov = providers[arg], let url = prov["url"] as? String else { continue }
                    let behavior = (prov["behavior"] as? String ?? "classical").lowercased()
                    let file = dir.appendingPathComponent("\(tag).json")
                    guard await downloadAndConvert(url, behavior: behavior, to: file, proxyPort: proxyPort) else { continue }
                    ruleSetDefs.append(["type": "local", "tag": tag, "format": "source", "path": file.path])
                    seenTags.insert(tag)
                }
                sbRules.append(withAction(["rule_set": [tag]], out))

            case "GEOIP":
                let code = sanitize(arg.lowercased())
                guard !code.isEmpty else { continue }
                let tag = "geoip-\(code)"
                addRemoteGeo(tag, kind: "geoip", code: code, hasProxy: hasProxy, into: &ruleSetDefs, seen: &seenTags)
                sbRules.append(withAction(["rule_set": [tag]], out))

            case "GEOSITE":
                let code = sanitize(arg.lowercased())
                guard !code.isEmpty else { continue }
                let tag = "geosite-\(code)"
                addRemoteGeo(tag, kind: "geosite", code: code, hasProxy: hasProxy, into: &ruleSetDefs, seen: &seenTags)
                sbRules.append(withAction(["rule_set": [tag]], out))

            default:
                var m = Matchers()
                guard addMatcher(type, arg, into: &m) else { continue }   // 不认识的类型跳过
                for obj in m.ruleObjects() { sbRules.append(withAction(obj, out)) }
            }
        }

        // 出站分组定义（makeConfig 据此 + 订阅节点生成 selector/url-test 出站）。
        var groups: [[String: Any]] = []
        for g in ClashYAMLParser.proxyGroupDefs(yaml) {
            guard let name = g["name"] as? String else { continue }
            let ctype = (g["type"] as? String ?? "select").lowercased()
            var gd: [String: Any] = [
                "tag": name,
                "type": ctype == "select" ? "selector" : "urltest",   // url-test/fallback/load-balance → urltest
                "members": (g["proxies"] as? [Any])?.compactMap { $0 as? String } ?? [],
                "useAll": !((g["use"] as? [Any])?.isEmpty ?? true),    // use 任意 provider → 全部订阅节点
            ]
            if gd["type"] as? String == "urltest" {
                gd["url"] = "http://cp.cloudflare.com/generate_204"   // 统一用更普遍可达的地址（运行时 groupOutbounds 也会覆盖）
                let iv = (g["interval"] as? Int) ?? (Int((g["interval"] as? String) ?? "") ?? 300)
                gd["interval"] = "\(iv)s"
                if let tol = g["tolerance"] as? Int { gd["tolerance"] = tol }
            }
            groups.append(gd)
        }

        var route: [String: Any] = ["rules": sbRules, "rule_set": ruleSetDefs, "groups": groups]
        if let f = finalOutbound { route["final"] = f }
        guard !sbRules.isEmpty || finalOutbound != nil,
              let data = try? JSONSerialization.data(withJSONObject: route) else { return false }
        try? data.write(to: dir.appendingPathComponent("route.json"), options: .atomic)
        return true
    }

    /// 读回某订阅已转换的 route 片段（makeConfig 用）。
    nonisolated static func importedRoute(dir: URL)
        -> (rules: [[String: Any]], ruleSet: [[String: Any]], final: String?, groups: [[String: Any]])? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("route.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["rules"] as? [[String: Any]] ?? [],
                obj["rule_set"] as? [[String: Any]] ?? [],
                obj["final"] as? String,
                obj["groups"] as? [[String: Any]] ?? [])
    }

    // MARK: 去向注入

    private nonisolated static func withAction(_ rule: [String: Any], _ outbound: String?) -> [String: Any] {
        var r = rule
        if let o = outbound { r["outbound"] = o } else { r["action"] = "reject" }
        return r
    }

    private nonisolated static func addRemoteGeo(_ tag: String, kind: String, code: String, hasProxy: Bool,
                                                 into defs: inout [[String: Any]], seen: inout Set<String>) {
        guard !seen.contains(tag) else { return }
        let url = "https://raw.githubusercontent.com/SagerNet/sing-\(kind)/rule-set/\(tag).srs"
        defs.append(["type": "remote", "tag": tag, "format": "binary", "url": url,
                     "download_detour": hasProxy ? "proxy" : "direct"])
        seen.insert(tag)
    }

    // MARK: Clash 规则体 → sing-box matcher

    private struct Matchers {
        var domain: [String] = [], domainSuffix: [String] = [], domainKeyword: [String] = []
        var ipCidr: [String] = [], process: [String] = [], sourceIPCidr: [String] = []
        var port: [Int] = []
        func ruleObjects() -> [[String: Any]] {
            var r: [[String: Any]] = []
            if !domain.isEmpty { r.append(["domain": domain]) }
            if !domainSuffix.isEmpty { r.append(["domain_suffix": domainSuffix]) }
            if !domainKeyword.isEmpty { r.append(["domain_keyword": domainKeyword]) }
            if !ipCidr.isEmpty { r.append(["ip_cidr": ipCidr]) }
            if !process.isEmpty { r.append(["process_name": process]) }
            if !sourceIPCidr.isEmpty { r.append(["source_ip_cidr": sourceIPCidr]) }
            if !port.isEmpty { r.append(["port": port]) }
            return r
        }
    }

    /// 把一条 Clash 规则体(TYPE, arg)累加进 matcher；识别返回 true。
    private nonisolated static func addMatcher(_ type: String, _ arg: String, into m: inout Matchers) -> Bool {
        switch type.uppercased() {
        case "DOMAIN": m.domain.append(arg)
        case "DOMAIN-SUFFIX": m.domainSuffix.append(arg)
        case "DOMAIN-KEYWORD": m.domainKeyword.append(arg)
        case "IP-CIDR", "IP-CIDR6": m.ipCidr.append(arg)
        case "PROCESS-NAME": m.process.append(arg)
        case "SRC-IP-CIDR": m.sourceIPCidr.append(arg)
        case "DST-PORT": if let p = Int(arg) { m.port.append(p) } else { return false }
        default: return false
        }
        return true
    }

    // MARK: rule-provider 下载 + 转 sing-box rule_set 源

    private nonisolated static func downloadAndConvert(_ urlString: String, behavior: String, to file: URL, proxyPort: Int?) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let cfg = URLSessionConfiguration.ephemeral
        if let port = proxyPort {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true, kCFNetworkProxiesHTTPProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true, kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1", kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        guard let (data, resp) = try? await URLSession(configuration: cfg).data(for: URLRequest(url: url, timeoutInterval: 30)),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let text = String(data: data, encoding: .utf8) else { return false }

        var m = Matchers()
        for entry in payloadEntries(text) {
            switch behavior {
            case "domain":
                if entry.hasPrefix("+.") { m.domainSuffix.append(String(entry.dropFirst(2))) }
                else if entry.hasPrefix("*.") { m.domainSuffix.append(String(entry.dropFirst(2))) }
                else { m.domain.append(entry) }
            case "ipcidr":
                m.ipCidr.append(entry)
            default: // classical：每条是「TYPE,arg[,...]」
                let p = entry.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count >= 2 { _ = addMatcher(p[0], p[1], into: &m) }
            }
        }
        let objs = m.ruleObjects()
        guard !objs.isEmpty,
              let out = try? JSONSerialization.data(withJSONObject: ["version": 2, "rules": objs]) else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? out.write(to: file, options: .atomic)) != nil
    }

    /// 取 Clash provider 的 payload 列表项（`payload:` 下的 `- 'x'` 行；去引号）。纯行解析，足够稳。
    private nonisolated static func payloadEntries(_ text: String) -> [String] {
        var out: [String] = []
        var inPayload = false
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "payload:" || t.hasPrefix("payload:") { inPayload = true; continue }
            guard inPayload, t.hasPrefix("-") else {
                if !t.isEmpty && !t.hasPrefix("-") && !t.hasPrefix("#") && inPayload { break } // 离开 payload 块
                continue
            }
            var v = t.dropFirst().trimmingCharacters(in: .whitespaces)
            if (v.hasPrefix("'") && v.hasSuffix("'")) || (v.hasPrefix("\"") && v.hasSuffix("\"")), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            if !v.isEmpty { out.append(v) }
        }
        return out
    }

    /// rule_set tag 只留合法字符。
    private nonisolated static func sanitize(_ s: String) -> String {
        String(s.lowercased().map { ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "-" ? $0 : "-" })
    }
}
