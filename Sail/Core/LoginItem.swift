import Foundation
import ServiceManagement

/// 开机自启：用 SMAppService 把主程序注册/注销为登录项。
/// 状态由系统持有（系统设置 → 通用 → 登录项里可见），无需自己持久化。
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 设置开机自启；返回设置后的真实状态（失败则保持原样）。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 失败（如未授权/路径问题）：忽略，返回系统当前真实状态
        }
        return isEnabled
    }
}
