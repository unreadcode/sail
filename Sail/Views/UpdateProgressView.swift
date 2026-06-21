import SwiftUI

/// 更新进度小窗内容：下载（带百分比）→ 解压 → 即将重启。
struct UpdateProgressView: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("更新 Sail").font(.system(size: 14, weight: .semibold, design: .rounded))
                    if let v = updater.latest?.version {
                        Text("v\(v)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            switch updater.installPhase {
            case .downloading:
                VStack(spacing: 8) {
                    ProgressView(value: updater.downloadProgress)
                    HStack {
                        Text(sizeText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(updater.downloadProgress * 100))%")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("取消") { updater.cancelInstall() }
                            .controlSize(.small)
                    }
                }
            case .extracting:
                phaseBar("解压安装中…")
            case .restarting:
                phaseBar("即将重启 Sail…")
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    /// 「已下载 / 总大小」；总大小未知时退回「下载中…」。
    private var sizeText: String {
        guard updater.totalBytes > 0 else { return "下载中…" }
        return "\(formatBytes(Double(updater.downloadedBytes))) / \(formatBytes(Double(updater.totalBytes)))"
    }

    private func phaseBar(_ text: String) -> some View {
        VStack(spacing: 6) {
            ProgressView().progressViewStyle(.linear)   // 不确定进度的滚动条
            HStack { Text(text).font(.caption).foregroundStyle(.secondary); Spacer() }
        }
    }
}
