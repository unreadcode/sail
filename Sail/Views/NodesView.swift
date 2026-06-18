import SwiftUI

/// 节点页：展示「当前订阅」的节点，支持搜索 / 协议筛选 / 测速 / 选择。
struct NodesView: View {
    @State private var store = SubscriptionStore.shared
    @State private var tester = LatencyTester.shared
    @State private var search = ""
    @State private var protocolFilter: String?
    @State private var sortByLatency = false

    private var sub: Subscription? { store.selectedSubscription }
    private var nodes: [ProxyNode] { sub?.nodes ?? [] }

    private var breakdown: [(proto: String, count: Int)] {
        Dictionary(grouping: nodes, by: \.type)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private var filtered: [ProxyNode] {
        let base = nodes.filter { node in
            (protocolFilter == nil || node.type == protocolFilter)
                && (search.isEmpty
                    || node.label.localizedCaseInsensitiveContains(search)
                    || node.server.localizedCaseInsensitiveContains(search))
        }
        guard sortByLatency else { return base }
        // 已测最快在前；测速中 / 未测 / 超时依次靠后（稳定排序保留原相对顺序）
        func key(_ node: ProxyNode) -> Int {
            switch tester.result(for: node) {
            case .ok(let ms): return ms
            case .testing: return Int.max - 2
            case .none: return Int.max - 1
            case .timeout: return Int.max
            }
        }
        return base.enumerated()
            .sorted { (key($0.element), $0.offset) < (key($1.element), $1.offset) }
            .map(\.element)
    }

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: .infinity), spacing: 12)]

    var body: some View {
        Group {
            if sub == nil {
                placeholder("未选择订阅", "到「订阅」页选一个订阅，这里显示它的节点", system: "antenna.radiowaves.left.and.right")
            } else if nodes.isEmpty {
                placeholder("该订阅暂无节点", "在「订阅」页更新一下试试", system: "tray")
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    grid
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: sub?.id) { _, _ in search = ""; protocolFilter = nil }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(sub?.name ?? "")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text("\(nodes.count)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
                Spacer()
                Picker("", selection: $sortByLatency) {
                    Text("默认").tag(false)
                    Text("延迟").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("排序：默认顺序 / 延迟低→高")
                Button { Task { await tester.testAll(nodes) } } label: {
                    if tester.running {
                        HStack(spacing: 5) { Spinner(size: 12); Text("测速中") }
                    } else {
                        Label("测速", systemImage: "bolt.horizontal")
                    }
                }
                .controlSize(.small)
                .disabled(tester.running || nodes.isEmpty)
            }

            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("搜索节点", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.4), in: Capsule())
                .frame(maxWidth: 240)

                if !breakdown.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ProtoChip(label: "全部", count: nodes.count, active: protocolFilter == nil) {
                                protocolFilter = nil
                            }
                            ForEach(breakdown, id: \.proto) { item in
                                ProtoChip(label: item.proto.uppercased(), count: item.count,
                                          active: protocolFilter == item.proto,
                                          tint: ProtocolStyle.color(item.proto)) {
                                    protocolFilter = (protocolFilter == item.proto) ? nil : item.proto
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(filtered) { node in
                    NodeCard(node: node, selected: store.isSelected(node)) {
                        Task { await store.selectNode(node) }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .animation(.snappy(duration: 0.25), value: filtered)
        }
        .scrollIndicators(.hidden)
    }

    private func placeholder(_ title: String, _ desc: String, system: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: system)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(desc).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 协议筛选 chip

private struct ProtoChip: View {
    let label: String
    let count: Int
    var active: Bool
    var tint: Color = .accentColor
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label).font(.system(size: 10, weight: .semibold, design: .monospaced))
                Text("\(count)").font(.system(size: 10, weight: .medium, design: .monospaced)).opacity(0.7)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(active ? tint.opacity(0.18) : Color(nsColor: .quaternaryLabelColor).opacity(0.4), in: Capsule())
            .foregroundStyle(active ? tint : Color.secondary)
            .overlay(Capsule().strokeBorder(active ? tint.opacity(0.4) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 节点卡片

private struct NodeCard: View {
    let node: ProxyNode
    let selected: Bool
    var onSelect: () -> Void
    @State private var hovering = false

    private var parts: (flag: String, name: String) { NodeName.split(node.label) }
    private var tint: Color { ProtocolStyle.color(node.type) }

    private var borderColor: Color {
        if selected { return Color.accentColor }
        if hovering { return tint.opacity(0.5) }
        return Color(nsColor: .separatorColor).opacity(0.6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(parts.flag.isEmpty ? "🌐" : parts.flag).font(.system(size: 20))
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.accentColor)
                }
                Text(node.type.uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(tint.opacity(0.16), in: Capsule())
                    .foregroundStyle(tint)
            }
            Text(parts.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(node.server)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { Task { await LatencyTester.shared.testOne(node) } } label: {
                    LatencyBadge(result: LatencyTester.shared.result(for: node))
                        .frame(minWidth: 24, minHeight: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击测速该节点")
            }
        }
        .padding(12)
        .frame(height: 104, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor, lineWidth: selected ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: 8, y: 4)
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.snappy(duration: 0.18), value: hovering)
        .animation(.snappy(duration: 0.2), value: selected)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
        .help("点击设为当前节点")
    }
}

private struct LatencyBadge: View {
    let result: LatencyTester.Result?

    var body: some View {
        switch result {
        case .none:
            Image(systemName: "bolt.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        case .testing:
            Spinner(size: 11)
        case .timeout:
            Text("超时")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.red)
        case .ok(let ms):
            Text("\(ms)ms")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color(ms))
        }
    }

    private func color(_ ms: Int) -> Color {
        switch ms {
        case ..<200: .green
        case ..<500: .yellow
        default: .orange
        }
    }
}

// MARK: - 协议配色 / 名称解析

enum ProtocolStyle {
    static func color(_ type: String) -> Color {
        switch type.lowercased() {
        case "tuic": .indigo
        case "anytls": .teal
        case "naive": .orange
        case "vmess": .blue
        case "vless": .purple
        case "trojan": .pink
        case "shadowsocks", "ss": .green
        case "hysteria2", "hysteria", "hy2": .mint
        default: .gray
        }
    }
}

enum NodeName {
    /// 拆出名称开头的国旗 / emoji 与其余文本。
    static func split(_ name: String) -> (flag: String, name: String) {
        var flag = ""
        var idx = name.startIndex
        while idx < name.endIndex {
            let ch = name[idx]
            let isFlag = ch.unicodeScalars.allSatisfy { s in
                (s.value >= 0x1F1E6 && s.value <= 0x1F1FF)
                    || (s.properties.isEmojiPresentation && s.value >= 0x1F000)
            }
            if isFlag {
                flag.append(ch)
                idx = name.index(after: idx)
            } else { break }
        }
        let rest = String(name[idx...]).trimmingCharacters(in: .whitespaces)
        return (flag, rest.isEmpty ? name : rest)
    }
}

#Preview {
    NodesView().frame(width: 800, height: 600)
}
