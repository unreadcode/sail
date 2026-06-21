import Foundation
import Observation

/// 内核管理：检测 / 下载 / 更新 / 卸载 sing-box。
/// 逻辑对齐参考项目 application/kernel/kernel.go。
@MainActor
@Observable
final class KernelManager {
    /// sing-box 官方仓库
    nonisolated static let repo = "SagerNet/sing-box"

    struct Status {
        var installed = false
        var version = ""
        var path = ""
    }

    // MARK: 对外状态（驱动 UI）
    var status = Status()
    var latest = ""
    var busy = false
    var progress = 0.0
    var statusMessage = ""
    var errorMessage = ""

    var updatable: Bool { status.installed && !latest.isEmpty && status.version != latest }
    var upToDate: Bool { status.installed && !latest.isEmpty && status.version == latest }

    // MARK: 路径

    private var installDir: URL { KernelPaths.kernelDir }
    private var binaryURL: URL { KernelPaths.binary }

    // MARK: 动作

    /// 刷新本地状态与远端最新版本（用于首次加载与「检查更新」）
    func refresh() async {
        await refreshStatus()
        await refreshLatest()
    }

    /// 仅刷新本地安装状态（不触网，避免 GitHub 限速）
    private func refreshStatus() async {
        let path = binaryURL.path
        status = await Task.detached { Self.probeStatus(binaryPath: path) }.value
    }

    /// 仅查询远端最新版本；失败时保留上次已知值，不清空
    private func refreshLatest() async {
        do {
            latest = try await Self.fetchLatest()
        } catch {
            // 离线 / 限速时忽略，保留上次结果，不打扰用户
        }
    }

    /// 下载并安装指定版本（去掉前缀 v）；version 为空时安装最新版（即「更新」）
    func install(version requested: String? = nil) async {
        guard !busy else { return }
        busy = true
        errorMessage = ""
        progress = 0
        statusMessage = "准备中 …"
        defer { busy = false }

        do {
            let installingLatest = (requested ?? "").isEmpty
            var version = requested ?? ""
            if version.isEmpty { version = try await Self.fetchLatest() }
            if version.hasPrefix("v") { version = String(version.dropFirst()) }

            // 仅支持 Apple 芯片（darwin/arm64）
            let asset = "sing-box-\(version)-darwin-arm64.tar.gz"
            guard let url = URL(string: "https://github.com/\(Self.repo)/releases/download/v\(version)/\(asset)") else {
                throw KernelError.message("下载地址无效")
            }

            statusMessage = "下载 sing-box \(version) …"
            let archive = try await download(url: url)

            statusMessage = "解压中 …"
            let dst = binaryURL
            let dir = installDir
            let expected = version
            try await Task.detached {
                let data = try Self.extractBinary(archive: archive)
                try Self.installBinary(data: data, to: dst, dir: dir, expectedVersion: expected)
            }.value

            statusMessage = "安装完成"
            // 只刷新本地状态：刚装的版本即为已知最新，无需再打一次 GitHub（省限速、避免 latest 被清空）
            await refreshStatus()
            if installingLatest || latest.isEmpty { latest = version }
        } catch {
            errorMessage = (error as? KernelError)?.description ?? error.localizedDescription
            statusMessage = ""
        }
    }

    /// 重新安装：停内核 → 下载最新并校验替换（install 内部删旧换新，校验全过才删旧）→
    /// 若装了特权组件，再把新内核同步到 root 副本（TUN/helper 以 root 跑的就是它，需一次管理员授权）→ 还原运行。
    /// 用于内核疑似损坏或想强制刷新到最新。
    func reinstall() async {
        guard !busy else { return }
        let runner = KernelRunner.shared
        let wasRunning = runner.runState == .running || runner.runState == .starting
        let syncPrivileged = HelperManager.isInstalled   // 装了 TUN 服务则同步 root 副本，保持两份一致

        if wasRunning { await runner.stop() }     // 先停，释放对二进制的占用，干净替换
        await install()                            // 复用：下载→校验→原子换新（失败则旧二进制保留）

        // TUN/helper：把刚校验落盘的新内核同步到 root-only 副本（经管理员授权的特权拷贝）
        if syncPrivileged, errorMessage.isEmpty {
            busy = true   // install() 已退出 busy，这里自管一段，卡片显示进行中而非空闲
            statusMessage = "同步特权内核副本（需管理员授权）…"
            let ok = await HelperManager.installPrivilegedKernel(from: binaryURL.path)
            busy = false
            if !ok { errorMessage = "特权内核副本同步失败（未授权？）——TUN 模式仍会用旧内核" }
        }

        if wasRunning { await runner.start() }     // 还原运行：成功跑新内核，失败回退跑旧内核
    }

    /// 卸载本地内核
    func remove() async {
        guard !busy else { return }
        busy = true
        errorMessage = ""
        defer { busy = false }

        let url = binaryURL
        do {
            try await Task.detached {
                let fm = FileManager.default
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }
            }.value
            statusMessage = "已卸载"
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 下载（带进度）

    private func download(url: URL) async throws -> URL {
        let downloader = Downloader { [weak self] p in
            guard let self else { return }
            Task { @MainActor in self.progress = p }
        }
        return try await downloader.run(url)
    }

    // MARK: 纯函数实现（后台线程执行）

    /// 检测本地内核安装状态及版本
    nonisolated private static func probeStatus(binaryPath: String) -> Status {
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            return Status(installed: false, version: "", path: binaryPath)
        }
        var version = ""
        if let out = try? runProcess(binaryPath, ["version"]) {
            version = parseVersion(out)
        }
        return Status(installed: true, version: version, path: binaryPath)
    }

    /// 查询 GitHub 最新稳定版 tag（去掉前缀 v）
    nonisolated static func fetchLatest() async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw KernelError.message("API 地址无效")
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Sail", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw KernelError.message("GitHub API 返回状态 \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        struct Release: Decodable { let tag_name: String }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let tag = release.tag_name
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// 运行 `sing-box version` 并解析版本号
    nonisolated private static func parseVersion(_ out: String) -> String {
        let firstLine = out.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? out
        let fields = firstLine.split(separator: " ").map(String.init)
        if let i = fields.firstIndex(of: "version"), i + 1 < fields.count {
            return fields[i + 1]
        }
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func runProcess(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 从 tar.gz 中取出 sing-box 二进制（用系统 /usr/bin/tar 解压）
    nonisolated private static func extractBinary(archive: URL) throws -> Data {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: workDir)
            try? fm.removeItem(at: archive)
        }

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", workDir.path]
        let errPipe = Pipe()
        tar.standardError = errPipe
        try tar.run()
        tar.waitUntilExit()
        if tar.terminationStatus != 0 {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw KernelError.message("解压失败：\(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        guard let bin = findBinary(in: workDir, named: "sing-box") else {
            throw KernelError.message("压缩包中未找到 sing-box")
        }
        return try Data(contentsOf: bin)
    }

    nonisolated private static func findBinary(in dir: URL, named name: String) -> URL? {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    /// 原子安装 + 完整性校验：写临时文件 → 校验是可运行的 Mach-O 且版本相符 → rename 覆盖。
    /// 上游不发布哈希，故用「结构校验 + 跑起来报版本」做功能性校验，挡住限速 HTML 页 /
    /// 损坏包 / 错架构 / 被替换的二进制（跑不起来或版本对不上即拒绝落盘）。
    nonisolated private static func installBinary(data: Data, to binaryURL: URL, dir: URL, expectedVersion: String) throws {
        let fm = FileManager.default
        // 1) 结构校验：必须是 Mach-O（挡住 HTML / 文本 / 损坏内容）
        guard isMachO(data) else {
            throw KernelError.message("下载内容不是有效的可执行文件（可能被限速页或网络劫持污染）")
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = binaryURL.appendingPathExtension("tmp")
        if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        // 2) 功能校验：能跑起来并报出版本（同时验证架构正确——错架构会 exec 失败）
        let reported = parseVersion((try? runProcess(tmp.path, ["version"])) ?? "")
        guard !reported.isEmpty else {
            try? fm.removeItem(at: tmp)
            throw KernelError.message("内核无法运行或架构不匹配，已拒绝安装")
        }
        // 3) 版本校验：与请求版本一致（下的是 v<version> 资产，理应相符；不符可能被换包）
        if !expectedVersion.isEmpty, reported != expectedVersion {
            try? fm.removeItem(at: tmp)
            throw KernelError.message("版本校验不符：期望 \(expectedVersion)，实际 \(reported)，已拒绝安装")
        }
        if fm.fileExists(atPath: binaryURL.path) {
            try fm.removeItem(at: binaryURL)
        }
        try fm.moveItem(at: tmp, to: binaryURL)
    }

    /// 是否为 Mach-O 可执行（含通用二进制 fat）。
    nonisolated private static func isMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let head = Array(data.prefix(4))
        let magics: [[UInt8]] = [
            [0xCF, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCF],   // Mach-O 64（小端 / 大端）
            [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA],   // 通用二进制 fat
        ]
        return magics.contains(head)
    }
}

enum KernelError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let m): m
        }
    }
}

/// 基于 URLSession 下载委托的下载器，按字节比例回调进度
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private let onProgress: @Sendable (Double) -> Void

    nonisolated init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    /// 原子地取出 continuation 并恢复一次：多次调用只有第一次生效，杜绝 double-resume 崩溃，
    /// 也用锁消除「调用线程写 / delegate 队列读」的内存可见性隐患。
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let s = session
        session = nil
        lock.unlock()
        // delegate 型 URLSession 会强引用 delegate(self) 且不自动释放，必须显式 invalidate 才能断环回收
        s?.finishTasksAndInvalidate()
        guard let cont else { return }
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let err): cont.resume(throwing: err)
        }
    }

    nonisolated func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            var req = URLRequest(url: url, timeoutInterval: 300)
            req.setValue("Sail", forHTTPHeaderField: "User-Agent")
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            lock.lock(); continuation = cont; session = s; lock.unlock()
            s.downloadTask(with: req).resume()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(KernelError.message("下载返回状态 \(http.statusCode)")))
            return
        }
        // 委托回调返回后临时文件即被删除，必须在此同步移走
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tar.gz")
        do {
            try FileManager.default.moveItem(at: location, to: dst)
            finish(.success(dst))
        } catch {
            finish(.failure(error))
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        // 成功路径已由 didFinishDownloadingTo 处理（finish 幂等，这里只兜失败）
        if let error { finish(.failure(error)) }
    }
}
