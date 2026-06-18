import Foundation

/// TUN 需要 root 权限。参考 GUI.for.SingBox：一次管理员授权把内核设为 setuid root，
/// 之后普通启动即以 root 运行，可创建虚拟网卡 + 改路由，无需每次输密码。
enum TUNPermission {
    /// 内核是否已具备 TUN 权限（owner=root 且带 setuid 位）。
    nonisolated static func isGranted() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: KernelPaths.binary.path) else { return false }
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        return owner == 0 && (perms & 0o4000) != 0  // setuid
    }

    /// 通过一次管理员授权，将内核设为 setuid root。返回是否成功。
    /// 会弹出系统管理员授权对话框（osascript）。
    nonisolated static func grant() -> Bool {
        let path = KernelPaths.binary.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let q = shellQuote(path)
        let shell = "chown root:admin \(q); chmod +sx \(q)"
        return runAdmin(shell) && isGranted()
    }

    /// 卸载 TUN 服务：把内核还原为当前用户所有、去掉 setuid 位。同样需管理员授权。
    nonisolated static func revoke() -> Bool {
        let path = KernelPaths.binary.path
        guard FileManager.default.fileExists(atPath: path) else { return true }
        let q = shellQuote(path)
        let shell = "chown \(shellQuote(NSUserName())):staff \(q); chmod 0755 \(q)"
        return runAdmin(shell) && !isGranted()
    }

    /// 把任意字符串安全地包进 shell 单引号（内部单引号转义为 '\''），
    /// 防止以 root 执行时被 home 路径/用户名里的特殊字符注入命令。
    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 以管理员权限执行一段 shell（弹系统授权框）。
    nonisolated private static func runAdmin(_ shell: String) -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
