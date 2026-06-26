import Foundation

/// 通过 networksetup 接管 / 释放 macOS 系统代理（HTTP / HTTPS / SOCKS）。
/// 连接内核时设到本地混合端口，断开时关闭——否则流量不会经过 Sail。
enum SystemProxy {
    /// 串行队列：enable/disable 多由 Task.detached 触发（启动/崩溃/退出），并发跑会让 networksetup
    /// 命令交错，留下半开半关的不确定状态。全部经此队列序列化，保证每次操作整体原子、按事件顺序落定。
    nonisolated private static let queue = DispatchQueue(label: "com.sail.systemproxy")

    nonisolated static func enable(host: String = "127.0.0.1", port: Int) {
        queue.sync {
            for svc in activeServices() {
                run(["-setwebproxy", svc, host, "\(port)"])
                run(["-setsecurewebproxy", svc, host, "\(port)"])
                run(["-setsocksfirewallproxy", svc, host, "\(port)"])
            }
        }
    }

    nonisolated static func disable() {
        queue.sync {
            for svc in activeServices() {
                run(["-setwebproxystate", svc, "off"])
                run(["-setsecurewebproxystate", svc, "off"])
                run(["-setsocksfirewallproxystate", svc, "off"])
            }
        }
    }

    /// 已启用（未被 * 标记禁用）的网络服务名。
    nonisolated private static func activeServices() -> [String] {
        guard let out = run(["-listallnetworkservices"]) else { return [] }
        return out
            .split(separator: "\n")
            .dropFirst() // 首行是说明文字
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    @discardableResult
    nonisolated private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            NSLog("%@", "[Sail] networksetup 无法启动(\(args.first ?? "")): \(error.localizedDescription)")
            return nil
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        // networksetup 失败（服务名不存在/权限/服务异常）返回非 0，错误以 "** Error:" 打到 stdout。
        // 静默吞掉会让「以为设/撤了代理其实没生效」无从察觉——尤其 disable 失败会把用户留在指向死端口的黑洞里。
        if p.terminationStatus != 0 {
            let msg = ((out ?? "") + err).trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("%@", "[Sail] networksetup 失败(\(p.terminationStatus)) args=\(args.joined(separator: " ")) msg=\(msg)")
        }
        return out
    }
}
