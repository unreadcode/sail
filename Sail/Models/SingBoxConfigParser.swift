import Foundation

/// 解析服务器直接下发的原生 sing-box 配置（JSON），从 outbounds 提取代理节点。
/// 这是最优路径：无需任何协议转换，且只含 sing-box 支持的协议。
enum SingBoxConfigParser {
    /// 非代理出站类型（分组 / 内置），需排除。
    nonisolated private static let nonProxyTypes: Set<String> = ["selector", "urltest", "direct", "block", "dns"]

    nonisolated static func looksLikeJSON(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
    }

    nonisolated static func parseOutbounds(_ text: String) -> [ProxyNode] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]] else { return [] }

        return outbounds.compactMap { ob in
            guard let type = (ob["type"] as? String)?.lowercased(),
                  !nonProxyTypes.contains(type),
                  let server = ob["server"] as? String, !server.isEmpty else { return nil }

            let port = portValue(ob["server_port"])
            guard port > 0 else { return nil }
            let name = (ob["tag"] as? String) ?? ""

            // 已是 sing-box 出站；规范化端口，并剥掉引用整份配置其它段的字段
            // （domain_resolver 指向 dns 段、detour 指向其它出站），使节点自包含
            var normalized = ob
            normalized["server_port"] = port
            normalized["domain_resolver"] = nil
            normalized["detour"] = nil
            return ProxyNode.make(name: name, type: type, server: server, port: port, outbound: normalized)
        }
    }

    nonisolated private static func portValue(_ v: Any?) -> Int {
        // 端口是 uint16；范围外取 0（由 server_port>0 守卫丢弃该节点，好过让畸形端口把整份配置喂崩内核）。
        if let i = v as? Int { return (0...65535).contains(i) ? i : 0 }
        if let s = v as? String { return Int(s).map { (0...65535).contains($0) ? $0 : 0 } ?? 0 }
        // Int(Double) 对超出 Int 范围的值是不可捕获的 fatalError：恶意/畸形订阅里 "server_port": 1e20
        // （JSONSerialization 解析为 Double，as? Int 失配落到这里）会直接崩掉整个 app。先做有限性+范围校验。
        if let d = v as? Double { return d.isFinite && d >= 0 && d <= Double(UInt16.max) ? Int(d) : 0 }
        return 0
    }
}
