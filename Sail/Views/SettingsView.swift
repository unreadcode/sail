import SwiftUI

/// 设置页面：应用常规偏好（持久化到 SettingsStore）。
struct SettingsView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader("常规")
                    GeneralCard()
                }
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader("sing-box")
                    SingBoxCard()
                }
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader("高级")
                    AdvancedCard()
                }
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader("内核")
                    KernelCard()
                }
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader("关于")
                    AboutCard()
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .toolbar {
            ToolbarItem {
                Button {
                    openURL(URL(string: "https://github.com/unreadcode/sail")!)
                } label: {
                    Image("GitHubMark")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.plain)
                .help("在 GitHub 查看源码")
            }
        }
    }
}

// MARK: - 通用设置行

@ViewBuilder
private func settingRow<Trailing: View>(_ label: String, _ desc: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
    HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 13, weight: .medium))
            Text(desc).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        trailing()
    }
    .padding(16)
}

// MARK: - 常规（应用行为）

private struct GeneralCard: View {
    @State private var store = SettingsStore.shared
    @State private var launchAtLogin = false

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                settingRow("主题外观", "界面跟随系统，或强制浅色 / 深色") {
                    Picker("", selection: Binding(get: { store.appearance }, set: { store.setAppearance($0) })) {
                        ForEach(AppearanceMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider().padding(.leading, 16)
                settingRow("开机自启", "登录系统后自动启动 Sail") {
                    Toggle("", isOn: Binding(get: { launchAtLogin },
                                             set: { launchAtLogin = LoginItem.setEnabled($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 16)
                settingRow("启动时隐藏到托盘", "开启后启动不弹主界面，直接挂菜单栏（点托盘图标可唤出）") {
                    Toggle("", isOn: Binding(get: { store.silentStart }, set: { store.setSilentStart($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}

// MARK: - sing-box（内核运行配置）

private struct SingBoxCard: View {
    @State private var store = SettingsStore.shared
    @State private var geo = GeoData.shared
    @State private var portText = ""
    @State private var tunGranted = false
    @State private var tunBusy = false
    @State private var showingTUN = false
    @FocusState private var portFocused: Bool
    private let dnsStrategyLabels = ["ipv4_only": "仅 IPv4", "prefer_ipv4": "优先 IPv4", "prefer_ipv6": "优先 IPv6"]

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()
    private var geoDesc: String {
        if let err = geo.lastError { return "更新失败：\(err)" }
        if let date = geo.lastUpdated { return "本地规则 · 上次更新 \(Self.dateFmt.string(from: date))" }
        return "当前用远程规则（每次启动联网拉取）；点更新下到本地"
    }

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                settingRow("混合代理端口", "HTTP / SOCKS 共用的本地监听端口（重启内核后生效）") {
                    TextField("", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 90)
                        .focused($portFocused)
                        .onChange(of: portText) { _, new in
                            portText = String(new.filter(\.isNumber).prefix(5))
                        }
                        .onSubmit(commitPort)
                        .onChange(of: portFocused) { _, focused in if !focused { commitPort() } }
                        .onChange(of: store.mixedPort) { _, v in portText = String(v) }
                }
                Divider().padding(.leading, 16)
                settingRow("允许局域网连接", "让同一网络下的其它设备使用此代理") {
                    Toggle("", isOn: Binding(get: { store.allowLan }, set: { store.setAllowLan($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 16)
                settingRow("DNS 解析策略", "仅 IPv4 最稳；无可用 IPv6 出口时选它，可避免连上却打不开") {
                    Picker("", selection: Binding(get: { store.dnsStrategy }, set: { store.setDnsStrategy($0) })) {
                        ForEach(SettingsStore.dnsStrategies, id: \.self) { Text(dnsStrategyLabels[$0] ?? $0).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Divider().padding(.leading, 16)
                settingRow("GEO 数据", geoDesc) {
                    if geo.updating {
                        Spinner(size: 14)
                    } else {
                        Button("更新") { Task { await geo.update() } }.controlSize(.small)
                    }
                }
                Divider().padding(.leading, 16)
                settingRow("虚拟网卡（TUN）服务", "安装特权组件后，内核经其以 root 运行虚拟网卡；安装/卸载需管理员授权") {
                    if tunBusy {
                        Spinner(size: 14)
                    } else if tunGranted {
                        HStack(spacing: 8) {
                            Label("已安装", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Button("卸载") { uninstallTUNService() }
                                .controlSize(.small)
                        }
                    } else {
                        Button("安装") { installTUNService() }
                            .controlSize(.small)
                    }
                }
                Divider().padding(.leading, 16)
                settingRow("虚拟网卡（TUN）配置", "堆栈、路由、DNS 劫持、MTU、排除网段等") {
                    Button("配置") { showingTUN = true }.controlSize(.small)
                }
            }
        }
        .onAppear {
            portText = String(store.mixedPort)
            tunGranted = HelperManager.isInstalled
        }
        .sheet(isPresented: $showingTUN) {
            TUNSettingsSheet(config: store.tun) { store.setTUN($0) }
        }
    }

    private func commitPort() {
        store.setMixedPort(Int(portText) ?? SettingsStore.defaultPort)
        portText = String(store.mixedPort)
    }

    private func installTUNService() {
        tunBusy = true
        Task {
            _ = await HelperManager.install()
            tunGranted = HelperManager.isInstalled
            tunBusy = false
        }
    }

    private func uninstallTUNService() {
        tunBusy = true
        Task {
            if store.tunEnabled { await store.setTunEnabled(false) }  // 先关闭虚拟网卡
            _ = await HelperManager.uninstall()
            tunGranted = HelperManager.isInstalled
            tunBusy = false
        }
    }
}

// MARK: - 虚拟网卡 (TUN) 配置弹窗

struct TUNSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var config: TUNConfig
    var onSave: (TUNConfig) -> Void

    @State private var excludeText = ""
    @FocusState private var field: Field?
    private enum Field { case mtu, name, exclude }

    private let stackLabels = ["system": "System", "gvisor": "GVisor", "mixed": "Mixed"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("虚拟网卡（TUN）").font(.system(size: 16, weight: .semibold, design: .rounded))
                Spacer()
                Button("重置为默认") { reset() }.controlSize(.small)
            }
            .padding(.bottom, 16)

            VStack(spacing: 0) {
                row2("网络堆栈", "gvisor：用户态，最稳；system：内核态，更快；mixed：混合") {
                    Picker("", selection: $config.stack) {
                        ForEach(TUNConfig.stacks, id: \.self) { Text(stackLabels[$0] ?? $0).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                divider
                row2("自动设置全局路由", "接管系统路由表，是 TUN 生效的前提（一般保持开启）") {
                    Toggle("", isOn: $config.autoRoute).labelsHidden().toggleStyle(.switch)
                }
                divider
                row2("严格路由", "强制所有流量经 TUN，防止分流泄漏") {
                    Toggle("", isOn: $config.strictRoute).labelsHidden().toggleStyle(.switch)
                }
                divider
                row2("自动选择出口接口", "自动跟随系统默认网卡，换网/插拔无需手改") {
                    Toggle("", isOn: $config.autoDetectInterface).labelsHidden().toggleStyle(.switch)
                }
                divider
                row2("DNS 劫持", "拦截 DNS 查询并按规则分流，避免泄漏") {
                    Toggle("", isOn: $config.dnsHijack).labelsHidden().toggleStyle(.switch)
                }
                divider
                row2("MTU", "最大传输单元，默认 9000；遇到兼容问题可改 1500") {
                    TextField("", value: $config.mtu, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 80)
                        .focused($field, equals: .mtu)
                }
                divider
                row2("虚拟网卡名称", "留空自动分配（如 utun5）") {
                    TextField("自动", text: $config.interfaceName)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 140)
                        .focused($field, equals: .name)
                }
                divider
                VStack(alignment: .leading, spacing: 6) {
                    Text("排除自定义网段").font(.system(size: 13, weight: .medium))
                    Text("这些网段不走 TUN（每行一个 CIDR，如 192.168.0.0/16）")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $excludeText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 64)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                        .focused($field, equals: .exclude)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }.buttonStyle(.borderedProminent)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            excludeText = config.excludeCIDR.joined(separator: "\n")
            DispatchQueue.main.async { field = nil }   // 盖过系统的自动聚焦
        }
    }

    private var divider: some View { Divider().padding(.leading, 16) }

    private func row2<T: View>(_ label: String, _ desc: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13, weight: .medium))
                Text(desc).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
        .padding(16)
    }

    private func reset() {
        config = TUNConfig()
        excludeText = ""
    }

    private func save() {
        config.mtu = min(max(config.mtu, 576), 9000)   // 约束在合理区间
        // 只保留合法的 IP / CIDR：一个非法网段会让内核启动直接失败、陷入重启循环，且错误仅显示「内核异常退出」难定位。
        config.excludeCIDR = excludeText
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && Self.isValidCIDR($0) }
        onSave(config)
        dismiss()
    }

    /// 校验 IP 或 CIDR（如 192.168.0.0/16、10.0.0.1、fd00::/8）。裸 IP 也接受（按单地址）。
    private static func isValidCIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let ip = String(parts[0])
        var v4 = in_addr(), v6 = in6_addr()
        let isV4 = ip.withCString { inet_pton(AF_INET, $0, &v4) } == 1
        let isV6 = ip.withCString { inet_pton(AF_INET6, $0, &v6) } == 1
        guard isV4 || isV6 else { return false }
        if parts.count == 2 {
            guard let prefix = Int(parts[1]) else { return false }
            return isV4 ? (0...32).contains(prefix) : (0...128).contains(prefix)
        }
        return true
    }
}

// MARK: - 高级（测速）

private struct AdvancedCard: View {
    @State private var store = SettingsStore.shared
    @State private var timeoutText = ""
    @State private var intervalText = ""
    @FocusState private var focus: Field?
    private enum Field { case timeout, interval }

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                settingRow("延迟检测超时", "节点延迟测试的超时时间，默认 10000（单位毫秒）") {
                    HStack(spacing: 4) {
                        TextField("", text: $timeoutText)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                            .font(.system(size: 13, design: .monospaced)).frame(width: 80)
                            .focused($focus, equals: .timeout)
                            .onChange(of: timeoutText) { _, n in timeoutText = String(n.filter(\.isNumber).prefix(5)) }
                            .onSubmit(commitTimeout)
                            .onChange(of: focus) { _, f in if f != .timeout { commitTimeout() } }
                            .onChange(of: store.latencyTimeoutMs) { _, v in timeoutText = String(v) }
                        Text("ms").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.leading, 16)
                settingRow("自动延迟检查", "按间隔自动测试当前订阅节点的延迟") {
                    Toggle("", isOn: Binding(get: { store.autoLatencyCheck }, set: { store.setAutoLatencyCheck($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider().padding(.leading, 16)
                settingRow("延迟检测间隔", "自动检查的间隔，默认 300（单位秒）") {
                    HStack(spacing: 4) {
                        TextField("", text: $intervalText)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                            .font(.system(size: 13, design: .monospaced)).frame(width: 80)
                            .focused($focus, equals: .interval)
                            .onChange(of: intervalText) { _, n in intervalText = String(n.filter(\.isNumber).prefix(4)) }
                            .onSubmit(commitInterval)
                            .onChange(of: focus) { _, f in if f != .interval { commitInterval() } }
                            .onChange(of: store.latencyIntervalSec) { _, v in intervalText = String(v) }
                        Text("秒").font(.caption).foregroundStyle(.secondary)
                    }
                    .disabled(!store.autoLatencyCheck)
                }
            }
        }
        .onAppear {
            timeoutText = String(store.latencyTimeoutMs)
            intervalText = String(store.latencyIntervalSec)
        }
    }

    private func commitTimeout() {
        store.setLatencyTimeout(Int(timeoutText) ?? 10000)
        timeoutText = String(store.latencyTimeoutMs)
    }

    private func commitInterval() {
        store.setLatencyInterval(Int(intervalText) ?? 300)
        intervalText = String(store.latencyIntervalSec)
    }
}

// MARK: - 内核管理

private struct KernelCard: View {
    @State private var kernel = KernelManager()
    private let runner = KernelRunner.shared

    private var statusText: String {
        if !kernel.status.installed { return "未检测到内核，安装后即可启航" }
        if kernel.updatable { return "发现可用更新" }
        if kernel.upToDate { return "已是最新版本" }
        return "内核已安装"
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 20) {
                // 头部
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sing-box").font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text("代理内核").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if kernel.status.installed {
                        Button { Task { await runner.restart() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                        .disabled(runner.isBusy)
                        .help("重启内核")
                    }
                    statusPill
                }

                // 版本主展示
                VStack(alignment: .leading, spacing: 6) {
                    if !kernel.status.installed {
                        Text("未安装")
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else if kernel.updatable {
                        HStack(spacing: 10) {
                            Text("v\(kernel.status.version)")
                                .font(.system(size: 16, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .strikethrough()
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text("v\(kernel.latest)")
                                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                    } else {
                        Text("v\(kernel.status.version.isEmpty ? "—" : kernel.status.version)")
                            .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    }
                    Text(statusText).font(.subheadline).foregroundStyle(.secondary)
                }

                // 元信息
                VStack(spacing: 8) {
                    metaRow("最新版本", kernel.latest.isEmpty ? "—" : "v\(kernel.latest)")
                    if kernel.status.installed {
                        metaRow("安装路径", kernel.status.path)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                if kernel.busy {
                    VStack(spacing: 8) {
                        HStack {
                            Label(kernel.statusMessage.isEmpty ? "处理中 …" : kernel.statusMessage,
                                  systemImage: "arrow.down.circle")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(kernel.progress * 100))%")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        .font(.caption)
                        ProgressView(value: kernel.progress).tint(Color.accentColor)
                    }
                } else if !kernel.errorMessage.isEmpty {
                    Label(kernel.errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }

                // 操作
                HStack(spacing: 8) {
                    if !kernel.status.installed {
                        Button { Task { await kernel.install() } } label: {
                            Label(kernel.latest.isEmpty ? "安装内核" : "安装 v\(kernel.latest)", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(kernel.busy)
                    } else if kernel.updatable {
                        Button { Task { await kernel.install() } } label: {
                            Label("更新到 v\(kernel.latest)", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(kernel.busy)
                    } else {
                        // 已安装且无可用更新：提供重新安装（停内核→下载最新→换新→重启），用于损坏修复 / 强制刷新
                        Button { Task { await kernel.reinstall() } } label: {
                            Label("重新安装", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .disabled(kernel.busy)
                    }
                    Button("检查更新") { Task { await kernel.refresh() } }
                        .disabled(kernel.busy)
                    Spacer()
                    if kernel.status.installed {
                        Button(role: .destructive) { Task { await kernel.remove() } } label: {
                            Label("卸载", systemImage: "trash")
                        }
                        .disabled(kernel.busy)
                    }
                }
            }
        }
        .task { await kernel.refresh() }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(kernel.status.installed ? Color.accentColor : Color.secondary)
                .frame(width: 6, height: 6)
            Text(kernel.status.installed ? "运行就绪" : "未安装")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(kernel.status.installed ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternaryLabelColor).opacity(0.4))
        )
        .foregroundStyle(kernel.status.installed ? Color.accentColor : Color.secondary)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary.opacity(0.8))
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
    }
}

// MARK: - 关于

private struct AboutCard: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image("AppLogo")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sail").font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text("优雅的 sing-box Mac客户端").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(SystemInfo.appVersion).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    HStack {
                        Text("版本更新").foregroundStyle(.secondary)
                        Spacer()
                        updateStatus
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    Divider().padding(.leading, 14)
                    HStack {
                        Text("作者").foregroundStyle(.secondary)
                        Spacer()
                        Text("Unreadcode").fontWeight(.medium)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    Divider().padding(.leading, 14)
                    Link(destination: URL(string: "https://github.com/SagerNet/sing-box")!) {
                        HStack {
                            Text("内核项目").foregroundStyle(.secondary)
                            Spacer()
                            Label("SagerNet/sing-box", systemImage: "arrow.up.right.square")
                                .labelStyle(.titleAndIcon)
                                .environment(\.layoutDirection, .rightToLeft)
                                .fontWeight(.medium)
                        }
                        .font(.system(size: 13))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    Divider().padding(.leading, 14)
                    Link(destination: URL(string: "https://www.rainyun.com/Nzc2NDU0_")!) {
                        HStack {
                            Text("服务器推荐").foregroundStyle(.secondary)
                            Spacer()
                            Label("查看雨云服务器🔥", systemImage: "arrow.up.right.square")
                                .labelStyle(.titleAndIcon)
                                .environment(\.layoutDirection, .rightToLeft)
                                .fontWeight(.medium)
                        }
                        .font(.system(size: 13))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
                )
            }
        }
        .task { if updater.latest == nil { await updater.check() } }
    }

    @ViewBuilder private var updateStatus: some View {
        if updater.installing {
            HStack(spacing: 6) { Spinner(size: 12); Text("下载并安装中…").foregroundStyle(.secondary) }
        } else if updater.checking {
            HStack(spacing: 6) { Spinner(size: 12); Text("检查中…").foregroundStyle(.secondary) }
        } else if updater.updateAvailable, let v = updater.latest?.version {
            HStack(spacing: 8) {
                if let err = updater.installError {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
                Button { Task { await updater.downloadAndInstall() } } label: {
                    Label("更新到 v\(v)", systemImage: "arrow.down.circle.fill")
                        .labelStyle(.titleAndIcon).fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        } else if updater.lastError != nil {
            Button("检查失败，重试") { Task { await updater.check() } }.controlSize(.small)
        } else if updater.latest != nil {
            Button("已是最新 · 重新检查") { Task { await updater.check() } }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        } else {
            Button("检查更新") { Task { await updater.check() } }.controlSize(.small)
        }
    }
}

#Preview {
    SettingsView().frame(width: 720, height: 600)
}
