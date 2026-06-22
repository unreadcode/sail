import SwiftUI

/// 分组页：展示订阅生成的代理分组（selector / url-test）。
/// - selector：可点选成员手动切换（PUT /proxies/{group}）。
/// - url-test：内核按延迟自动选，这里只读高亮当前选择。
/// 每组可一键测速，成员显示最近延迟。数据来自内核 clash_api，2 秒轮询刷新。
struct GroupsView: View {
    @State private var store = ProxyGroupStore.shared

    /// 当前在左侧选中、右侧展示的分组名。持久化：切页/重启不丢（与概览同一套）。
    @AppStorage("groupsSelectedGroup") private var selectedGroup = ""

    // 右侧节点网格：自适应——每列约 260px，按可用宽度自动决定列数并拉伸填满，任意屏宽都不别扭
    private let columns = [GridItem(.adaptive(minimum: 260, maximum: .infinity), spacing: 8)]

    private var groups: [ProxyGroupStore.Group] { store.groups }

    /// 右侧展示的分组：优先用户点选的，否则第一个。
    private var current: ProxyGroupStore.Group? {
        if !selectedGroup.isEmpty, let g = groups.first(where: { $0.name == selectedGroup }) { return g }
        return groups.first
    }

    var body: some View {
        Group {
            if !groups.isEmpty {
                // 左分组栏 + 右节点：内核没跑时展示订阅持久化的结构（离线，只读）
                HStack(spacing: 0) {
                    groupSidebar
                    Divider()
                    memberDetail
                }
            } else if !KernelRunner.shared.isRunning {
                placeholder("内核未运行", "开启系统代理或 TUN 让内核运行，或先到「订阅」开启「应用订阅自带规则」并刷新订阅",
                            system: "powersleep")
            } else if store.loaded {
                placeholder("暂无代理分组",
                            "分组来自订阅自带的 proxy-groups：需在「规则」模式下、开启「应用订阅自带规则」并刷新订阅后生成",
                            system: "square.stack.3d.up.slash")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // 视图可见期间轮询；离开自动取消（.task 随视图生命周期）。
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: 左侧分组栏

    private var groupSidebar: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(groups) { g in
                    GroupRow(group: g, active: current?.name == g.name) { selectedGroup = g.name }
                }
            }
            .padding(8)
        }
        .frame(width: 230)
        .scrollIndicators(.hidden)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    // MARK: 右侧节点

    @ViewBuilder private var memberDetail: some View {
        if let group = current {
            let isSelector = group.kind == .selector
            let canSelect = isSelector   // selector 组随时可选；离线选择持久化，内核启动后生效
            VStack(spacing: 0) {
                detailHeader(group)
                Divider()
                ScrollView {
                    if !store.live {
                        offlineBanner.padding(.horizontal, 18).padding(.top, 14)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(group.members) { m in
                            MemberChip(member: m, selected: m.name == group.now, selectable: canSelect) {
                                if canSelect { Task { await store.select(group, m.name) } }
                            }
                        }
                    }
                    .padding(18)
                    .animation(.snappy(duration: 0.2), value: group.members)
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ group: ProxyGroupStore.Group) -> some View {
        let isSelector = group.kind == .selector
        let testing = store.testing.contains(group.name)
        return HStack(spacing: 10) {
            Text(group.name).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1)
            Text(isSelector ? "手动" : "自动")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((isSelector ? Color.accentColor : Color.mint).opacity(0.16), in: Capsule())
                .foregroundStyle(isSelector ? Color.accentColor : .mint)
            Text("\(group.members.count) 个节点").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { Task { await store.testGroup(group) } } label: {
                if testing { HStack(spacing: 5) { Spinner(size: 12); Text("测速中") } }
                else { Label("测速", systemImage: "gauge.with.dots.needle.bottom.50percent") }
            }
            .controlSize(.small)
            .disabled(testing || !store.live)
            .help(store.live ? "测速整组" : "内核未运行，无法测速")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// 离线提示条：内核未运行时，分组来自订阅持久化结构，仅供查看，切换/测速需内核。
    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz").font(.system(size: 12))
            Text("内核未运行：可正常选择节点（已记住，内核启动后生效），但暂不能测速。")
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func placeholder(_ title: String, _ desc: String, system: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: system)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(desc)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 左侧分组栏的一行

private struct GroupRow: View {
    let group: ProxyGroupStore.Group
    let active: Bool
    var onTap: () -> Void
    @State private var hover = false

    private var isSelector: Bool { group.kind == .selector }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(group.now.isEmpty ? "—" : group.now)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(isSelector ? "手动" : "自动")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 1.5)
                .background((isSelector ? Color.accentColor : Color.mint).opacity(0.16), in: Capsule())
                .foregroundStyle(isSelector ? Color.accentColor : .mint)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Color.accentColor.opacity(0.15)
                      : (hover ? Color(nsColor: .quaternaryLabelColor).opacity(0.3) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hover = $0 }
    }
}

// MARK: - 成员芯片

private struct MemberChip: View {
    let member: ProxyGroupStore.Member
    let selected: Bool
    let selectable: Bool
    var onTap: () -> Void
    @State private var hover = false

    private var parts: (flag: String, name: String) { NodeName.split(member.name) }

    private var borderColor: Color {
        if selected { return .accentColor }
        if hover && selectable { return Color.accentColor.opacity(0.5) }
        return Color(nsColor: .separatorColor).opacity(0.6)
    }

    var body: some View {
        HStack(spacing: 7) {
            if !parts.flag.isEmpty {
                Text(parts.flag).font(.system(size: 14))
            } else if member.isGroup {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(parts.name)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
            }
            DelayLabel(ms: member.delay)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(borderColor, lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { if selectable { onTap() } }
        .onHover { hover = $0 }
        .scaleEffect(hover && selectable ? 1.02 : 1)
        .animation(.snappy(duration: 0.16), value: hover)
        .animation(.snappy(duration: 0.2), value: selected)
        .help(selectable ? "点击切换到此成员" : member.name)
    }
}

private struct DelayLabel: View {
    let ms: Int?
    var body: some View {
        if let ms {
            Text("\(ms)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color(ms))
        } else {
            Text("—")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
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

#Preview {
    GroupsView().frame(width: 800, height: 600)
}
