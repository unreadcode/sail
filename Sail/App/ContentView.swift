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
        case .traffic: "chart.bar.xaxis"
        case .logs: "terminal"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    @State private var selection: NavItem = .overview

    private let mainNav: [NavItem] = [.overview, .subscriptions, .groups, .rules, .connections, .traffic, .logs, .settings]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    HStack(spacing: 10) {
                        Image("AppLogo")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
            DetailContainer(item: selection)
        }
    }
}

/// 详情容器：套上原生标题栏（标题 + 副标题）后分发到各页面
private struct DetailContainer: View {
    let item: NavItem

    var body: some View {
        Group {
            switch item {
            case .overview: OverviewView()
            case .subscriptions: SubscriptionsView()
            case .groups: GroupsView()
            case .rules: RulesView()
            case .connections: ConnectionsView()
            case .traffic: TrafficView()
            case .logs: LogsView()
            case .settings: SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(item.title)
        .navigationSubtitle(item.subtitle)
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 700)
}
