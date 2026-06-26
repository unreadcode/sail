import Foundation
import Observation

/// GEO 数据（sing-box 规则集 geosite-cn / geoip-cn）。
/// 首次运行从 app 内置副本播种到本地（seedFromBundleIfNeeded），故默认即用本地 rule_set——
/// 启动快、可离线，且内核启动不依赖「经节点下载 geo」（否则死节点会让内核致命退出）。
/// 「更新」会从 GitHub 拉最新 .srs 覆盖本地；下载经本地代理端口（GitHub 常被墙）。
@MainActor
@Observable
final class GeoData {
    static let shared = GeoData()

    static let geositeURL = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
    static let geoipURL = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"

    private(set) var updating = false
    private(set) var lastError: String?

    private init() {}

    nonisolated static var dir: URL { KernelPaths.supportDir.appendingPathComponent("geo", isDirectory: true) }
    nonisolated static var geositePath: URL { dir.appendingPathComponent("geosite-cn.srs") }
    nonisolated static var geoipPath: URL { dir.appendingPathComponent("geoip-cn.srs") }

    /// 本地两份规则都在 → makeConfig 改用 local rule_set。
    nonisolated static var hasLocal: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: geositePath.path) && fm.fileExists(atPath: geoipPath.path)
    }

    /// 某规则集 tag（如 geosite-category-ads-all / geoip-cn）的本地 .srs 路径，存在才返回。
    /// 供「本地优先」：已内置/已下载到本地的分类用 local rule_set，免去启动时经节点远程下载。
    nonisolated static func localRuleSet(_ tag: String) -> URL? {
        let p = dir.appendingPathComponent("\(tag).srs")
        return FileManager.default.fileExists(atPath: p.path) ? p : nil
    }

    /// 首次运行把 app 内置的 geo 规则集（包内所有 geosite-*/geoip-*.srs）播种到本地。
    /// 这样对应分类一开始就用本地 rule_set，无需启动时经（可能不通的）节点下载——
    /// 否则该下载失败会被 sing-box 当致命错误，导致内核起不来、陷入重启循环。用户仍可在设置里「更新」覆盖。
    nonisolated static func seedFromBundleIfNeeded() {
        let fm = FileManager.default
        let bundled = (Bundle.main.urls(forResourcesWithExtension: "srs", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("geosite-") || $0.lastPathComponent.hasPrefix("geoip-") }
        guard bundled.contains(where: { !fm.fileExists(atPath: dir.appendingPathComponent($0.lastPathComponent).path) })
        else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for src in bundled {
            let dest = dir.appendingPathComponent(src.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: src, to: dest) }
        }
    }

    var lastUpdated: Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: Self.geositePath.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date
    }

    func update() async {
        guard !updating else { return }
        updating = true
        lastError = nil
        defer { updating = false }

        // 内核在跑就经混合端口下载（GitHub 国内常被墙）；否则直连尝试。
        let proxyPort = KernelRunner.shared.isRunning ? SettingsStore.shared.mixedPort : nil
        do {
            try FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
            try await Self.download(Self.geositeURL, to: Self.geositePath, proxyPort: proxyPort)
            try await Self.download(Self.geoipURL, to: Self.geoipPath, proxyPort: proxyPort)
            // 已切到本地 rule_set，运行中则重启内核应用
            if KernelRunner.shared.isRunning { await KernelRunner.shared.restart() }
        } catch {
            lastError = (error as NSError).localizedDescription
        }
    }

    nonisolated private static func download(_ urlString: String, to dest: URL, proxyPort: Int?) async throws {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "geo", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL 无效"])
        }
        let cfg = URLSessionConfiguration.ephemeral
        if let port = proxyPort {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }   // 用完主动关连接，经 7890 时不给它留 TIME_WAIT
        let (data, resp) = try await session.data(for: URLRequest(url: url, timeoutInterval: 30))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw NSError(domain: "geo", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "下载失败 HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        // 完整性校验：sing-box .srs 以魔数 "SRS" 开头。上游不发布哈希，故用结构校验挡住
        // 限速 HTML 页 / 404 错误页 / 半截下载（这些不是 SRS 头或体积过小）。
        guard data.count > 64, data.prefix(3).elementsEqual([0x53, 0x52, 0x53]) else {
            throw NSError(domain: "geo", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "校验失败：返回内容不是有效的规则集（可能是限速页或被劫持的内容）"])
        }
        let tmp = dest.appendingPathExtension("tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: tmp, to: dest)
    }
}
