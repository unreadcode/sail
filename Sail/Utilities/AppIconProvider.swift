import AppKit

/// 按可执行文件路径取图标，带缓存（icon(forFile:) 不便宜）。
/// - 路径在某 .app 包内（如 Chrome 的辅助进程）→ 取该 app 的图标；
/// - 否则（/usr/bin/curl 这类 CLI）→ 取文件本身图标，即 Finder 里显示的通用可执行图标。
@MainActor
enum AppIconProvider {
    private static var cache: [String: NSImage] = [:]

    static func icon(forExecutablePath path: String) -> NSImage {
        let resolved = bundlePath(for: path) ?? path
        if let hit = cache[resolved] { return hit }
        let img = NSWorkspace.shared.icon(forFile: resolved)
        cache[resolved] = img
        return img
    }

    /// 若路径位于某 .app 包内，返回最外层 .app 路径（Chrome 辅助进程 → Google Chrome.app）。
    private static func bundlePath(for path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}
