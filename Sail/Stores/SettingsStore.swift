import Foundation
import Observation
import AppKit

/// 应用主题外观：跟随系统 / 强制浅色 / 强制深色。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
    /// 对应的 NSAppearance；系统为 nil（跟随系统）。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// TUN 虚拟网卡详细配置。
struct TUNConfig: Codable, Equatable {
    var stack: String = "gvisor"          // system / gvisor / mixed
    var interfaceName: String = "utun996" // 空 = 自动
    var autoRoute: Bool = true
    var strictRoute: Bool = false
    var autoDetectInterface: Bool = true
    var dnsHijack: Bool = true
    var mtu: Int = 9000
    var excludeCIDR: [String] = []        // route_exclude_address

    static let stacks = ["system", "gvisor", "mixed"]
}

/// 应用偏好的持久化存储，落盘到 <应用支持目录>/Sail/config.json。
///
/// 网络接管对齐 Clash Verge：「系统代理」与「虚拟网卡(TUN)」是两个相互独立、
/// 可同时开启的开关，而非二选一。系统代理走 networksetup；TUN 往运行配置注入
/// tun inbound。内核在任一开关开启时运行，两个都关则停止。
@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    static let defaultPort = 7890
    /// sing-box DNS 解析策略（全局，非 TUN 专有）。
    static let dnsStrategies = ["ipv4_only", "prefer_ipv4", "prefer_ipv6"]

    private(set) var mixedPort: Int = defaultPort
    private(set) var allowLan: Bool = false
    /// 静默启动：开 app 时不弹主窗，直接挂菜单栏（托盘）。
    private(set) var silentStart: Bool = false
    /// 主题外观：系统 / 浅色 / 深色。
    private(set) var appearance: AppearanceMode = .system
    /// 系统代理开关（独立于 TUN）。
    private(set) var systemProxyEnabled: Bool = false
    /// 虚拟网卡(TUN)开关（独立于系统代理）。
    private(set) var tunEnabled: Bool = false
    private(set) var routeMode: ProxyMode = .rule
    /// DNS 解析策略：ipv4_only / prefer_ipv4 / prefer_ipv6。
    private(set) var dnsStrategy: String = "ipv4_only"
    private(set) var tun = TUNConfig()
    // 高级：测速超时（毫秒）/ 自动延迟检查 / 检测间隔（秒）
    private(set) var latencyTimeoutMs: Int = 10000
    private(set) var autoLatencyCheck: Bool = false
    private(set) var latencyIntervalSec: Int = 300

    private var fileURL: URL { KernelPaths.supportDir.appendingPathComponent("config.json") }

    private init() { load() }

    // MARK: 修改（自动落盘）

    func setMixedPort(_ port: Int) {
        let v = (1...65535).contains(port) ? port : Self.defaultPort
        guard v != mixedPort else { return }
        mixedPort = v
        save()
    }

    func setAllowLan(_ value: Bool) {
        guard value != allowLan else { return }
        allowLan = value
        save()
    }

    func setSilentStart(_ value: Bool) {
        guard value != silentStart else { return }
        silentStart = value
        save()
    }

    func setAppearance(_ mode: AppearanceMode) {
        guard mode != appearance else { return }
        appearance = mode
        applyAppearance()
        save()
    }

    /// 把当前主题应用到 NSApp（启动恢复与切换时调用）。
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    func setLatencyTimeout(_ ms: Int) {
        let v = min(max(ms, 1000), 60000)   // 1~60 秒
        guard v != latencyTimeoutMs else { return }
        latencyTimeoutMs = v
        save()
    }

    func setAutoLatencyCheck(_ value: Bool) {
        guard value != autoLatencyCheck else { return }
        autoLatencyCheck = value
        save()
        LatencyTester.shared.restartAuto()
    }

    func setLatencyInterval(_ sec: Int) {
        let v = min(max(sec, 10), 3600)     // 10 秒 ~ 1 小时
        guard v != latencyIntervalSec else { return }
        latencyIntervalSec = v
        save()
        LatencyTester.shared.restartAuto()
    }

    func setRouteMode(_ mode: ProxyMode) {
        guard mode != routeMode else { return }
        routeMode = mode
        save()
        if KernelRunner.shared.isRunning {
            Task { await KernelRunner.shared.restart() }
        }
    }

    func setDnsStrategy(_ strategy: String) {
        guard strategy != dnsStrategy, Self.dnsStrategies.contains(strategy) else { return }
        dnsStrategy = strategy
        save()
        if KernelRunner.shared.isRunning {
            Task { await KernelRunner.shared.restart() }
        }
    }

    /// 系统代理开关：与 TUN 独立，可共存。内核随 app 常驻，这里只接管/释放系统代理。
    func setSystemProxy(_ on: Bool) async {
        guard on != systemProxyEnabled else { return }
        systemProxyEnabled = on
        save()
        let runner = KernelRunner.shared
        if runner.isRunning {
            if on { SystemProxy.enable(port: mixedPort) } else { SystemProxy.disable() }
        } else {
            await runner.start()   // 内核应常驻；若没在跑则拉起，start() 会按当前开关接管
        }
    }

    /// 虚拟网卡(TUN)开关：与系统代理独立，可共存。增删 tun inbound 需重启内核生效。
    func setTunEnabled(_ on: Bool) async {
        guard on != tunEnabled else { return }
        tunEnabled = on
        save()
        let runner = KernelRunner.shared
        if runner.isRunning { await runner.restart() }  // start() 会按需申请 TUN 权限
        else { await runner.start() }
    }

    func setTUN(_ config: TUNConfig) {
        guard config != tun else { return }
        tun = config
        save()
        if KernelRunner.shared.isRunning, tunEnabled {
            Task { await KernelRunner.shared.restart() }
        }
    }

    // MARK: 落盘模型（嵌套 app，便于日后扩展 window 等字段）

    private struct Persisted: Codable {
        struct App: Codable {
            var mixedPort: Int = SettingsStore.defaultPort
            var allowLan: Bool = false
            var silentStart: Bool = false
            var appearance: String = AppearanceMode.system.rawValue
            var systemProxyEnabled: Bool = false
            var tunEnabled: Bool = false
            var routeMode: String = ProxyMode.rule.rawValue
            var dnsStrategy: String = "ipv4_only"
            var tun = TUNConfig()
            var latencyTimeoutMs: Int = 10000
            var autoLatencyCheck: Bool = false
            var latencyIntervalSec: Int = 300
        }
        var app = App()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        mixedPort = (1...65535).contains(p.app.mixedPort) ? p.app.mixedPort : Self.defaultPort
        allowLan = p.app.allowLan
        silentStart = p.app.silentStart
        appearance = AppearanceMode(rawValue: p.app.appearance) ?? .system
        routeMode = ProxyMode(rawValue: p.app.routeMode) ?? .rule
        dnsStrategy = Self.dnsStrategies.contains(p.app.dnsStrategy) ? p.app.dnsStrategy : "ipv4_only"
        tun = p.app.tun
        latencyTimeoutMs = min(max(p.app.latencyTimeoutMs, 1000), 60000)
        autoLatencyCheck = p.app.autoLatencyCheck
        latencyIntervalSec = min(max(p.app.latencyIntervalSec, 10), 3600)
        // 内核随 app 常驻，启动后由 start() 按这些开关接管，故直接恢复上次状态。
        systemProxyEnabled = p.app.systemProxyEnabled
        tunEnabled = p.app.tunEnabled
    }

    /// 原子写入：写临时文件 → rename，避免写到一半损坏。
    private func save() {
        var p = Persisted()
        p.app = .init(mixedPort: mixedPort, allowLan: allowLan, silentStart: silentStart,
                      appearance: appearance.rawValue,
                      systemProxyEnabled: systemProxyEnabled, tunEnabled: tunEnabled,
                      routeMode: routeMode.rawValue, dnsStrategy: dnsStrategy, tun: tun,
                      latencyTimeoutMs: latencyTimeoutMs, autoLatencyCheck: autoLatencyCheck,
                      latencyIntervalSec: latencyIntervalSec)
        do {
            try FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(p)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch {
            // 落盘失败时尽力而为，不阻断使用
        }
    }
}
