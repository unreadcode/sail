import Foundation

/// 一个代理节点：展示字段 + 已转换好的 sing-box 出站对象（JSON 字符串）。
/// outboundJSON 中的 tag 在生成运行配置时会被统一覆盖，保证唯一。
struct ProxyNode: Codable, Identifiable, Equatable {
    var id = UUID()            // 视图身份（ForEach diff）；每次解析新生成，不可用于内容匹配
    var name: String
    var type: String      // shadowsocks / vmess / vless / trojan
    var server: String
    var port: Int
    var outboundJSON: String

    var label: String { name.isEmpty ? "\(server):\(port)" : name }

    /// 内容相等：以 outboundJSON 为准（其中含 tag=name + 完整出站配置，是节点的稳定指纹）。
    /// 不比较随机 id —— 订阅刷新会重新解析、id 全变，按 id 判等会让选中态/归属判断在刷新后失配。
    static func == (lhs: ProxyNode, rhs: ProxyNode) -> Bool {
        lhs.outboundJSON == rhs.outboundJSON
    }

    /// 由 sing-box 出站字典构造节点（序列化为稳定 JSON 字符串）。
    nonisolated static func make(name: String, type: String, server: String, port: Int, outbound: [String: Any]) -> ProxyNode? {
        guard !server.isEmpty, port > 0,
              let data = try? JSONSerialization.data(withJSONObject: outbound, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let display = name.isEmpty ? "\(server):\(port)" : name
        return ProxyNode(name: display, type: type, server: server, port: port, outboundJSON: json)
    }
}

/// 把订阅内容 / 分享链接解析为 ProxyNode。纯 Foundation，便于命令行独立测试。
enum ShareLinkParser {
    /// 解析订阅正文：通常是 base64(换行分隔的分享链接)，也兼容明文链接列表。
    nonisolated static func parseSubscription(_ raw: String) -> [ProxyNode] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 含 "://" 说明已是明文链接列表（base64 字母表不含 ':'，纯 base64 绝不含 "://"）→ 不要误当 base64 解码成乱码。
        let body = trimmed.contains("://") ? trimmed : (decodeBase64(trimmed) ?? trimmed)
        return body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap(parseLink)
    }

    /// 解析单条分享链接。
    nonisolated static func parseLink(_ link: String) -> ProxyNode? {
        guard let scheme = link.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() else {
            return nil
        }
        switch scheme {
        case "ss": return parseShadowsocks(link)
        case "vmess": return parseVmess(link)
        case "vless": return parseVless(link)
        case "trojan": return parseTrojan(link)
        case "hysteria2", "hy2": return parseHysteria2(link, scheme: scheme + "://")
        case "tuic": return parseTuic(link)
        case "anytls": return parseAnyTLS(link)
        default: return nil
        }
    }

    // MARK: - shadowsocks

    nonisolated private static func parseShadowsocks(_ link: String) -> ProxyNode? {
        var rest = String(link.dropFirst("ss://".count))
        let name = popFragment(&rest)
        // 查询参数：SIP003 plugin（obfs / v2ray-plugin 等）暂不支持。
        // 带 plugin 的节点若砍掉参数照常生成，会得到一个必然连不上的「坏节点」——宁可丢弃，避免误导。
        if let q = rest.firstIndex(of: "?") {
            let query = parseQuery(String(rest[rest.index(after: q)...]))
            if let plugin = query["plugin"], !plugin.isEmpty { return nil }
            rest = String(rest[..<q])
        }

        var method = "", password = "", host = "", port = 0
        if let at = rest.lastIndex(of: "@") {
            // SIP002：ss://base64(method:password)@host:port
            let userInfo = String(rest[..<at])
            let hostPort = String(rest[rest.index(after: at)...])
            let decoded = decodeBase64(userInfo) ?? userInfo
            guard let colon = decoded.firstIndex(of: ":") else { return nil }
            method = String(decoded[..<colon])
            password = String(decoded[decoded.index(after: colon)...])
            guard let hp = splitHostPort(hostPort) else { return nil }
            host = hp.0; port = hp.1
        } else {
            // 旧式：ss://base64(method:password@host:port)
            guard let decoded = decodeBase64(rest), let at = decoded.lastIndex(of: "@") else { return nil }
            let cred = String(decoded[..<at])
            guard let colon = cred.firstIndex(of: ":"), let hp = splitHostPort(String(decoded[decoded.index(after: at)...])) else { return nil }
            method = String(cred[..<colon])
            password = String(cred[cred.index(after: colon)...])
            host = hp.0; port = hp.1
        }
        guard !host.isEmpty, port > 0, !method.isEmpty else { return nil }

        let outbound: [String: Any] = [
            "type": "shadowsocks", "tag": name,
            "server": host, "server_port": port,
            "method": method, "password": password,
        ]
        return node(name: name, type: "shadowsocks", server: host, port: port, outbound: outbound)
    }

    // MARK: - vmess

    nonisolated private static func parseVmess(_ link: String) -> ProxyNode? {
        let b64 = String(link.dropFirst("vmess://".count))
        guard let json = decodeBase64(b64)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }

        let host = string(obj["add"])
        let port = intValue(obj["port"])
        let name = string(obj["ps"])
        guard !host.isEmpty, port > 0 else { return nil }

        var outbound: [String: Any] = [
            "type": "vmess", "tag": name,
            "server": host, "server_port": port,
            "uuid": string(obj["id"]),
            "alter_id": intValue(obj["aid"]),
            "security": string(obj["scy"]).isEmpty ? "auto" : string(obj["scy"]),
        ]
        if let t = transport(net: string(obj["net"]), path: string(obj["path"]), host: string(obj["host"]), type: string(obj["type"])) {
            outbound["transport"] = t
        }
        // tls 字段在不同机场的 vmess 分享 JSON 里类型不一：可能是 "tls" / "true" / "1"，也可能是布尔 true。
        let tlsRaw = obj["tls"]
        let tlsOn = (tlsRaw as? Bool == true) || ["tls", "true", "1"].contains(string(tlsRaw).lowercased())
        if tlsOn {
            outbound["tls"] = tls(sni: string(obj["sni"]).isEmpty ? string(obj["host"]) : string(obj["sni"]),
                                  alpn: string(obj["alpn"]), insecure: false)
        }
        return node(name: name, type: "vmess", server: host, port: port, outbound: outbound)
    }

    // MARK: - vless

    nonisolated private static func parseVless(_ link: String) -> ProxyNode? {
        guard let parsed = parseUserHostQuery(link, scheme: "vless://") else { return nil }
        let q = parsed.query
        var outbound: [String: Any] = [
            "type": "vless", "tag": parsed.name,
            "server": parsed.host, "server_port": parsed.port,
            "uuid": parsed.user,
        ]
        if let flow = q["flow"], !flow.isEmpty { outbound["flow"] = flow }
        if let t = transport(net: q["type"] ?? "", path: q["path"] ?? q["serviceName"] ?? "", host: q["host"] ?? "", type: q["headerType"] ?? "") {
            outbound["transport"] = t
        }
        switch (q["security"] ?? "").lowercased() {
        case "tls":
            outbound["tls"] = tls(sni: q["sni"] ?? q["host"] ?? "", alpn: q["alpn"] ?? "", insecure: q["allowInsecure"] == "1", fingerprint: q["fp"])
        case "reality":
            var t = tls(sni: q["sni"] ?? "", alpn: "", insecure: false, fingerprint: q["fp"])
            t["reality"] = ["enabled": true, "public_key": q["pbk"] ?? "", "short_id": q["sid"] ?? ""]
            outbound["tls"] = t
        default: break
        }
        return node(name: parsed.name, type: "vless", server: parsed.host, port: parsed.port, outbound: outbound)
    }

    // MARK: - trojan

    nonisolated private static func parseTrojan(_ link: String) -> ProxyNode? {
        guard let parsed = parseUserHostQuery(link, scheme: "trojan://") else { return nil }
        let q = parsed.query
        var outbound: [String: Any] = [
            "type": "trojan", "tag": parsed.name,
            "server": parsed.host, "server_port": parsed.port,
            "password": parsed.user,
        ]
        outbound["tls"] = tls(sni: q["sni"] ?? q["peer"] ?? parsed.host, alpn: q["alpn"] ?? "", insecure: q["allowInsecure"] == "1", fingerprint: q["fp"])
        if let t = transport(net: q["type"] ?? "", path: q["path"] ?? q["serviceName"] ?? "", host: q["host"] ?? "", type: q["headerType"] ?? "") {
            outbound["transport"] = t
        }
        return node(name: parsed.name, type: "trojan", server: parsed.host, port: parsed.port, outbound: outbound)
    }

    // MARK: - hysteria2 / hy2

    nonisolated private static func parseHysteria2(_ link: String, scheme: String) -> ProxyNode? {
        guard let p = parseUserHostQuery(link, scheme: scheme) else { return nil }
        let q = p.query
        var t: [String: Any] = ["enabled": true]
        let sni = q["sni"] ?? q["peer"] ?? ""
        if !sni.isEmpty { t["server_name"] = sni }
        if q["insecure"] == "1" || q["allowInsecure"] == "1" { t["insecure"] = true }
        if let alpn = q["alpn"], !alpn.isEmpty { t["alpn"] = alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        var o: [String: Any] = [
            "type": "hysteria2", "tag": p.name,
            "server": p.host, "server_port": p.port,
            "password": p.user.removingPercentEncoding ?? p.user,
            "tls": t,
        ]
        if let obfs = q["obfs"], !obfs.isEmpty {
            o["obfs"] = ["type": obfs, "password": q["obfs-password"] ?? q["obfs_password"] ?? ""]
        }
        return node(name: p.name, type: "hysteria2", server: p.host, port: p.port, outbound: o)
    }

    // MARK: - tuic

    nonisolated private static func parseTuic(_ link: String) -> ProxyNode? {
        guard let p = parseUserHostQuery(link, scheme: "tuic://") else { return nil }
        let q = p.query
        // user 形如 uuid:password
        let creds = p.user.split(separator: ":", maxSplits: 1).map(String.init)
        let uuid = creds.first ?? ""
        let password = (creds.count > 1 ? creds[1] : "").removingPercentEncoding ?? (creds.count > 1 ? creds[1] : "")
        guard !uuid.isEmpty else { return nil }
        var t: [String: Any] = ["enabled": true]
        let sni = q["sni"] ?? q["peer"] ?? ""
        if !sni.isEmpty { t["server_name"] = sni }
        if q["allow_insecure"] == "1" || q["allowInsecure"] == "1" || q["insecure"] == "1" { t["insecure"] = true }
        if let alpn = q["alpn"], !alpn.isEmpty { t["alpn"] = alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        var o: [String: Any] = [
            "type": "tuic", "tag": p.name,
            "server": p.host, "server_port": p.port,
            "uuid": uuid, "password": password, "tls": t,
        ]
        if let cc = q["congestion_control"] ?? q["congestion-control"], !cc.isEmpty { o["congestion_control"] = cc }
        if let urm = q["udp_relay_mode"] ?? q["udp-relay-mode"], !urm.isEmpty { o["udp_relay_mode"] = urm }
        return node(name: p.name, type: "tuic", server: p.host, port: p.port, outbound: o)
    }

    // MARK: - anytls

    nonisolated private static func parseAnyTLS(_ link: String) -> ProxyNode? {
        guard let p = parseUserHostQuery(link, scheme: "anytls://") else { return nil }
        let q = p.query
        var t: [String: Any] = ["enabled": true]
        let sni = q["sni"] ?? q["peer"] ?? ""
        if !sni.isEmpty { t["server_name"] = sni }
        if q["insecure"] == "1" || q["allowInsecure"] == "1" { t["insecure"] = true }
        if let alpn = q["alpn"], !alpn.isEmpty { t["alpn"] = alpn.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let o: [String: Any] = [
            "type": "anytls", "tag": p.name,
            "server": p.host, "server_port": p.port,
            "password": p.user.removingPercentEncoding ?? p.user,
            "tls": t,
        ]
        return node(name: p.name, type: "anytls", server: p.host, port: p.port, outbound: o)
    }

    // MARK: - 通用构件

    /// 解析 `scheme user@host:port?query#name` 形式
    nonisolated private static func parseUserHostQuery(_ link: String, scheme: String) -> (user: String, host: String, port: Int, query: [String: String], name: String)? {
        var rest = String(link.dropFirst(scheme.count))
        let name = popFragment(&rest)
        var query: [String: String] = [:]
        if let qi = rest.firstIndex(of: "?") {
            query = parseQuery(String(rest[rest.index(after: qi)...]))
            rest = String(rest[..<qi])
        }
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let user = String(rest[..<at])
        guard let hp = splitHostPort(String(rest[rest.index(after: at)...])) else { return nil }
        return (user, hp.0, hp.1, query, name)
    }

    nonisolated private static func transport(net: String, path: String, host: String, type: String) -> [String: Any]? {
        switch net.lowercased() {
        case "ws":
            var t: [String: Any] = ["type": "ws"]
            if !path.isEmpty { t["path"] = path }
            if !host.isEmpty { t["headers"] = ["Host": host] }
            return t
        case "grpc":
            return ["type": "grpc", "service_name": path]
        case "http", "h2":
            var t: [String: Any] = ["type": "http"]
            if !host.isEmpty { t["host"] = [host] }
            if !path.isEmpty { t["path"] = path }
            return t
        default:
            return nil // tcp / 空 → 无 transport
        }
    }

    nonisolated private static func tls(sni: String, alpn: String, insecure: Bool, fingerprint: String? = nil) -> [String: Any] {
        var t: [String: Any] = ["enabled": true]
        if !sni.isEmpty { t["server_name"] = sni }
        if insecure { t["insecure"] = true }
        if !alpn.isEmpty { t["alpn"] = alpn.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
        if let fp = fingerprint, !fp.isEmpty { t["utls"] = ["enabled": true, "fingerprint": fp] }
        return t
    }

    nonisolated private static func node(name: String, type: String, server: String, port: Int, outbound: [String: Any]) -> ProxyNode? {
        guard let data = try? JSONSerialization.data(withJSONObject: outbound, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        let display = name.isEmpty ? "\(server):\(port)" : name
        return ProxyNode(name: display, type: type, server: server, port: port, outboundJSON: json)
    }

    // MARK: - 小工具

    nonisolated private static func popFragment(_ s: inout String) -> String {
        guard let h = s.firstIndex(of: "#") else { return "" }
        let frag = String(s[s.index(after: h)...])
        s = String(s[..<h])
        return frag.removingPercentEncoding ?? frag
    }

    nonisolated private static func splitHostPort(_ s: String) -> (String, Int)? {
        // IPv6 字面量：[2001:db8::1]:443 —— 不能用 lastIndex(of: ":") 切，会把地址里的冒号当分隔符。
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            guard after.hasPrefix(":"), let port = Int(after.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[..<colon])
        guard let port = Int(s[s.index(after: colon)...]) else { return nil }
        return (host, port)
    }

    nonisolated private static func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let k = kv.first.map(String.init) else { continue }
            let v = kv.count > 1 ? String(kv[1]) : ""
            out[k] = v.removingPercentEncoding ?? v
        }
        return out
    }

    /// 宽松 base64 解码（补齐 padding、支持 URL-safe）；失败返回 nil。
    nonisolated private static func decodeBase64(_ s: String) -> String? {
        var str = s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = str.count % 4
        if pad > 0 { str += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: str),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        return decoded
    }

    nonisolated private static func string(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let i = v as? Int { return String(i) }
        return ""
    }

    nonisolated private static func intValue(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) ?? 0 }
        if let d = v as? Double { return Int(d) }
        return 0
    }
}
