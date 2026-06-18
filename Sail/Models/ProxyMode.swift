import Foundation

/// 代理路由模式：规则分流 / 全局代理 / 全部直连。
enum ProxyMode: String, CaseIterable, Identifiable {
    case rule, global, direct
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rule: "规则"
        case .global: "全局"
        case .direct: "直连"
        }
    }
}
