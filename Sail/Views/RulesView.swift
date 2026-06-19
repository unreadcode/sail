import SwiftUI

/// 规则页：自定义分流规则（域名/IP → 代理/直连/拦截），优先级高于内置分流。
struct RulesView: View {
    @State private var store = RuleStore.shared
    @State private var editing: RoutingRule?
    @State private var adding = false

    var body: some View {
        Group {
            if store.rules.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text("自定义规则优先于内置分流，自上而下匹配；拖动可调整优先级。改动即时生效（重启内核）。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 12)
                    List {
                        ForEach(store.rules) { rule in
                            RuleRow(rule: rule, onEdit: { editing = rule })
                                .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                        .onMove { store.move(from: $0, to: $1) }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 0)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24).padding(.bottom, 16)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .help("添加规则")
            }
        }
        .sheet(isPresented: $adding) {
            RuleEditSheet(rule: RoutingRule()) { store.add($0) }
        }
        .sheet(item: $editing) { rule in
            RuleEditSheet(rule: rule) { store.update($0) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 88, height: 88)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 6) {
                Text("还没有自定义规则")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                Text("为指定域名 / IP 指定走代理、直连或拦截")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { adding = true } label: {
                Label("添加规则", systemImage: "plus").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 规则行

private struct RuleRow: View {
    let rule: RoutingRule
    var onEdit: () -> Void
    @State private var store = RuleStore.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(hovering ? .secondary : .tertiary)
                .help("拖动调整优先级")
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { store.setEnabled(rule.id, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.value.isEmpty ? "（空）" : rule.value)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Text(rule.match.label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            actionBadge
            if hovering {
                Button { onEdit() } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).help("编辑")
                Button(role: .destructive) { store.remove(rule.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("删除")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(hovering ? 0.8 : 0.4), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .opacity(rule.enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .onTapGesture { onEdit() }
    }

    private var actionBadge: some View {
        let color: Color = rule.action == .proxy ? .accentColor : (rule.action == .reject ? .red : .blue)
        return Text(rule.action.label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - 添加 / 编辑弹窗

private struct RuleEditSheet: View {
    @State var rule: RoutingRule
    var onSave: (RoutingRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("分流规则").font(.system(size: 16, weight: .semibold, design: .rounded))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("匹配方式").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(RuleMatch.allCases) { m in matchChip(m) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("内容").font(.caption).foregroundStyle(.secondary)
                TextField(rule.match.placeholder, text: $rule.value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                if let hint = rule.match.hint {
                    Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("去向").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $rule.action) {
                    ForEach(RuleAction.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(rule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(rule.value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { DispatchQueue.main.async { focused = false } }
    }

    private func matchChip(_ m: RuleMatch) -> some View {
        let on = rule.match == m
        return Button {
            rule.match = m
        } label: {
            Text(m.label)
                .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7).padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                )
                .foregroundStyle(on ? Color.white : .primary)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.15), value: on)
    }
}

#Preview {
    RulesView().frame(width: 760, height: 520)
}
