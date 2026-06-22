import SwiftUI

struct OverviewView: View {
    private let runner = KernelRunner.shared
    private let monitor = TrafficMonitor.shared
    @State private var settings = SettingsStore.shared
    @State private var ipInfo = IPInfo.shared
    @State private var groupStore = ProxyGroupStore.shared
    @AppStorage("overviewPickedGroup") private var pickedGroup = ""   // 概览操作的分组（空=第一个）；持久化，切页/重启不丢
    @State private var appeared = false
    @State private var kernelVersion = "—"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusHero
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 14)
                HStack(alignment: .top, spacing: 18) {
                    networkCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ipInfoCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 14)
                .animation(.smooth(duration: 0.45).delay(0.06), value: appeared)
                metricsCard
                    .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 14)
                    .animation(.smooth(duration: 0.45).delay(0.12), value: appeared)
            }
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
            .padding(28)
            .animation(.smooth(duration: 0.45), value: appeared)
        }
        .scrollIndicators(.hidden)
        .onAppear { appeared = true; Task { await ipInfo.refresh() } }
        .onChange(of: runner.isRunning) { _, _ in Task { await ipInfo.refresh() } }
        .task {
            // 概览可见期间轮询代理分组（与分组页一致）；离开自动取消。
            while !Task.isCancelled {
                await groupStore.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("代理模式", selection: Binding(get: { settings.routeMode },
                                                  set: { settings.setRouteMode($0) })) {
                    ForEach(ProxyMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("代理模式：规则 / 全局 / 直连")
            }
        }
    }

    private var connected: Bool { runner.isRunning }

    // MARK: 状态横幅（节点 / 速率 / 流量）

    private var statusHero: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if hasGroups {
                        groupPicker
                        memberPicker
                    } else {
                        nodePicker
                        HStack(spacing: 12) { latencyBadge }
                    }
                }
                Spacer(minLength: 16)
                liveSpeeds
            }
            .padding(20)

            ZStack(alignment: .bottomLeading) {
                Sparkline(values: monitor.history, tint: .accentColor)
                    .frame(height: 52)
                    .opacity(connected ? 0.85 : 0.2)
                HStack {
                    Text("累计 ↓ \(formatBytes(monitor.totalDown))")
                    Spacer()
                    Text("↑ \(formatBytes(monitor.totalUp))")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18).padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    // MARK: 网络设置卡（系统代理 / 虚拟网卡 两个独立开关，可共存）

    private var networkCard: some View {
        Card(fillHeight: true) {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader("网络设置", icon: "network")
                toggleRow(
                    icon: "macwindow",
                    title: "系统代理",
                    subtitle: settings.systemProxyEnabled ? "已设为 macOS 系统代理" : "将 macOS 系统代理指向本地端口",
                    isOn: systemProxyBinding
                )
                toggleRow(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "虚拟网卡（TUN）",
                    subtitle: settings.tunEnabled ? "已接管全局流量" : "接管全局流量，需管理员权限",
                    isOn: tunBinding
                )
                if !runner.errorMessage.isEmpty && !connected {
                    hintBox(runner.errorMessage, warning: true)
                }
            }
        }
    }

    private var systemProxyBinding: Binding<Bool> {
        Binding(get: { settings.systemProxyEnabled },
                set: { v in Task { await settings.setSystemProxy(v) } })
    }

    private var tunBinding: Binding<Bool> {
        Binding(get: { settings.tunEnabled },
                set: { v in Task { await settings.setTunEnabled(v) } })
    }

    private func toggleRow(icon: String, title: String, subtitle: String,
                           isOn: Binding<Bool>, gear: (() -> Void)? = nil) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor).font(.system(size: 14)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let gear {
                Button { gear() } label: { Image(systemName: "gearshape").font(.system(size: 12)) }
                    .buttonStyle(.borderless).help("虚拟网卡配置")
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).disabled(runner.isBusy)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: IP 信息卡

    private var ipInfoCard: some View {
        Card(fillHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    cardHeader("IP 信息", icon: "mappin.and.ellipse")
                    Spacer()
                    if ipInfo.loading {
                        Spinner(size: 14)
                    } else {
                        Button { Task { await ipInfo.refresh() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderless).help("刷新出口 IP")
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    MetricItem(icon: "network", label: "出口 IP",
                               value: ipInfo.ip ?? (ipInfo.failed ? "获取失败" : "—"), mono: true)
                    MetricItem(icon: "globe.asia.australia", label: "位置", value: ipInfo.location ?? "—")
                    MetricItem(icon: "building.2", label: "运营商", value: ipInfo.org ?? "—")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func cardHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
        }
    }

    private func hintBox(_ text: String, warning: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: warning ? "exclamationmark.triangle" : "info.circle").font(.system(size: 10))
            Text(text).font(.system(size: 11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(warning ? Color.red : Color.secondary)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((warning ? Color.red.opacity(0.1) : Color(nsColor: .quaternaryLabelColor).opacity(0.25)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var store: SubscriptionStore { SubscriptionStore.shared }

    // MARK: 当前节点（可切换 —— 明显的下拉胶囊）

    /// 节点选择菜单：只列出「当前订阅」里的节点，选中即热切换出站。
    @ViewBuilder private var nodePicker: some View {
        Menu {
            let nodes = store.selectedSubscription?.nodes ?? []
            if nodes.isEmpty {
                Text("该订阅暂无节点")
            } else {
                ForEach(nodes) { node in
                    Button {
                        Task { await store.selectNode(node) }
                    } label: {
                        if store.isSelected(node) {
                            Label(node.label, systemImage: "checkmark")
                        } else {
                            Text(node.label)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 15)).foregroundStyle(Color.accentColor)
                Text(store.selectedNode?.label ?? "未选择节点")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .tint(.accentColor)
        .controlSize(.large)
        .fixedSize()
        .help("点击切换节点")
    }

    // MARK: 分组式选择（先选分组 → 再选组内节点）

    /// 内核生成的代理分组（订阅自带 proxy-groups）。有分组时概览改走两级选择。
    private var groups: [ProxyGroupStore.Group] { groupStore.groups }
    private var hasGroups: Bool { !groups.isEmpty }

    /// 当前在概览里操作的分组：优先用户选过的，否则取第一个（selector 已排在前）。
    private var activeGroup: ProxyGroupStore.Group? {
        if !pickedGroup.isEmpty, let g = groups.first(where: { $0.name == pickedGroup }) { return g }
        return groups.first
    }

    /// 分组选择（系统原生下拉选择框）：切换概览当前操作的分组。
    @ViewBuilder private var groupPicker: some View {
        Picker("分组", selection: Binding(
            get: { activeGroup?.name ?? "" },
            set: { pickedGroup = $0 }
        )) {
            ForEach(groups) { g in Text(g.name).tag(g.name) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 200, alignment: .leading)   // 左对齐，与下方节点框左边对齐，不居中
    }

    /// 节点选择（独立框）：左侧菜单选节点（展开每项后带延迟），右侧延迟/测速（hover 高亮、点击测速、转圈占位）。
    @ViewBuilder private var memberPicker: some View {
        let group = activeGroup
        let isSelector = group?.kind == .selector   // selector 组随时可选（离线持久化）；url-test 只读
        let testing = group.map { groupStore.testing.contains($0.name) } ?? false
        let nowDelay: Int? = group.map(\.now).flatMap { $0.isEmpty ? nil : resolveDelay($0) }
        HStack(spacing: 0) {
            Menu {
                if let group, !group.members.isEmpty {
                    if !isSelector { Text("自动分组：由内核按延迟选择，不可手动切换") }
                    else if !groupStore.live { Text("内核未运行：选择会被记住，启动后生效") }
                    ForEach(group.members) { m in
                        Button {
                            if isSelector { Task { await groupStore.select(group, m.name) } }
                        } label: {
                            let suffix = m.delay.map { "　\($0) ms" } ?? ""   // 每个节点后显示延迟
                            if m.name == group.now { Label("\(m.name)\(suffix)", systemImage: "checkmark") }
                            else { Text("\(m.name)\(suffix)") }
                        }
                        .disabled(!isSelector)
                    }
                } else { Text("该分组暂无成员") }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 15)).foregroundStyle(Color.accentColor)
                    Text(group?.now.isEmpty == false ? group!.now : "未选择节点")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 190, alignment: .leading)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help(isSelector ? "点击切换组内节点" : "自动分组，由内核按延迟选择")

            Divider().frame(height: 26)

            DelayPill(delay: nowDelay, testing: testing, enabled: groupStore.live,
                      color: groupLatencyColor(nowDelay)) {
                if let group { Task { await groupStore.testGroup(group) } }
            }
        }
        .fixedSize()   // 按内容收缩，永不超出父容器
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func groupLatencyColor(_ ms: Int?) -> Color {
        guard let ms else { return .secondary }
        return ms < 200 ? .green : (ms < 500 ? .orange : .red)
    }

    /// 解析某成员的有效延迟：成员本身是分组就递归跟到它的当前选择，直到落在真实节点取其延迟。
    private func resolveDelay(_ name: String, depth: Int = 0) -> Int? {
        guard depth < 6 else { return nil }
        if let g = groups.first(where: { $0.name == name }) {
            return g.now.isEmpty ? nil : resolveDelay(g.now, depth: depth + 1)
        }
        for grp in groups {
            if let m = grp.members.first(where: { $0.name == name }) { return m.delay }
        }
        return nil
    }

    private var latencyBadge: some View {
        Button {
            if let node = store.selectedNode {
                Task { await LatencyTester.shared.testOne(node) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.67percent").font(.system(size: 11))
                Text(latencyLabel)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(latencyColor)
        }
        .buttonStyle(.plain)
        .disabled(store.selectedNode == nil || LatencyTester.shared.running)
        .help("点击测试当前节点延迟")
    }

    private var latencyLabel: String {
        guard let node = store.selectedNode else { return "—" }
        switch LatencyTester.shared.result(for: node) {
        case .ok(let ms): return "\(ms) ms"
        case .testing: return "测速中…"
        case .timeout: return "超时"
        case nil: return "点击测速"
        }
    }

    private var latencyColor: Color {
        guard let node = store.selectedNode,
              case .ok(let ms) = LatencyTester.shared.result(for: node) else { return .secondary }
        return ms < 200 ? .green : (ms < 500 ? .orange : .red)
    }

    private var liveSpeeds: some View {
        HStack(spacing: 18) {
            speedReadout(systemImage: "arrow.down", bytes: monitor.down,
                         color: connected ? .accentColor : .secondary)
            speedReadout(systemImage: "arrow.up", bytes: monitor.up, color: .secondary)
        }
    }

    private func speedReadout(systemImage: String, bytes: Double, color: Color) -> some View {
        let parts = speedParts(bytes)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
            Text(parts.value).font(.system(size: 22, weight: .semibold, design: .monospaced))
            Text(parts.unit).font(.system(size: 10, design: .monospaced)).opacity(0.7)
        }
        .foregroundStyle(color)
    }

    // MARK: 运行指标

    private var uptimeText: String {
        guard runner.isRunning, let started = runner.startedAt else { return "—" }
        return formatUptime(Int(Date().timeIntervalSince(started)))
    }

    private var itemGrid: [GridItem] {
        [GridItem(.flexible(), spacing: 28, alignment: .leading),
         GridItem(.flexible(), spacing: 28, alignment: .leading)]
    }

    // MARK: 运行指标卡（整行，两列）

    private var metricsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                cardHeader("运行指标", icon: "chart.bar.xaxis")
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LazyVGrid(columns: itemGrid, alignment: .leading, spacing: 16) {
                        MetricItem(icon: "timer", label: "运行时间", value: uptimeText, mono: true)
                        MetricItem(icon: "arrow.left.arrow.right", label: "活动连接", value: runner.isRunning ? "\(monitor.connections)" : "0", mono: true)
                        MetricItem(icon: "memorychip", label: "内核占用", value: runner.isRunning ? formatBytes(monitor.memory) : "—", mono: true)
                        MetricItem(icon: "shippingbox", label: "内核版本", value: kernelVersion, mono: true)
                        MetricItem(icon: "sailboat", label: "Sail 占用", value: formatBytes(SystemInfo.appMemoryBytes()), mono: true)
                        MetricItem(icon: "tag", label: "Sail 版本", value: SystemInfo.appVersion, mono: true)
                    }
                }
            }
        }
        .task {
            kernelVersion = await Task.detached { SystemInfo.kernelVersion() }.value ?? "未安装"
        }
    }

}

/// 选择框内的延迟/测速一体按钮：显示「—」或「X ms」，hover 高亮，点击测速；测速中转圈占位。
private struct DelayPill: View {
    let delay: Int?
    let testing: Bool
    let enabled: Bool
    let color: Color
    var onTest: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onTest) {
            ZStack {
                // 文本与转圈叠放、宽度固定：切换时不改变布局，杜绝闪动
                Text(delay.map { "\($0) ms" } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
                    .opacity(testing ? 0 : 1)
                if testing { Spinner(size: 13) }
            }
            .frame(width: 64)
            .padding(.vertical, 9)
            .frame(maxHeight: .infinity)
            .background(hover && enabled && !testing ? Color.accentColor.opacity(0.18) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(testing || !enabled)
        .onHover { hover = $0 }
        .help(enabled ? "点击测速当前节点" : "内核未运行，无法测速")
    }
}

/// 把字节速率拆成数值与单位，便于大小字号分排。
private func speedParts(_ bytes: Double) -> (value: String, unit: String) {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var n = bytes
    var i = 0
    while n >= 1024 && i < units.count - 1 { n /= 1024; i += 1 }
    let v = n < 10 && i > 0 ? String(format: "%.1f", n) : String(Int(n.rounded()))
    return (v, units[i] + "/s")
}

/// 折线图：填充渐变 + 描边。
private struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxV = max(values.max() ?? 1, 1)
            let n = max(values.count - 1, 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: w * CGFloat(i) / CGFloat(n), y: h - (CGFloat(v / maxV) * h * 0.95))
            }

            ZStack {
                Self.smoothPath(pts, w: w, h: h, closed: true)
                    .fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom))

                Self.smoothPath(pts, w: w, h: h, closed: false)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// 用中点水平切线的三次贝塞尔把点连成平滑曲线；closed 时收到底边形成填充区域。
    private static func smoothPath(_ pts: [CGPoint], w: CGFloat, h: CGFloat, closed: Bool) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        if closed { path.move(to: CGPoint(x: 0, y: h)); path.addLine(to: first) }
        else { path.move(to: first) }
        for i in 1..<pts.count {
            let p0 = pts[i - 1], p1 = pts[i]
            let midX = (p0.x + p1.x) / 2
            path.addCurve(to: p1,
                          control1: CGPoint(x: midX, y: p0.y),
                          control2: CGPoint(x: midX, y: p1.y))
        }
        if closed { path.addLine(to: CGPoint(x: w, y: h)); path.closeSubpath() }
        return path
    }
}

/// 卡片内的指标条目：图标 + 标签 + 数值（无独立卡片背景）。
private struct MetricItem: View {
    let icon: String
    let label: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.10)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: mono ? .monospaced : .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    OverviewView().frame(width: 900, height: 700)
}
