import SwiftUI

/// 连接管理页：实时显示内核当前活动连接，支持搜索、按流量排序、关闭单条 / 全部。
/// 数据来自 TrafficMonitor 的 clash_api /connections 流。
struct ConnectionsView: View {
    @State private var monitor = TrafficMonitor.shared
    @State private var runner = KernelRunner.shared
    @State private var search = ""
    @State private var sort: Sort = .download

    enum Sort: String, CaseIterable { case download = "下行", upload = "上行", recent = "最新" }

    private var conns: [TrafficMonitor.Conn] {
        let base = monitor.connectionList.filter { c in
            search.isEmpty
                || c.host.localizedCaseInsensitiveContains(search)
                || c.process.localizedCaseInsensitiveContains(search)
                || c.chain.localizedCaseInsensitiveContains(search)
                || c.rule.localizedCaseInsensitiveContains(search)
        }
        switch sort {
        case .download: return base.sorted { $0.download > $1.download }
        case .upload:   return base.sorted { $0.upload > $1.upload }
        case .recent:   return base.sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
        }
    }

    var body: some View {
        Group {
            if !runner.isRunning {
                placeholder("内核未运行", "启动内核后这里显示实时连接", system: "bolt.horizontal.circle")
            } else if monitor.connectionList.isEmpty {
                placeholder("暂无活动连接", "有网络请求经过 Sail 时会出现在这里", system: "point.3.connected.trianglepath.dotted")
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("活动连接")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                Text("\(monitor.connections)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
                Spacer()
                Picker("", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button(role: .destructive) {
                    monitor.closeAll()
                } label: {
                    Label("全部关闭", systemImage: "xmark.circle")
                }
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("搜索 目标 / 进程 / 出站 / 规则", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.4), in: Capsule())
            .frame(maxWidth: 300)
        }
        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(conns) { c in
                    ConnRow(conn: c) { monitor.close(c.id) }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            .animation(.snappy(duration: 0.2), value: conns.map(\.id))
        }
        .scrollIndicators(.hidden)
    }

    private func placeholder(_ title: String, _ desc: String, system: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: system).font(.system(size: 30)).foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(desc).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ConnRow: View {
    let conn: TrafficMonitor.Conn
    var onClose: () -> Void
    @State private var hovering = false

    private var netColor: Color { conn.network == "udp" ? .orange : .blue }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !conn.process.isEmpty {
                        Text(conn.process)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                    }
                    Text(conn.host)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(conn.process.isEmpty ? .primary : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    tag(conn.network.uppercased(), netColor)
                    if !conn.chain.isEmpty { tag(conn.chain, .accentColor) }
                    if !conn.rule.isEmpty {
                        Text(conn.rule)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("↓ \(formatBytes(conn.download))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.green)
                Text("↑ \(formatBytes(conn.upload))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let start = conn.start {
                Text(duration(since: start))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 46, alignment: .trailing)
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(hovering ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help("关闭此连接")
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(hovering ? 0.9 : 0.5), lineWidth: 1)
        )
        .onHover { hovering = $0 }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func duration(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

#Preview {
    ConnectionsView().frame(width: 800, height: 600)
}
