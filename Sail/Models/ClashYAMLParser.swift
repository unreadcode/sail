import Foundation

/// 解析 Clash / Clash.Meta 订阅（YAML）中的 proxies，并把字段映射到 sing-box 出站。
/// 自带一个面向 Clash proxies 子集的迷你 YAML 解析器（支持块/流两种风格、缩进嵌套）。
/// 纯 Foundation，便于命令行独立测试。
enum ClashYAMLParser {
    /// 是否看起来是 Clash YAML（而非 base64 分享链接订阅）。
    nonisolated static func looksLikeClash(_ text: String) -> Bool {
        text.contains("\nproxies:") || text.hasPrefix("proxies:")
            || text.contains("proxy-providers:") || text.contains("proxy-groups:")
    }

    /// 解析 proxies 列表为节点。
    nonisolated static func parseProxies(_ yaml: String) -> [ProxyNode] {
        guard let value = topLevelValue(named: "proxies", in: yaml),
              let list = value as? [Any] else { return [] }
        return list.compactMap { ($0 as? [String: Any]).flatMap(node(from:)) }
    }

    /// 取出 proxy-providers 中 type: http 的 url 列表（用于跟随抓取真实节点）。
    nonisolated static func providerURLs(_ yaml: String) -> [String] {
        guard let value = topLevelValue(named: "proxy-providers", in: yaml),
              let providers = value as? [String: Any] else { return [] }
        var urls: [String] = []
        for case let p as [String: Any] in providers.values {
            if let url = p["url"] as? String, url.hasPrefix("http") { urls.append(url) }
        }
        return urls
    }

    // MARK: - Clash proxy → sing-box outbound

    nonisolated private static func node(from p: [String: Any]) -> ProxyNode? {
        let type = str(p["type"]).lowercased()
        let name = str(p["name"])
        let server = str(p["server"])
        let port = int(p["port"])
        guard !server.isEmpty, port > 0 else { return nil }

        var o: [String: Any] = ["tag": name, "server": server, "server_port": port]

        switch type {
        case "ss", "shadowsocks":
            o["type"] = "shadowsocks"
            o["method"] = str(p["cipher"])
            o["password"] = str(p["password"])

        case "vmess":
            o["type"] = "vmess"
            o["uuid"] = str(p["uuid"])
            o["alter_id"] = int(p["alterId"])
            o["security"] = str(p["cipher"]).isEmpty ? "auto" : str(p["cipher"])
            applyTransport(&o, p)
            if bool(p["tls"]) { o["tls"] = tls(p, defaultSNI: str(p["servername"])) }

        case "vless":
            o["type"] = "vless"
            o["uuid"] = str(p["uuid"])
            if !str(p["flow"]).isEmpty { o["flow"] = str(p["flow"]) }
            applyTransport(&o, p)
            if bool(p["tls"]) || p["reality-opts"] != nil {
                var t = tls(p, defaultSNI: str(p["servername"]))
                if let r = p["reality-opts"] as? [String: Any] {
                    t["reality"] = ["enabled": true,
                                    "public_key": str(r["public-key"]),
                                    "short_id": str(r["short-id"])]
                }
                o["tls"] = t
            }

        case "trojan":
            o["type"] = "trojan"
            o["password"] = str(p["password"])
            applyTransport(&o, p)
            o["tls"] = tls(p, defaultSNI: str(p["sni"]))

        case "hysteria2", "hy2":
            o["type"] = "hysteria2"
            o["password"] = str(p["password"])
            var t = tls(p, defaultSNI: str(p["sni"]))
            t["enabled"] = true
            o["tls"] = t
            if let obfs = p["obfs"] as? String, !obfs.isEmpty {
                o["obfs"] = ["type": obfs, "password": str(p["obfs-password"])]
            }

        case "tuic":
            o["type"] = "tuic"
            o["uuid"] = str(p["uuid"])
            o["password"] = str(p["password"])
            if !str(p["congestion-control"]).isEmpty { o["congestion_control"] = str(p["congestion-control"]) }
            if !str(p["udp-relay-mode"]).isEmpty { o["udp_relay_mode"] = str(p["udp-relay-mode"]) }
            if bool(p["reduce-rtt"]) { o["zero_rtt_handshake"] = true }
            var t = tls(p, defaultSNI: str(p["sni"]))
            if bool(p["disable-sni"]) { t["disable_sni"] = true }
            o["tls"] = t

        case "anytls":
            o["type"] = "anytls"
            o["password"] = str(p["password"])
            o["tls"] = tls(p, defaultSNI: str(p["sni"]))

        default:
            return nil // 暂不支持的协议（mieru / ssr / wireguard 等 sing-box 无对应出站）
        }

        return ProxyNode.make(name: name, type: o["type"] as? String ?? type, server: server, port: port, outbound: o)
    }

    nonisolated private static func applyTransport(_ o: inout [String: Any], _ p: [String: Any]) {
        switch str(p["network"]).lowercased() {
        case "ws":
            var t: [String: Any] = ["type": "ws"]
            if let ws = p["ws-opts"] as? [String: Any] {
                if let path = ws["path"] as? String, !path.isEmpty { t["path"] = path }
                if let headers = ws["headers"] as? [String: Any], let host = headers["Host"] ?? headers["host"] {
                    t["headers"] = ["Host": str(host)]
                }
            }
            o["transport"] = t
        case "grpc":
            let svc = (p["grpc-opts"] as? [String: Any]).map { str($0["grpc-service-name"]) } ?? ""
            o["transport"] = ["type": "grpc", "service_name": svc]
        case "h2", "http":
            var t: [String: Any] = ["type": "http"]
            if let h2 = p["h2-opts"] as? [String: Any] {
                if let path = h2["path"] as? String, !path.isEmpty { t["path"] = path }
                if let host = h2["host"] as? [Any] { t["host"] = host.map { str($0) } }
            }
            o["transport"] = t
        default:
            break // tcp / 空 → 无 transport
        }
    }

    nonisolated private static func tls(_ p: [String: Any], defaultSNI: String) -> [String: Any] {
        var t: [String: Any] = ["enabled": true]
        let sni = !str(p["servername"]).isEmpty ? str(p["servername"])
            : (!str(p["sni"]).isEmpty ? str(p["sni"]) : defaultSNI)
        if !sni.isEmpty { t["server_name"] = sni }
        if bool(p["skip-cert-verify"]) { t["insecure"] = true }
        if let alpn = p["alpn"] as? [Any], !alpn.isEmpty { t["alpn"] = alpn.map { str($0) } }
        let fp = str(p["client-fingerprint"])
        if !fp.isEmpty { t["utls"] = ["enabled": true, "fingerprint": fp] }
        return t
    }

    // MARK: - 取值工具

    nonisolated private static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let i = v as? Int { return String(i) }
        if let b = v as? Bool { return b ? "true" : "false" }
        return ""
    }

    nonisolated private static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) ?? 0 }
        return 0
    }

    nonisolated private static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let s = v as? String { return s == "true" || s == "1" }
        return false
    }

    // MARK: - 迷你 YAML 解析

    /// 取顶层键的值（list / map / scalar）。
    nonisolated static func topLevelValue(named key: String, in yaml: String) -> Any? {
        let lines = tokenize(yaml)
        guard let start = lines.firstIndex(where: { $0.indent == 0 && $0.text.hasPrefix("\(key):") }) else { return nil }
        let header = lines[start].text
        // 同行有值：key: value
        let inline = header.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        if !inline.isEmpty { return scalar(inline) }
        // 否则收集后续更深缩进的行作为子块
        var block: [Token] = []
        var i = start + 1
        while i < lines.count {
            if lines[i].indent == 0 { break }
            block.append(lines[i]); i += 1
        }
        if block.isEmpty { return nil }
        var cursor = 0
        return parseBlock(block, &cursor, indent: block[0].indent)
    }

    private struct Token { let indent: Int; let text: String }

    nonisolated private static func tokenize(_ yaml: String) -> [Token] {
        var out: [Token] = []
        for raw in yaml.components(separatedBy: "\n") {
            // 去掉制表 → 视作空格；跳过空行与整行注释
            let expanded = raw.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = expanded.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = expanded.prefix { $0 == " " }.count
            out.append(Token(indent: indent, text: trimmed))
        }
        return out
    }

    /// 递归解析一段同层 token：返回 [Any]（列表）或 [String:Any]（映射）。
    nonisolated private static func parseBlock(_ tokens: [Token], _ i: inout Int, indent: Int) -> Any {
        if i < tokens.count, tokens[i].text.hasPrefix("-") {
            return parseList(tokens, &i, indent: indent)
        }
        return parseMap(tokens, &i, indent: indent)
    }

    nonisolated private static func parseList(_ tokens: [Token], _ i: inout Int, indent: Int) -> [Any] {
        var arr: [Any] = []
        while i < tokens.count, tokens[i].indent == indent, tokens[i].text.hasPrefix("-") {
            let text = tokens[i].text
            let after = String(text.dropFirst(1)).trimmingCharacters(in: .whitespaces)
            i += 1
            if after.isEmpty {
                // 子块在后续更深缩进行
                if i < tokens.count, tokens[i].indent > indent {
                    arr.append(parseBlock(tokens, &i, indent: tokens[i].indent))
                } else {
                    arr.append("")
                }
            } else if after.hasPrefix("{") || after.hasPrefix("[") {
                arr.append(parseFlow(after))
            } else if let colon = keyColon(after) {
                // "- key: value" → 以该行为首的映射，合并后续更深缩进行
                var sub: [Token] = [Token(indent: indent + 2, text: after)]
                while i < tokens.count, tokens[i].indent > indent {
                    sub.append(tokens[i]); i += 1
                }
                // 用统一缩进重解析子映射
                let normalized = sub.map { Token(indent: $0.indent == indent + 2 ? childIndentNorm(indent) : $0.indent, text: $0.text) }
                _ = colon
                var c = 0
                arr.append(parseMap(normalized, &c, indent: normalized[0].indent))
            } else {
                arr.append(scalar(after))
            }
        }
        return arr
    }

    nonisolated private static func childIndentNorm(_ indent: Int) -> Int { indent + 2 }

    nonisolated private static func parseMap(_ tokens: [Token], _ i: inout Int, indent: Int) -> [String: Any] {
        var map: [String: Any] = [:]
        while i < tokens.count, tokens[i].indent == indent, !tokens[i].text.hasPrefix("-") {
            let text = tokens[i].text
            guard let colon = keyColon(text) else { i += 1; continue }
            let key = unquote(String(text[..<colon]).trimmingCharacters(in: .whitespaces))
            let valueStr = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            i += 1
            if valueStr.isEmpty {
                // 嵌套块
                if i < tokens.count, tokens[i].indent > indent {
                    map[key] = parseBlock(tokens, &i, indent: tokens[i].indent)
                } else {
                    map[key] = ""
                }
            } else if valueStr.hasPrefix("{") || valueStr.hasPrefix("[") {
                map[key] = parseFlow(valueStr)
            } else {
                map[key] = scalar(valueStr)
            }
        }
        return map
    }

    /// 找到作为 "key:" 分隔的冒号位置（跳过引号内/值内的冒号）。
    nonisolated private static func keyColon(_ s: String) -> String.Index? {
        if s.hasPrefix("\"") || s.hasPrefix("'") {
            let quote = s.first!
            if let end = s[s.index(after: s.startIndex)...].firstIndex(of: quote) {
                let afterQuote = s.index(after: end)
                if afterQuote < s.endIndex, s[afterQuote] == ":" { return afterQuote }
            }
            return nil
        }
        // 第一个 ": " 或行尾 ":"
        var idx = s.startIndex
        while idx < s.endIndex {
            if s[idx] == ":" {
                let next = s.index(after: idx)
                if next == s.endIndex || s[next] == " " { return idx }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    /// 解析内联流式 {a: b, c: d} 或 [x, y]
    nonisolated private static func parseFlow(_ s: String) -> Any {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("[") {
            let inner = String(t.dropFirst().dropLast())
            return splitTopLevel(inner).map { scalar($0.trimmingCharacters(in: .whitespaces)) }
        }
        if t.hasPrefix("{") {
            let inner = String(t.dropFirst().dropLast())
            var map: [String: Any] = [:]
            for pair in splitTopLevel(inner) {
                guard let colon = keyColon(pair.trimmingCharacters(in: .whitespaces)) else { continue }
                let p = pair.trimmingCharacters(in: .whitespaces)
                let k = unquote(String(p[..<colon]).trimmingCharacters(in: .whitespaces))
                let v = String(p[p.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                map[k] = (v.hasPrefix("{") || v.hasPrefix("[")) ? parseFlow(v) : scalar(v)
            }
            return map
        }
        return scalar(t)
    }

    /// 按顶层逗号切分（忽略嵌套 {} [] 内的逗号）。
    nonisolated private static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = []
        var depth = 0, current = ""
        for ch in s {
            switch ch {
            case "{", "[": depth += 1; current.append(ch)
            case "}", "]": depth -= 1; current.append(ch)
            case "," where depth == 0: parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    /// 标量：去引号、识别 bool / int。
    nonisolated private static func scalar(_ s: String) -> Any {
        let v = unquote(s)
        if s.hasPrefix("\"") || s.hasPrefix("'") { return v } // 显式字符串
        switch v.lowercased() {
        case "true": return true
        case "false": return false
        case "null", "~": return ""
        default: break
        }
        if let i = Int(v) { return i }
        return v
    }

    nonisolated private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")), t.count >= 2 {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }
}
