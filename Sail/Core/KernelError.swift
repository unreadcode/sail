import Foundation

/// 内核 / 网络 / 订阅等场景通用的可读错误。携带一条中文消息，直接展示给用户。
enum KernelError: Error, CustomStringConvertible, LocalizedError {
    case message(String)
    var description: String {
        switch self {
        case .message(let m): m
        }
    }
    // 必须实现 LocalizedError：否则 error.localizedDescription 走 NSError 桥接，
    // 只显示「Sail.KernelError 错误 0」而丢掉真正的消息（启动失败时看不到原因）。
    var errorDescription: String? { description }
}
