import SwiftUI

/// 侧栏导航项，对齐参考项目（Wails 版）的信息架构
enum NavItem: String, CaseIterable, Identifiable {
    case overview, subscriptions, groups, rules, connections, traffic, logs, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .subscriptions: "订阅"
        case .groups: "分组"
        case .rules: "规则"
        case .connections: "连接"
        case .traffic: "流量"
        case .logs: "日志"
        case .settings: "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: "连接状态与实时流量"
        case .subscriptions: "管理订阅链接与节点"
        case .groups: "代理分组切换与测速"
        case .rules: "自定义分流规则"
        case .connections: "实时连接与流量"
        case .traffic: "按域名 / 应用 / 协议统计用量"
        case .logs: "内核运行日志"
        case .settings: "应用常规偏好与内核管理"
        }
    }

    var icon: String {
        switch self {
        case .overview: "chart.line.uptrend.xyaxis"
        case .subscriptions: "icloud.and.arrow.down"
        case .groups: "square.stack.3d.up"
        case .rules: "arrow.triangle.branch"
        case .connections: "network"
        case .traffic: "arrow.up.arrow.down"
        case .logs: "terminal"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @State private var selection: NavItem = .overview
    @State private var updater = AppUpdater.shared   // 观察「有新版本」，在侧栏 logo 上挂 NEW 角标
    @State private var settingsTab: SettingsView.Tab = .general   // 设置页当前分区；点 NEW 角标时切到「关于」

    private let mainNav: [NavItem] = [.overview, .subscriptions, .groups, .rules, .connections, .traffic, .logs, .settings]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    HStack(spacing: 10) {
                        // 有新版本时整个 logo 变成可点按钮 → 跳「设置 › 关于」；否则普通展示。
                        if updater.updateAvailable {
                            Button {
                                settingsTab = .about
                                selection = .settings
                            } label: { brandLogo }
                            .buttonStyle(.plain)
                            .help(updater.latest.map { "有新版本 v\($0.version)，点击前往「设置 › 关于」更新" } ?? "有新版本可用，点击前往更新")
                        } else {
                            brandLogo
                        }
                        Text("Sail")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                    }
                    .padding(.vertical, 4)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                }

                Section {
                    ForEach(mainNav) { item in
                        Label(item.title, systemImage: item.icon)
                            .tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(200)   // 固定 200（最窄）：侧栏不可拖宽，展开时详情页挤压最小，避免重排卡顿
        } detail: {
            DetailContainer(item: selection, settingsTab: $settingsTab)
        }
    }

    /// 侧栏品牌 logo；有新版本时右上角挂 NEW 角标（overlay 在 clipShape 之后，不被圆角裁掉）。
    private var brandLogo: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if updater.updateAvailable {
                    Text("NEW")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                        // 描边用窗口背景色，让角标从 logo 边缘跳出来
                        .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        .fixedSize()
                        .offset(x: 6, y: -4)
                }
            }
    }
}

/// 详情容器：套上原生标题栏（标题 + 副标题）后分发到各页面
private struct DetailContainer: View {
    let item: NavItem
    @Binding var settingsTab: SettingsView.Tab
    @State private var windowState = WindowState.shared

    var body: some View {
        Group {
            if windowState.contentVisible {
                page
            } else {
                // 收托盘后卸载页面：等价于用户切走 tab，销毁概览等页 → 停每秒重绘 / 轮询、
                // 释放离屏渲染图层，挂机 RSS 不再走高。唤出主窗自然重建。
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(item.title)
        .navigationSubtitle(item.subtitle)
    }

    @ViewBuilder private var page: some View {
        switch item {
        case .overview: OverviewView()
        case .subscriptions: SubscriptionsView()
        case .groups: GroupsView()
        case .rules: RulesView()
        case .connections: ConnectionsView()
        case .traffic: TrafficView()
        case .logs: LogsView()
        case .settings: SettingsView(tab: $settingsTab)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 700)
}
