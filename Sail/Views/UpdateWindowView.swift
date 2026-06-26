import SwiftUI

/// 更新独立窗口内容：头部（新版本号）+ 更新日志，底部未安装时是「取消 / 更新」，
/// 点「更新」后底部就地切换为下载 → 解压 → 即将重启 的进度（不再另开进度窗）。
/// 由 `AppUpdater.showUpdateWindow()` 托管为独立 NSWindow；「设置 › 关于」「查看更新」与侧栏 NEW 角标都开它。
struct UpdateWindowView: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部
            HStack(spacing: 12) {
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("发现新版本").font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("v\(updater.latest?.version ?? "") · 当前 v\(updater.current)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            // 更新日志
            ScrollView {
                Text(notesAttributed(updater.changelog ?? "本次更新暂无说明。"))
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))

            // 底部：未安装 → 取消 / 更新；安装中 → 进度（各状态都单行，窗口高度稳定）
            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    @ViewBuilder private var footer: some View {
        if updater.installing {
            switch updater.installPhase {
            case .downloading:
                HStack(spacing: 12) {
                    ProgressView(value: updater.downloadProgress).frame(maxWidth: .infinity)
                    Text("\(Int(updater.downloadProgress * 100))%")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                    Button("取消") { updater.cancelInstall() }.controlSize(.small)
                }
            case .extracting:
                progressLine("解压安装中…")
            case .restarting:
                progressLine("即将重启 Sail…")
            }
        } else {
            HStack(spacing: 10) {
                if let err = updater.installError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("取消") { updater.closeUpdateWindow() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await updater.downloadAndInstall() }
                } label: {
                    Label(updater.installError == nil ? "更新" : "重试", systemImage: "arrow.down.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func progressLine(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().progressViewStyle(.linear).frame(maxWidth: .infinity)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// inlineOnlyPreservingWhitespace：保留换行 + 解析行内 markdown（加粗/链接/代码），块级（标题/列表）保持原样仍可读。
    private func notesAttributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
