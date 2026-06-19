import Foundation
import Observation

/// 规则匹配方式。
enum RuleMatch: String, Codable, CaseIterable, Identifiable {
    case domainSuffix, domainKeyword, domain, ipCIDR, geosite, geoip
    case processName, port, proto
    var id: String { rawValue }
    var label: String {
        switch self {
        case .domainSuffix: "域名后缀"
        case .domainKeyword: "域名关键词"
        case .domain: "完整域名"
        case .ipCIDR: "IP 段"
        case .geosite: "GeoSite 分类"
        case .geoip: "GeoIP 分类"
        case .processName: "进程名"
        case .port: "端口"
        case .proto: "协议"
        }
    }
    var singBoxKey: String {
        switch self {
        case .domainSuffix: "domain_suffix"
        case .domainKeyword: "domain_keyword"
        case .domain: "domain"
        case .ipCIDR: "ip_cidr"
        case .geosite, .geoip: "rule_set"
        case .processName: "process_name"
        case .port: "port"
        case .proto: "protocol"
        }
    }
    var placeholder: String {
        switch self {
        case .domainSuffix: "example.com"
        case .domainKeyword: "google"
        case .domain: "www.example.com"
        case .ipCIDR: "192.168.0.0/16"
        case .geosite: "netflix / telegram / google"
        case .geoip: "cn / us / jp"
        case .processName: "Telegram / qBittorrent（可逗号分隔多个）"
        case .port: "443 / 80,443 / 6881-6889"
        case .proto: "tls / http / quic / bittorrent / dns"
        }
    }
    /// 多个值的输入说明（逗号分隔）。
    var hint: String? {
        switch self {
        case .processName: "应用进程名（含 .app 后缀或可执行名），多个用逗号分隔。"
        case .port: "目标端口；单个、逗号分隔多个，或 起-止 区间（如 6881-6889）。"
        case .proto: "嗅探出的应用层协议，多个用逗号分隔。"
        default: nil
        }
    }
    var isGeo: Bool { self == .geosite || self == .geoip }
}

/// 规则命中后的去向。
enum RuleAction: String, Codable, CaseIterable, Identifiable {
    case proxy, direct, reject
    var id: String { rawValue }
    var label: String {
        switch self {
        case .proxy: "代理"
        case .direct: "直连"
        case .reject: "拦截"
        }
    }
}

struct RoutingRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var match: RuleMatch = .domainSuffix
    var value: String = ""
    var action: RuleAction = .proxy
    var enabled: Bool = true
}

/// 用户自定义分流规则。优先级高于内置（geosite/geoip-cn）分流，注入运行配置后即时重启生效。
@MainActor
@Observable
final class RuleStore {
    static let shared = RuleStore()

    private(set) var rules: [RoutingRule] = []

    private var fileURL: URL { KernelPaths.supportDir.appendingPathComponent("rules.json") }

    private init() { load() }

    func add(_ rule: RoutingRule) { rules.append(rule); persistAndApply() }

    func update(_ rule: RoutingRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
        persistAndApply()
    }

    func remove(_ id: UUID) { rules.removeAll { $0.id == id }; persistAndApply() }

    /// 拖拽调序：顺序即匹配优先级（自上而下）。
    /// 手写实现，避免在 Store 里依赖 SwiftUI 的 move(fromOffsets:toOffset:)。
    func move(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { rules[$0] }
        let remaining = rules.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        var result = remaining
        result.insert(contentsOf: moving, at: min(max(insertAt, 0), result.count))
        rules = result
        persistAndApply()
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled = on
        persistAndApply()
    }

    /// 转成 sing-box route 规则（按列表顺序）。代理类规则仅在有代理出站时才加入。
    func singBoxRules(hasProxy: Bool) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for r in rules where r.enabled {
            let v = r.value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { continue }
            var dict: [String: Any]
            switch r.match {
            case .geosite:
                let code = v.lowercased()
                guard Self.isValidGeoCode(code) else { continue }
                dict = ["rule_set": ["geosite-\(code)"]]
            case .geoip:
                let code = v.lowercased()
                guard Self.isValidGeoCode(code) else { continue }
                dict = ["rule_set": ["geoip-\(code)"]]
            case .processName:
                let names = Self.splitList(v)
                guard !names.isEmpty else { continue }
                dict = ["process_name": names]
            case .proto:
                let protos = Self.splitList(v).map { $0.lowercased() }
                guard !protos.isEmpty else { continue }
                dict = ["protocol": protos]
            case .port:
                let (ports, ranges) = Self.parsePorts(v)
                guard !ports.isEmpty || !ranges.isEmpty else { continue }
                dict = [:]
                if !ports.isEmpty { dict["port"] = ports }
                if !ranges.isEmpty { dict["port_range"] = ranges }
            default:
                dict = [r.match.singBoxKey: [v]]
            }
            switch r.action {
            case .proxy:
                guard hasProxy else { continue }
                dict["outbound"] = "proxy"
            case .direct:
                dict["outbound"] = "direct"
            case .reject:
                dict["action"] = "reject"
            }
            out.append(dict)
        }
        return out
    }

    /// geo 分类码合法字符：小写字母 / 数字 / 连字符（如 cn、google、category-ads-all）。
    /// 非法字符（空格、斜杠、`..` 等）会拼出畸形 rule_set tag 或 URL，让整份 sing-box 配置启动失败、所有规则连带失效，故直接跳过。
    private static func isValidGeoCode(_ v: String) -> Bool {
        !v.isEmpty && v.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// 逗号分隔 → 去空去重的字符串数组。
    private static func splitList(_ s: String) -> [String] {
        var seen = Set<String>()
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 解析端口输入：单个/逗号分隔的整数进 port，起-止（或起:止）区间进 port_range（sing-box 格式 "start:end"）。
    private static func parsePorts(_ s: String) -> (ports: [Int], ranges: [String]) {
        var ports: [Int] = []
        var ranges: [String] = []
        for tok in s.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !tok.isEmpty {
            if tok.contains("-") || tok.contains(":") {
                let parts = tok.split(whereSeparator: { $0 == "-" || $0 == ":" }).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]),
                   a <= b, (1...65535).contains(a), (1...65535).contains(b) {
                    ranges.append("\(a):\(b)")
                }
            } else if let p = Int(tok), (1...65535).contains(p) {
                ports.append(p)
            }
        }
        return (Array(Set(ports)).sorted(), Array(Set(ranges)))
    }

    /// geo 规则用到的远程 rule_set 定义（去重）；下载走代理（无代理则直连）。
    func geoRuleSets(hasProxy: Bool) -> [[String: Any]] {
        let detour = hasProxy ? "proxy" : "direct"
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for r in rules where r.enabled && r.match.isGeo {
            if r.action == .proxy && !hasProxy { continue }
            let v = r.value.trimmingCharacters(in: .whitespaces).lowercased()
            guard Self.isValidGeoCode(v) else { continue }
            let tag: String, url: String
            if r.match == .geosite {
                tag = "geosite-\(v)"
                url = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-\(v).srs"
            } else {
                tag = "geoip-\(v)"
                url = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-\(v).srs"
            }
            guard seen.insert(tag).inserted else { continue }
            out.append(["type": "remote", "tag": tag, "format": "binary", "url": url, "download_detour": detour])
        }
        return out
    }

    private func persistAndApply() {
        save()
        if KernelRunner.shared.isRunning {
            Task { await KernelRunner.shared.restart() }
        }
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL) {
            do {
                rules = try JSONDecoder().decode([RoutingRule].self, from: data)
            } catch {
                // 文件存在但解码失败（损坏/字段不兼容）：备份原文件，避免随后 save() 用空数据覆盖
                let backup = fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: fileURL, to: backup)
            }
        }
        // 仅首次（从未种过）且为空时，内置「国内 IP 直连」默认规则；
        // 之后即使用户清空也不再补，尊重其选择。
        let key = "rulesSeeded"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            if rules.isEmpty {
                rules = [RoutingRule(match: .geoip, value: "cn", action: .direct)]
                save()
            }
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(rules)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch { /* 尽力而为 */ }
    }
}
