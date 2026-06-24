import SwiftUI

/// 主窗口内容可见性。收托盘时窗口对象保活（orderOut），但内容无需继续绘制——
/// ContentView 据此卸载详情页，停掉概览等页的每秒重绘 / 轮询、释放离屏渲染图层，
/// 避免关窗挂机时 RSS 长期走高（实测概览页每秒重绘 + Timeline_periodic 在隐藏后仍空转）。
/// 唤出主窗时再置回，详情页自然重建，成本可忽略。
@MainActor @Observable final class WindowState {
    static let shared = WindowState()
    private init() {}

    /// true=窗口在屏需渲染；false=已收托盘，卸载内容。
    var contentVisible = true
}
