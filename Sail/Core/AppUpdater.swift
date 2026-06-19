import Foundation
import Observation
import AppKit

/// Sail 自身的更新：查 GitHub releases 最新 tag 与本机比较；有新版可一键「下载并安装」——
/// 下载 Sail.app.zip（URLSession 自取，不带 quarantine，故无需用户再跑 xattr）→ 解压验签 →
/// 助手脚本等本进程退出后换包 → 自动重启。无 zip 资产时退回打开下载页。
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    nonisolated static let repo = "unreadcode/sail"

    struct Release: Equatable {
        let version: String     // 去掉 v 前缀，如 "1.0.1"
        let pageURL: String     // release 页面
        let dmgURL: String?     // DMG 直链（给浏览器下载兜底）
        let zipURL: String?     // Sail.app.zip 直链（app 内自动更新用）
    }

    private(set) var latest: Release?
    private(set) var checking = false
    private(set) var lastError: String?
    /// 正在下载/安装更新。
    private(set) var installing = false
    private(set) var installError: String?
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

    /// 一键下载并安装：有 zip 资产则自动更新；否则退回打开下载页。
    func downloadAndInstall() async {
        guard let latest else { return }
        guard let zip = latest.zipURL, let url = URL(string: zip) else {
            openDownload(); return   // 旧 release 无 zip → 退回浏览器
        }
        guard !installing else { return }
        installing = true; installError = nil
        defer { installing = false }
        do {
            try await Self.downloadAndSwap(zipURL: url)   // 成功不会正常返回：会退出 app 让助手接管
        } catch {
            installError = (error as? KernelError)?.description ?? error.localizedDescription
        }
    }

    /// 打开下载：优先 DMG 直链，否则 release 页面。
    func openDownload() {
        guard let latest, let url = URL(string: latest.dmgURL ?? latest.pageURL) else { return }
        NSWorkspace.shared.open(url)
    }

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
        let zip = rel.assets.first { $0.name.lowercased().hasSuffix(".zip") }?.browser_download_url
        return Release(version: ver, pageURL: rel.html_url, dmgURL: dmg, zipURL: zip)
    }

    // MARK: - 下载并替换自身

    nonisolated private static func downloadAndSwap(zipURL: URL) async throws {
        let installPath = Bundle.main.bundlePath
        let parent = (installPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw KernelError.message("无法写入 \(parent)，请把 Sail 拖到「应用程序」后再更新")
        }

        var req = URLRequest(url: zipURL, timeoutInterval: 120)
        req.setValue("Sail", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw KernelError.message("下载失败（HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)）")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("sail-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("Sail.app.zip")
        try fm.moveItem(at: tmp, to: zip)

        let extract = work.appendingPathComponent("extract")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, extract.path])
        let newApp = extract.appendingPathComponent("Sail.app")
        guard fm.fileExists(atPath: newApp.path) else { throw KernelError.message("更新包内未找到 Sail.app") }
        // 验签：仅做完整性校验（ad-hoc 无法验来源真伪），挡住损坏 / 半截下载
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])

        // 助手脚本：等本进程退出 → 换包 → 重开（脱离本进程，app 退出后仍在跑）
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        rm -rf \(shq(installPath))
        mv \(shq(newApp.path)) \(shq(installPath))
        open \(shq(installPath))
        rm -rf \(shq(work.path))
        """
        let sh = work.appendingPathComponent("swap.sh")
        try script.write(to: sh, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [sh.path]
        try p.run()

        await MainActor.run { NSApp.terminate(nil) }   // 退出，让助手接管换包+重启
    }

    /// 把字符串安全包进 shell 单引号。
    nonisolated private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw KernelError.message("\((tool as NSString).lastPathComponent) 失败（\(p.terminationStatus)）")
        }
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
