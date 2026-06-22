import Foundation

/// 特权 helper 的安装 / 卸载（替代 setuid）。
/// 一次管理员授权（osascript）把 helper + 内核副本装到 root-only 路径、写 LaunchDaemon plist 并 bootstrap。
/// 所有特权命令直接 inline 进 osascript 一次性执行，不落任何临时脚本 → 无 TOCTOU 窗口。
enum HelperManager {
    static let label = "com.unreadcode.Sail.helper"
    /// 内嵌 helper 的版本，须与 Helper/main.swift 的 kHelperVersion 一致；装着的版本不符即判旧、自动重装。
    static let expectedVersion = "3"
    static let helperDest = "/Library/PrivilegedHelperTools/\(label)"
    static let plistDest = "/Library/LaunchDaemons/\(label).plist"
    static let supportDir = "/Library/Application Support/Sail"
    static let singboxDest = supportDir + "/sing-box"
    static let kernelLog = supportDir + "/kernel.log"   // 须与 Helper/main.swift 的 kLogPath 一致

    /// app 内嵌的 helper 与内核源路径。
    nonisolated static var embeddedHelper: String { Bundle.main.bundlePath + "/Contents/Helpers/sail-helper" }
    nonisolated static var bundledSingBox: String? { Bundle.main.url(forResource: "sing-box", withExtension: nil)?.path }

    /// 是否已安装（plist 在位即认为装过；可读，无需 root）。
    nonisolated static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistDest) }

    /// 已安装的 helper 是否过旧（版本不符或旧到不认识 version 命令）。仅在已安装时判断。
    static func isStale() async -> Bool {
        guard isInstalled else { return false }
        return await SailHelperClient.helperVersion() != expectedVersion
    }

    /// 安装：弹一次管理员授权（所有命令 inline 进 osascript，不落任何临时脚本 → 无 TOCTOU），装好后验证 helper 能 ping 通。
    static func install() async -> Bool {
        guard FileManager.default.fileExists(atPath: embeddedHelper), let singbox = bundledSingBox else { return false }

        // plist 注入安装者 uid（仅该用户可连 helper）；base64 编码后内联，规避引号/换行的多层转义
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array>
            <string>\(helperDest)</string><string>--uid</string><string>\(getuid())</string>
          </array>
          <key>KeepAlive</key><true/>
          <key>RunAtLoad</key><true/>
        </dict></plist>
        """
        let b64 = Data(plist.utf8).base64EncodedString()
        let cmd = [
            "set -e",
            "mkdir -p \(shq(supportDir))",
            "cp \(shq(singbox)) \(shq(singboxDest))",
            "chown root:wheel \(shq(supportDir)) \(shq(singboxDest))",
            "chmod 0755 \(shq(supportDir)) \(shq(singboxDest))",
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp \(shq(embeddedHelper)) \(shq(helperDest))",
            "chown root:wheel \(shq(helperDest))",
            "chmod 0755 \(shq(helperDest))",
            "echo \(shq(b64)) | /usr/bin/base64 -D > \(shq(plistDest))",
            "chown root:wheel \(shq(plistDest))",
            "chmod 0644 \(shq(plistDest))",
            "launchctl bootout system \(shq(plistDest)) 2>/dev/null || true",
            "launchctl bootstrap system \(shq(plistDest))",
        ].joined(separator: " ; ")

        guard await runAdmin(cmd) else { return false }
        // 等 launchd 拉起 helper 并能 ping
        for _ in 0..<25 { if await SailHelperClient.ping() { return true }; try? await Task.sleep(for: .milliseconds(200)) }
        return false
    }

    /// 把（已在用户态校验过的）内核二进制同步到 root-only 路径，供 TUN/helper 以 root 运行。
    /// 需一次管理员授权（osascript）——这是信任边界：不让 helper 自动拷用户可写文件以 root 运行（即原 setuid 漏洞）。
    static func installPrivilegedKernel(from src: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: src) else { return false }
        let cmd = [
            "set -e",
            "mkdir -p \(shq(supportDir))",
            "chown root:wheel \(shq(supportDir))",
            "chmod 0755 \(shq(supportDir))",
            "cp \(shq(src)) \(shq(singboxDest))",
            "chown root:wheel \(shq(singboxDest))",
            "chmod 0755 \(shq(singboxDest))",
        ].joined(separator: " ; ")
        return await runAdmin(cmd)
    }

    /// 卸载：bootout + 删除 helper / plist / root-only 数据（同样全 inline）。
    static func uninstall() async -> Bool {
        let cmd = [
            "launchctl bootout system \(shq(plistDest)) 2>/dev/null || true",
            "rm -f \(shq(plistDest))",
            "rm -f \(shq(helperDest))",
            "rm -rf \(shq(supportDir))",
        ].joined(separator: " ; ")
        return await runAdmin(cmd)
    }

    /// 把字符串安全包进 shell 单引号（防 root 下命令注入）。
    nonisolated private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 以管理员权限跑一段 shell（osascript 弹授权框）；放后台线程，不阻塞 main。
    private static func runAdmin(_ shell: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
                p.standardOutput = Pipe(); p.standardError = Pipe()
                do { try p.run(); p.waitUntilExit(); cont.resume(returning: p.terminationStatus == 0) }
                catch { cont.resume(returning: false) }
            }
        }
    }
}
