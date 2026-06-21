import SwiftUI

/// 流量统计页：把实时连接的用量按「域名 / 应用 / 协议 / 出站」累计（会话级，连接关闭也不丢），降序展示。
/// 与「连接」页互补——连接看当下、流量看累计。
struct TrafficView: View {
    @State private var monitor = TrafficMonitor.shared
    @State private var dimension: Dim = .domain

    enum Dim: String, CaseIterable, Identifiable {
        case domain, process, network, chain
        var id: String { rawValue }
        var label: String {
            switch self {
            case .domain: "域名"
            case .process: "应用"
            case .network: "协议"
            case .chain: "出站"
            }
        }
    }

    private var data: [(key: String, usage: TrafficMonitor.Usage)] {
        let dict: [String: TrafficMonitor.Usage]
        switch dimension {
        case .domain: dict = monitor.byDomain
        case .process: dict = monitor.byProcess
        case .network: dict = monitor.byNetwork
        case .chain: dict = monitor.byChain
        }
        return dict.map { (key: $0.key, usage: $0.value) }.sorted { $0.usage.total > $1.usage.total }
    }

    private var maxTotal: Double { data.first?.usage.total ?? 1 }
    private var grandTotal: Double { data.reduce(0) { $0 + $1.usage.total } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if data.isEmpty {
                placeholder
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $dimension) {
                ForEach(Dim.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            Text("合计 \(formatBytes(grandTotal))")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Button { monitor.resetStats() } label: {
                Label("重置", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.small).disabled(data.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(data, id: \.key) { item in
                    row(item.key, item.usage)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .animation(.snappy(duration: 0.25), value: dimension)
        }
        .scrollIndicators(.hidden)
    }

    /// 「应用」维度的前置图标：有路径取 app/可执行图标，无（未知）则占位符。
    @ViewBuilder
    private func processIcon(_ name: String) -> some View {
        if let path = monitor.processPaths[name], !path.isEmpty {
            Image(nsImage: AppIconProvider.icon(forExecutablePath: path))
                .resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
    }

    private func row(_ name: String, _ u: TrafficMonitor.Usage) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if dimension == .process { processIcon(name) }
                Text(name)
                    .font(.system(size: 12.5))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("↑\(formatBytes(u.up))  ↓\(formatBytes(u.down))")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                Text(formatBytes(u.total))
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 70, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                    Capsule().fill(Color.accentColor.opacity(0.65))
                        .frame(width: max(2, geo.size.width * (maxTotal > 0 ? u.total / maxTotal : 0)))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 30)).foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("暂无流量统计").font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("内核运行并产生流量后，这里按维度累计用量").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    TrafficView().frame(width: 720, height: 560)
}
