import SwiftUI

/// 分组页：展示订阅生成的代理分组（selector / url-test）。
/// - selector：可点选成员手动切换（PUT /proxies/{group}）。
/// - url-test：内核按延迟自动选，这里只读高亮当前选择。
/// 每组可一键测速，成员显示最近延迟。数据来自内核 clash_api，2 秒轮询刷新。
struct GroupsView: View {
    @State private var store = ProxyGroupStore.shared

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: .infinity), spacing: 10)]

    var body: some View {
        Group {
            if !KernelRunner.shared.isRunning {
                placeholder("内核未运行", "开启系统代理或 TUN 让内核运行后，这里显示代理分组",
                            system: "powersleep")
            } else if store.loaded && store.groups.isEmpty {
                placeholder("暂无代理分组",
                            "分组来自订阅自带的 proxy-groups：需在「规则」模式下、开启「应用订阅自带规则」并刷新订阅后生成",
                            system: "square.stack.3d.up.slash")
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(store.groups) { group in
                            GroupCard(group: group, columns: columns,
                                      testing: store.testing.contains(group.name),
                                      onSelect: { m in Task { await store.select(group, m) } },
                                      onTest: { Task { await store.testGroup(group) } })
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .animation(.snappy(duration: 0.22), value: store.groups)
                }
                .scrollIndicators(.hidden)
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

// MARK: - 分组卡片

private struct GroupCard: View {
    let group: ProxyGroupStore.Group
    let columns: [GridItem]
    let testing: Bool
    var onSelect: (String) -> Void
    var onTest: () -> Void

    private var isSelector: Bool { group.kind == .selector }

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(group.name)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(isSelector ? "手动" : "自动")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background((isSelector ? Color.accentColor : Color.mint).opacity(0.16), in: Capsule())
                        .foregroundStyle(isSelector ? Color.accentColor : .mint)
                    Text("\(group.members.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(group.now)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .trailing)
                    Button(action: onTest) {
                        if testing { Spinner(size: 12) }
                        else { Image(systemName: "bolt.horizontal").font(.system(size: 11)) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(testing)
                    .help("测速整组")
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(group.members) { m in
                        MemberChip(member: m, selected: m.name == group.now, selectable: isSelector) {
                            if isSelector { onSelect(m.name) }
                        }
                    }
                }
            }
        }
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
