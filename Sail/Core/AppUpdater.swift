import Foundation
import Observation
import AppKit
import SwiftUI

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
    /// 安装阶段（驱动进度小窗显示）。
    enum InstallPhase: Equatable { case downloading, extracting, restarting }
    private(set) var installPhase: InstallPhase = .downloading
    private(set) var downloadProgress = 0.0   // 0…1
    private(set) var downloadedBytes: Int64 = 0   // 已下载字节
    private(set) var totalBytes: Int64 = 0        // 总字节（响应未给时为 0）
    /// 用户已忽略的版本（本次运行内不再提示）。
    private var dismissedVersion: String?
    /// 更新进度小窗。
    private var progressWindow: NSWindow?
    private var downloader: ProgressDownloader?
    private var userCancelled = false

    /// 下载阶段可取消（解压/重启已过临界点，不可取消）。
    var canCancel: Bool { installing && installPhase == .downloading }

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

    /// 一键下载并安装：弹小窗显示「下载进度 → 解压 → 即将重启」，完成后自动重启。无 zip 资产则退回浏览器。
    func downloadAndInstall() async {
        guard let latest else { return }
        guard let zipStr = latest.zipURL, let url = URL(string: zipStr) else {
            openDownload(); return
        }
        guard !installing else { return }
        installing = true; installError = nil; userCancelled = false
        installPhase = .downloading; downloadProgress = 0; downloadedBytes = 0; totalBytes = 0
        presentProgressWindow()
        do {
            // 1) 下载（带进度回调，可取消）
            var req = URLRequest(url: url, timeoutInterval: 300)
            req.setValue("Sail", forHTTPHeaderField: "User-Agent")
            let dl = ProgressDownloader { p, written, total in
                Task { @MainActor in
                    let u = AppUpdater.shared
                    u.downloadProgress = p; u.downloadedBytes = written; u.totalBytes = total
                }
            }
            downloader = dl
            let zip = try await dl.run(req)
            downloader = nil
            // 2) 解压 + 验签 + 布置换包助手（过了这里就不可取消）
            installPhase = .extracting
            try await Self.extractVerifyStage(zipAt: zip)
            // 3) 即将重启：退出本进程，助手脚本接管换包并重新打开
            installPhase = .restarting
            try? await Task.sleep(for: .milliseconds(500))   // 让小窗显示「即将重启」
            NSApp.terminate(nil)
        } catch {
            // 用户取消 → 干净复位，不报错；其它错误 → 显示在「设置→关于」
            if !userCancelled {
                installError = (error as? KernelError)?.description ?? error.localizedDescription
            }
            downloader = nil
            userCancelled = false
            installing = false
            closeProgressWindow()
        }
    }

    /// 取消更新（仅下载阶段有效）：中断下载、关窗、复位。
    func cancelInstall() {
        guard canCancel else { return }
        userCancelled = true
        downloader?.cancel()
    }

    // MARK: 进度小窗

    private func presentProgressWindow() {
        guard progressWindow == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 150),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingView(rootView: UpdateProgressView())
        w.contentView = host
        w.setContentSize(host.fittingSize)   // 按内容自适应高度
        w.center()
        w.level = .floating
        NSApp.setActivationPolicy(.regular)   // 确保小窗可见（即便之前在托盘）
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        progressWindow = w
    }

    private func closeProgressWindow() {
        progressWindow?.close()
        progressWindow = nil
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

    // MARK: - 解压 + 验签 + 布置换包助手（下载已单独完成）

    nonisolated private static func extractVerifyStage(zipAt zip: URL) async throws {
        let installPath = Bundle.main.bundlePath
        let parent = (installPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw KernelError.message("无法写入 \(parent)，请把 Sail 拖到「应用程序」后再更新")
        }
        let fm = FileManager.default
        let work = zip.deletingLastPathComponent()
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
        try p.run()   // 助手已就绪，等调用方退出本进程后接管
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

/// 带进度回调的下载器（URLSessionDownloadDelegate）；下载到临时文件并搬走返回。
private final class ProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let onProgress: @Sendable (Double, Int64, Int64) -> Void

    init(onProgress: @escaping @Sendable (Double, Int64, Int64) -> Void) { self.onProgress = onProgress }

    func run(_ req: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let t = s.downloadTask(with: req)
            lock.lock(); continuation = cont; session = s; task = t; lock.unlock()
            t.resume()
        }
    }

    /// 取消下载（触发 didCompleteWithError(cancelled) → run 抛错）。
    func cancel() {
        lock.lock(); let t = task; lock.unlock()
        t?.cancel()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        if total > 0 { onProgress(min(1, Double(written) / Double(total)), written, total) }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(KernelError.message("下载失败（HTTP \(http.statusCode)）"))); return
        }
        // 回调返回后临时文件即被删，必须同步搬走（搬到独立工作目录，供后续解压）
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("sail-update-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dst = work.appendingPathComponent("Sail.app.zip")
            try FileManager.default.moveItem(at: location, to: dst)
            finish(.success(dst))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation; continuation = nil
        let s = session; session = nil
        task = nil
        lock.unlock()
        s?.finishTasksAndInvalidate()
        guard let cont else { return }
        switch result {
        case .success(let u): cont.resume(returning: u)
        case .failure(let e): cont.resume(throwing: e)
        }
    }
}
