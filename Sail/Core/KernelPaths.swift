import Foundation

/// 内核相关的统一路径，避免各处各算各的。
enum KernelPaths {
    /// 应用支持目录：<应用支持目录>/Sail
    nonisolated static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sail", isDirectory: true)
    }

    /// 内核安装目录：…/Sail/sing-box
    nonisolated static var kernelDir: URL {
        supportDir.appendingPathComponent("sing-box", isDirectory: true)
    }

    /// 内核二进制：…/Sail/sing-box/sing-box
    nonisolated static var binary: URL {
        kernelDir.appendingPathComponent("sing-box")
    }

    /// 运行时生成的 sing-box 配置：…/Sail/config.run.json
    nonisolated static var runtimeConfig: URL {
        supportDir.appendingPathComponent("config.run.json")
    }
}
