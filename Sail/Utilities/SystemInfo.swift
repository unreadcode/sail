import Foundation
import Darwin

/// 系统 / 应用自身 / 内核的信息。
enum SystemInfo {
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    static var arch: String {
        #if arch(arm64)
        "Apple Silicon"
        #else
        "Intel x86_64"
        #endif
    }

    static var physicalMemory: Double { Double(ProcessInfo.processInfo.physicalMemory) }

    static var cpuCores: Int { ProcessInfo.processInfo.processorCount }

    /// Sail 自身版本（CFBundleShortVersionString）。
    static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "v\(v)"
    }

    /// Sail 应用自身内存占用（字节）。用 phys_footprint —— 与「活动监视器」的
    /// 「内存」一栏一致，排除共享框架内存，比 resident_size 更准、更低。
    static func appMemoryBytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) : 0
    }

    /// 运行内核二进制取版本号（阻塞，后台调用）。默认取已安装的用户态内核，可传路径比对其它副本。
    nonisolated static func kernelVersion(at path: String = KernelPaths.binary.path) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let first = (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").first.map(String.init) ?? ""
        let fields = first.split(separator: " ").map(String.init)
        if let i = fields.firstIndex(of: "version"), i + 1 < fields.count { return "v" + fields[i + 1] }
        return nil
    }
}
