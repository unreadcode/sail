import Foundation
import Observation
import AppKit

/// Sail 自身的更新检查：查 GitHub releases 最新 tag，与本机版本比较，有新版则提示去下载。
/// 复用 KernelManager 的 GitHub releases 套路；只做「检查 + 提示 + 打开下载」，安装由用户拖入完成。
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// ⚠️ 开源后改成实际的 owner/repo。
    nonisolated static let repo = "unreadcode/sail"

    struct Release: Equatable {
        let version: String     // 去掉 v 前缀，如 "1.0.1"
        let pageURL: String     // release 页面
        let dmgURL: String?     // DMG 资产直链（若 release 附了 .dmg）
    }

    private(set) var latest: Release?
    private(set) var checking = false
    private(set) var lastError: String?
    /// 用户已忽略的版本（本次运行内不再提示）。
    private var dismissedVersion: String?

    private init() {}

    /// 本机版本（CFBundleShortVersionString）。
    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// 有可用更新：拿到 latest 且其版本严格大于当前、且未被忽略。
    var updateAvailable: Bool {
        guard let latest, latest.version != dismissedVersion else { return false }
        return Self.compareVersions(latest.version, current) > 0
    }

    func check() async {
        guard !checking else { return }
        checking = true
        lastError = nil
        defer { checking = false }
        do { latest = try await Self.fetchLatest() }
        catch { lastError = (error as? KernelError)?.description ?? error.localizedDescription }
    }

    /// 打开下载：优先 DMG 直链，否则 release 页面。
    func openDownload() {
        guard let latest, let url = URL(string: latest.dmgURL ?? latest.pageURL) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 本次运行内忽略当前最新版，不再提示。
    func dismissLatest() { dismissedVersion = latest?.version }

    // MARK: - GitHub API

    nonisolated private static func fetchLatest() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw KernelError.message("更新地址无效")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Sail", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw KernelError.message("检查更新失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)）")
        }
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct GHRelease: Decodable { let tag_name: String; let html_url: String; let assets: [Asset] }
        let rel = try JSONDecoder().decode(GHRelease.self, from: data)
        let ver = rel.tag_name.hasPrefix("v") ? String(rel.tag_name.dropFirst()) : rel.tag_name
        let dmg = rel.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url
        return Release(version: ver, pageURL: rel.html_url, dmgURL: dmg)
    }

    /// 语义版本比较：点分整数逐段比，返回 >0 表示 a 比 b 新。缺位补 0（1.0 == 1.0.0）。
    nonisolated static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
