import Foundation
import Observation

/// 当前出口 IP 信息。内核在跑时经本地混合端口查询（反映代理出口），否则直连（真实 IP）。
@MainActor
@Observable
final class IPInfo {
    static let shared = IPInfo()

    private(set) var ip: String?
    private(set) var location: String?
    private(set) var org: String?
    private(set) var loading = false
    private(set) var failed = false

    private init() {}

    func refresh() async {
        guard !loading else { return }
        loading = true
        failed = false
        defer { loading = false }
        let proxyPort = KernelRunner.shared.isRunning ? SettingsStore.shared.mixedPort : nil
        if let r = await Self.fetch(proxyPort: proxyPort) {
            ip = r.ip; location = r.location; org = r.org
        } else {
            failed = true
        }
    }

    private struct Result { var ip: String; var location: String; var org: String }

    nonisolated private static func fetch(proxyPort: Int?) async -> Result? {
        guard let url = URL(string: "http://ip-api.com/json/?lang=zh-CN&fields=status,country,regionName,city,isp,org,query") else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        if let port = proxyPort {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        } else {
            cfg.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: false,
                kCFNetworkProxiesHTTPSEnable as String: false,
                kCFNetworkProxiesSOCKSEnable as String: false,
            ]
        }
        guard let (data, resp) = try? await URLSession(configuration: cfg).data(for: URLRequest(url: url)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["status"] as? String) == "success" else { return nil }
        let ip = obj["query"] as? String ?? "—"
        let country = obj["country"] as? String ?? ""
        let city = obj["city"] as? String ?? ""
        let region = obj["regionName"] as? String ?? ""
        let loc = [country, city.isEmpty ? region : city].filter { !$0.isEmpty }.joined(separator: " · ")
        let org = (obj["isp"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (obj["org"] as? String) ?? ""
        return Result(ip: ip, location: loc.isEmpty ? "未知" : loc, org: org)
    }
}
