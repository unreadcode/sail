import Foundation
import Observation

/// 一行内核日志：id 为单调递增序号（跨封顶裁剪稳定，供列表做稳定 diff），text 保留原始 ANSI。
struct LogLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// 负责把 sing-box 作为子进程启动 / 停止，并捕获日志与运行状态。
/// 全局唯一（系统中只应有一个内核进程）。
@MainActor
@Observable
final class KernelRunner {
    static let shared = KernelRunner()

    enum RunState: Equatable { case stopped, starting, running, stopping }

    // MARK: 对外状态
    private(set) var runState: RunState = .stopped
    private(set) var startedAt: Date?
    var errorMessage = ""
    private(set) var logLines: [LogLine] = []
    private var logSeq = 0

    var isRunning: Bool { runState == .running }
    var isBusy: Bool { runState == .starting || runState == .stopping }

    private var process: Process?
    private var ranViaHelper = false   // 本次内核是否由特权 helper(root) 启动（TUN 模式）
    private let maxLogLines = 800

    // 内核异常退出后的自动重启：限次 + 退避，避免坏配置导致的无限快速重启循环
    private var crashCount = 0
    private var autoRestartTask: Task<Void, Never>?
    private var helperWatchTask: Task<Void, Never>?   // helper 模式：轮询内核存活，崩溃则重启
    private var helperLogTask: Task<Void, Never>?      // helper 模式：tail 内核日志文件
    private static let maxAutoRestarts = 3

    private init() {}

    // MARK: 动作

    func toggle() async {
        if runState == .stopped {
            await start()
        } else {
            await stop()
        }
    }

    /// auto=true 表示由「异常退出自动重启」触发，不重置崩溃计数；手动/常规启动会清零并取消待重启。
    func start(auto: Bool = false) async {
        guard runState == .stopped else { return }
        errorMessage = ""
        if !auto {
            crashCount = 0
            autoRestartTask?.cancel(); autoRestartTask = nil
        }

        // 首次运行从 app 包内播种内核 + geo 规则集（无需联网，避免「没代理装不了内核 / 起不来」的死循环）
        await Task.detached {
            Self.seedKernelFromBundleIfNeeded()
            GeoData.seedFromBundleIfNeeded()
        }.value

        guard FileManager.default.fileExists(atPath: KernelPaths.binary.path) else {
            errorMessage = "未检测到内核，请先到「设置」安装 sing-box"
            disableSystemProxyIfNeeded()   // 内核起不来：撤掉系统代理，避免指向死端口黑洞断网
            return
        }

        runState = .starting
        logLines.removeAll()

        // 清理上次残留的孤儿内核：app 被强杀/崩溃时 terminationHandler 没跑到，
        // 旧 sing-box 仍占着 clash_api/本地端口，新内核会因端口冲突 code 1 退出。
        await Task.detached { Self.killStrayKernels() }.value

        // TUN 需 root：经特权 helper 以 root 起内核（替代 setuid）。helper 未装则先弹一次管理员授权安装。
        if SettingsStore.shared.tunEnabled {
            if !HelperManager.isInstalled {
                let ok = await HelperManager.install()
                if !ok {
                    runState = .stopped
                    errorMessage = "未能安装 TUN 特权组件（需管理员授权）"
                    disableSystemProxyIfNeeded()
                    return
                }
            } else if !auto, await HelperManager.isStale() {
                // 已装但是旧版（如缺内核日志重定向）→ 重装刷新（管理员授权）；
                // 仅用户主动启动时弹授权，崩溃自动重启不打扰；失败不致命，继续用旧 helper
                _ = await HelperManager.install()
            }
        }

        let useHelper = SettingsStore.shared.tunEnabled && HelperManager.isInstalled
        do {
            if useHelper {
                // helper 模式：配置交给 root helper 起 sing-box（TUN 需要 root，本进程不持有内核进程）
                let data = try JSONSerialization.data(withJSONObject: makeConfig())
                let (ok, err) = await SailHelperClient.startKernel(config: String(decoding: data, as: UTF8.self))
                guard ok else {
                    let reason = err ?? "helper 启动失败"
                    appendLogs(["[TUN] helper 启动内核失败：\(reason)"])
                    throw KernelError.message("TUN 启动失败：\(reason)")
                }
                ranViaHelper = true
                process = nil
                startedAt = Date()
                runState = .running
                appendLogs(["[TUN] 内核已由特权 helper 以 root 启动"])
                startHelperLogTail()   // tail root 内核日志
                startHelperWatch()     // 监测崩溃并自动重启
            } else {
                ranViaHelper = false
                try writeConfig()
                let proc = Process()
                proc.executableURL = KernelPaths.binary
                proc.arguments = ["run", "-c", KernelPaths.runtimeConfig.path]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
                    guard !lines.isEmpty else { return }
                    Task { @MainActor in KernelRunner.shared.appendLogs(lines) }
                }
                proc.terminationHandler = { finished in
                    let code = finished.terminationStatus
                    let bySignal = finished.terminationReason == .uncaughtSignal
                    Task { @MainActor in KernelRunner.shared.handleTermination(code: code, bySignal: bySignal) }
                }
                try proc.run()
                process = proc
                startedAt = Date()
                runState = .running
            }

            // 系统代理开关开启则接管系统代理（与 TUN 独立，可共存）
            if SettingsStore.shared.systemProxyEnabled {
                let port = SettingsStore.shared.mixedPort
                Task.detached { SystemProxy.enable(port: port) }
            }
            TrafficMonitor.shared.start()
        } catch {
            process = nil
            startedAt = nil
            ranViaHelper = false
            runState = .stopped
            errorMessage = "启动失败：\(error.localizedDescription)"
            disableSystemProxyIfNeeded()
        }
    }

    /// 内核未在运行却仍开着系统代理 → OS 代理指向死端口会黑洞断网。保留开关状态（内核恢复后会自动重启代理），仅在 OS 层撤下。
    private func disableSystemProxyIfNeeded() {
        if SettingsStore.shared.systemProxyEnabled {
            Task.detached { SystemProxy.disable() }
        }
    }

    /// 若工作目录还没有内核，则从 app 包内置的二进制拷贝过来（离线可用）。
    nonisolated static func seedKernelFromBundleIfNeeded() {
        let dest = KernelPaths.binary
        guard !FileManager.default.fileExists(atPath: dest.path),
              let bundled = Bundle.main.url(forResource: "sing-box", withExtension: nil) else { return }
        do {
            try FileManager.default.createDirectory(at: KernelPaths.kernelDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        } catch {
            // 尽力而为
        }
    }

    /// 杀掉残留的用户态主内核进程（清理孤儿）。helper 模式的 root 内核不在此列（由 helper 自己停）。
    /// 按运行配置路径匹配而非二进制路径：测速临时实例跑的是 sail-latency-*.json，不能误杀。
    nonisolated private static func killStrayKernels() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", KernelPaths.runtimeConfig.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return }
        p.waitUntilExit()
        // pkill 后给系统一点时间释放端口
        usleep(200_000)
    }

    func stop() async {
        autoRestartTask?.cancel(); autoRestartTask = nil   // 用户主动停止，取消待重启
        helperWatchTask?.cancel(); helperWatchTask = nil   // 停监测，避免把主动停止误判为崩溃
        helperLogTask?.cancel(); helperLogTask = nil
        crashCount = 0
        // helper 模式：内核是 root 起的，本进程不持有 Process，交给 helper 停（否则 guard 直接 return → 内核残留）
        if ranViaHelper {
            guard runState == .running || runState == .starting else { return }
            runState = .stopping
            _ = await SailHelperClient.stopKernel()
            ranViaHelper = false
            startedAt = nil
            runState = .stopped
            TrafficMonitor.shared.stop()
            disableSystemProxyIfNeeded()
            return
        }
        guard let proc = process, runState == .running || runState == .starting else { return }
        runState = .stopping
        proc.terminate() // SIGTERM，sing-box 会优雅退出

        // 最多等 3 秒，仍未退出则强杀
        for _ in 0..<30 {
            if !proc.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        // 最终状态由 terminationHandler 落定
    }

    /// 重启内核（切换节点等场景）：停止后等状态落定再启动。
    func restart() async {
        await stop()
        for _ in 0..<40 where runState != .stopped {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await start()
    }

    /// 应用退出时同步收尾，避免遗留孤儿进程（不能 await）。
    /// 必须等内核真正退出：root 的 TUN 实例若成孤儿会继续占用路由表 → 整机断网。
    /// applicationWillTerminate 允许同步阻塞（系统给约 5s），故这里轮询等待 + 超时强杀。
    nonisolated func terminateForAppExit() {
        // terminationHandler 触发的状态更新此刻已无意义，尽力发送终止信号即可
        MainActor.assumeIsolated {
            // 先释放系统代理，避免退出后用户断网
            if SettingsStore.shared.systemProxyEnabled {
                SystemProxy.disable()
            }
            // helper 模式：同步停掉 root 起的内核，否则退出后残留 root TUN 占路由表 → 整机断网
            if ranViaHelper {
                SailHelperClient.stopKernelSync()
                return
            }
            guard let proc = process, proc.isRunning else { return }
            proc.terminate() // SIGTERM，sing-box 优雅退出
            // 最多等 ~3s，仍未退出则强杀并回收，确保进程在 app 退出前确实终止
            for _ in 0..<30 {
                if !proc.isRunning { break }
                usleep(100_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                proc.waitUntilExit()
            }
        }
    }

    // MARK: 内部

    private func handleTermination(code: Int32, bySignal: Bool) {
        let wasStopping = (runState == .stopping)
        let uptime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        // 解除日志管道的读回调，避免其 dispatch source + FileHandle 在多次启停后累积
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        startedAt = nil
        runState = .stopped
        TrafficMonitor.shared.stop()

        // 用户主动停止：清零计数，不重启，撤系统代理
        if wasStopping {
            crashCount = 0
            disableSystemProxyIfNeeded()
            return
        }

        // 异常退出。曾健康运行过（>30s）视作偶发崩溃，重置计数；瞬间退出多为坏配置，计数累加触顶。
        if uptime > 30 { crashCount = 0 }
        let why = bySignal ? "内核被信号终止" : "内核异常退出（code \(code)）"

        if crashCount < Self.maxAutoRestarts {
            crashCount += 1
            let delay = Double(crashCount)   // 1s / 2s / 3s 退避
            errorMessage = "\(why)，\(Int(delay)) 秒后自动重启（第 \(crashCount) 次）…"
            // 重启期间不动系统代理：新内核会绑定同一端口，恢复后代理自然复通（避免反复开关代理）
            autoRestartTask?.cancel()
            autoRestartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.runState == .stopped else { return }
                await self.start(auto: true)
            }
        } else {
            // 连续多次崩溃：放弃自动重启，撤系统代理兜底防黑洞
            errorMessage = "\(why)。已连续 \(crashCount) 次异常退出，停止自动重启——请检查节点配置或查看日志。"
            disableSystemProxyIfNeeded()
        }
    }

    // MARK: helper 模式：崩溃监测 + 日志 tail

    /// 轮询 helper 内核存活；连续两次探测失败（约 6s）才判崩溃，避免偶发 IPC 抖动误杀。
    private func startHelperWatch() {
        helperWatchTask?.cancel()
        helperWatchTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                guard self.ranViaHelper, self.runState == .running else { misses = 0; continue }
                let alive = await SailHelperClient.kernelRunning()
                // await 期间状态可能变化（用户停/切节点），复核后再判定
                guard !Task.isCancelled, self.ranViaHelper, self.runState == .running else { misses = 0; continue }
                if alive { misses = 0; continue }
                misses += 1
                if misses >= 2 { self.handleHelperCrash(); return }
            }
        }
    }

    /// helper 内核崩溃处理：复用直跑模式的限次退避自动重启逻辑。
    private func handleHelperCrash() {
        guard ranViaHelper, runState == .running else { return }
        let uptime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        ranViaHelper = false
        startedAt = nil
        runState = .stopped
        TrafficMonitor.shared.stop()
        helperLogTask?.cancel(); helperLogTask = nil
        helperWatchTask = nil   // 当前 watch 正在退出

        if uptime > 30 { crashCount = 0 }   // 健康跑过 30s 视作偶发，重置计数
        let why = "TUN 内核异常退出"
        if crashCount < Self.maxAutoRestarts {
            crashCount += 1
            let delay = Double(crashCount)
            errorMessage = "\(why)，\(Int(delay)) 秒后自动重启（第 \(crashCount) 次）…"
            autoRestartTask?.cancel()
            autoRestartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, self.runState == .stopped else { return }
                await self.start(auto: true)
            }
        } else {
            errorMessage = "\(why)。已连续 \(crashCount) 次异常退出，停止自动重启——请检查节点配置或查看日志。"
            disableSystemProxyIfNeeded()
        }
    }

    /// tail helper 写的内核日志文件，增量并入 app 日志页（root 写、0644，用户可读）。
    private func startHelperLogTail() {
        helperLogTask?.cancel()
        let path = HelperManager.kernelLog
        helperLogTask = Task { [weak self] in
            var offset: UInt64 = 0
            var first = true
            while !Task.isCancelled {
                if !first { try? await Task.sleep(for: .seconds(1)) }
                first = false
                guard let self, !Task.isCancelled, self.ranViaHelper else { return }
                guard let fh = FileHandle(forReadingAtPath: path) else { continue }
                defer { try? fh.close() }
                let size = (try? fh.seekToEnd()) ?? 0
                if size < offset { offset = 0 }   // 新内核 O_TRUNC 截断 → 重读
                guard size > offset else { continue }
                try? fh.seek(toOffset: offset)
                let data = (try? fh.readToEnd()) ?? Data()
                offset = size
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { continue }
                let lines = text.split(whereSeparator: \.isNewline).map(String.init)
                if !lines.isEmpty { self.appendLogs(lines) }
            }
        }
    }

    func clearLogs() {
        logLines.removeAll()
    }

    private func appendLogs(_ lines: [String]) {
        // 保留原始 ANSI 颜色码，展示时由日志页解析上色；复制时再剥离
        // 每行带单调递增序号 id：跨 removeFirst（封顶裁剪）仍稳定，避免日志页用数组下标当 id 导致复用错位
        for line in lines {
            logLines.append(LogLine(id: logSeq, text: line))
            logSeq += 1
        }
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    /// 剥离 ANSI 颜色码（复制到剪贴板时用，避免带入转义序列）
    nonisolated static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private func writeConfig() throws {
        try FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
        let config = makeConfig()
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted])
        try data.write(to: KernelPaths.runtimeConfig, options: .atomic)
        // 配置含 clash_api 的随机 secret，收紧为仅属主可读写，防本机其它进程读取后偷切节点/读流量
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: KernelPaths.runtimeConfig.path)
    }

    private static let geositeCN = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs"
    private static let geoipCN = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs"

    /// 生成运行配置：mixed 入站 + 出站 + 按模式路由。
    /// 规则：国内/私网直连、其余走代理；全局：全部走代理；直连：全部直连。
    /// 未选节点时一律直连。
    private func makeConfig(applyMixin: Bool = true) -> [String: Any] {
        let settings = SettingsStore.shared
        let listen = settings.allowLan ? "0.0.0.0" : "127.0.0.1"

        // 出站
        var proxyOutbound: [String: Any]?
        if let node = SubscriptionStore.shared.selectedNode,
           let data = node.outboundJSON.data(using: .utf8),
           var outbound = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            outbound["tag"] = "proxy"
            proxyOutbound = outbound
        }
        var outbounds: [[String: Any]] = []
        if let proxyOutbound { outbounds.append(proxyOutbound) }
        outbounds.append(["type": "direct", "tag": "direct"])

        // 路由
        let hasProxy = proxyOutbound != nil
        let mode = settings.routeMode
        let isTun = settings.tunEnabled
        var route: [String: Any] = ["auto_detect_interface": isTun ? settings.tun.autoDetectInterface : true]

        if !hasProxy || mode == .direct {
            route["rules"] = [["action": "sniff"]]
            route["final"] = "direct"
        } else if mode == .global {
            route["rules"] = [["action": "sniff"]]
            route["final"] = "proxy"
        } else if settings.importSubscriptionRules,
                  let subID = SubscriptionStore.shared.selectedSubscription?.id,
                  let imported = ClashRuleImport.importedRoute(dir: SubscriptionStore.subrulesDir(subID)),
                  !imported.rules.isEmpty {
            // 订阅自带规则（已转换落盘）：用它替代内置 geosite-cn/geoip-cn 分流。
            // 私网仍先直连；用户手填规则随后注入在最前（优先级最高）。
            route["rules"] = [["action": "sniff"], ["ip_is_private": true, "outbound": "direct"]] + imported.rules
            route["rule_set"] = imported.ruleSet
            route["final"] = imported.final ?? "proxy"
        } else { // 规则分流（内置）
            route["rules"] = [
                ["action": "sniff"],
                ["ip_is_private": true, "outbound": "direct"],
                ["rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct"],
            ]
            // 已手动下载到本地则用 local（启动快、可离线）；否则远程拉取（经代理）
            if GeoData.hasLocal {
                route["rule_set"] = [
                    ["type": "local", "tag": "geosite-cn", "format": "binary", "path": GeoData.geositePath.path],
                    ["type": "local", "tag": "geoip-cn", "format": "binary", "path": GeoData.geoipPath.path],
                ]
            } else {
                route["rule_set"] = [
                    ["type": "remote", "tag": "geosite-cn", "format": "binary",
                     "url": Self.geositeCN, "download_detour": "proxy"],
                    ["type": "remote", "tag": "geoip-cn", "format": "binary",
                     "url": Self.geoipCN, "download_detour": "proxy"],
                ]
            }
            route["final"] = "proxy"
        }

        // 入站：mixed 始终在（本地端口）；TUN 模式再加一个 tun 网卡（按用户配置）
        var inbounds: [[String: Any]] = [
            ["type": "mixed", "tag": "mixed-in", "listen": listen, "listen_port": settings.mixedPort],
        ]
        if isTun {
            let t = settings.tun
            // TUN 仅默认通告 IPv4 地址；IPv6 地址只在用户启用 IPv6（DNS 非 ipv4_only）时才加。
            // 否则 macOS 会把 IPv6 流量塞进 TUN，而本应用默认无 IPv6 出口 → 既「连上无数据」，
            // 还会让发往 TUN 自身 ULA 网关的 UDP 命中 ip_is_private 判直连而回环 TUN，导致 CPU 空转、上传虚高。
            var tunAddress = ["172.18.0.1/30"]
            if settings.dnsStrategy != "ipv4_only" { tunAddress.append("fdfe:dcba:9876::1/126") }
            var tunIn: [String: Any] = [
                "type": "tun",
                "tag": "tun-in",
                "address": tunAddress,
                "auto_route": t.autoRoute,
                "strict_route": t.strictRoute,
                "stack": t.stack,
                "mtu": t.mtu,
            ]
            if !t.interfaceName.isEmpty { tunIn["interface_name"] = t.interfaceName }
            let cidrs = t.excludeCIDR.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !cidrs.isEmpty { tunIn["route_exclude_address"] = cidrs }
            inbounds.append(tunIn)
        }

        var config: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": route,
            "experimental": [
                "clash_api": ClashAPI.config(port: TrafficMonitor.apiPort)
            ],
        ]

        // DNS 解析策略：sing-box 全局配置，所有模式生效（默认 ipv4_only）。
        // TUN 通告 IPv6 后 macOS 会优先走 IPv6，但直连/代理常无可用 IPv6 出口 →
        // 连上却无数据；ipv4_only 只给 IPv4 可规避，需要 IPv6 的用户可改 prefer_*。
        var dns: [String: Any] = ["strategy": settings.dnsStrategy]

        // TUN + DNS 劫持：拦截 DNS 并经代理/直连分流解析，避免泄漏
        if isTun, settings.tun.dnsHijack {
            var rules = (route["rules"] as? [[String: Any]]) ?? []
            // hijack-dns 必须在 sniff 之后：protocol:dns 要靠 sniff 先嗅探出来，
            // 否则规则匹配不到、DNS 不会被劫持（app 直接用自带 DNS 拿到 AAAA）。
            rules.insert(["protocol": "dns", "action": "hijack-dns"], at: min(1, rules.count))
            route["rules"] = rules
            route["default_domain_resolver"] = "local-dns" // 解析节点域名走直连，避免鸡生蛋
            config["route"] = route

            var dnsServers: [[String: Any]] = []
            if hasProxy {
                dnsServers.append(["tag": "remote-dns", "type": "https", "server": "1.1.1.1", "detour": "proxy"])
            }
            // 不写 detour：sing-box 1.12+ 的 DNS 连接默认即直连，写 detour:"direct"
            // 会被判为「detour to an empty direct outbound makes no sense」而启动失败。
            dnsServers.append(["tag": "local-dns", "type": "https", "server": "223.5.5.5"])
            dns["servers"] = dnsServers
            dns["final"] = hasProxy ? "remote-dns" : "local-dns"
        }
        config["dns"] = dns

        // 注入用户自定义规则：放在 sniff/hijack-dns 之后、内置分流之前，优先级最高。
        let userRules = RuleStore.shared.singBoxRules(hasProxy: hasProxy)
        if !userRules.isEmpty {
            var rules = (route["rules"] as? [[String: Any]]) ?? []
            let prefix = rules.prefix {
                ($0["action"] as? String).map { $0 == "sniff" || $0 == "hijack-dns" } ?? false
            }.count
            rules.insert(contentsOf: userRules, at: prefix)
            route["rules"] = rules
        }
        // geo 分类 + 用户远程规则集，都需要对应的远程 rule_set 定义，合并进 route.rule_set（按 tag 去重）
        let extraSets = RuleStore.shared.geoRuleSets(hasProxy: hasProxy)
            + RuleStore.shared.customRuleSets(hasProxy: hasProxy)
        if !extraSets.isEmpty {
            var sets = (route["rule_set"] as? [[String: Any]]) ?? []
            var tags = Set(sets.compactMap { $0["tag"] as? String })
            for s in extraSets where tags.insert(s["tag"] as? String ?? "").inserted {
                sets.append(s)
            }
            route["rule_set"] = sets
        }

        // 进程解析开关：sing-box 仅当路由里存在「进程匹配」条件时，才会逐连接解析进程名。
        // 加一条永不命中的哨兵规则（无进程叫这名），只为打开解析，让流量页「应用」维度有数据；
        // 放最后且 action 为 route→direct，永不命中故不影响实际分流。
        var withProbe = (route["rules"] as? [[String: Any]]) ?? []
        withProbe.append(["process_name": ["sail-enable-process-resolve"], "action": "route", "outbound": "direct"])
        route["rules"] = withProbe

        config["route"] = route

        // 最后一步：用户 Mixin 深合并覆盖（启用时）。放在最后，可覆盖以上任意生成字段。
        return applyMixin ? MixinStore.shared.apply(to: config) : config
    }

    /// 用「给定 Mixin 文本」合并后的配置跑一次 `sing-box check`；nil=通过，否则返回错误信息。
    /// 不依赖 enabled、不改运行状态——便于启用前先验，避免改坏配置后重启内核才发现起不来。
    func validateConfig(mixinText: String) async -> String? {
        var cfg = makeConfig(applyMixin: false)
        if let overlay = MixinStore.parseObject(mixinText) {
            cfg = MixinStore.deepMerge(cfg, overlay, overlayWins: MixinStore.shared.priority == .mixinWins)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) else {
            return "生成配置失败"
        }
        guard FileManager.default.fileExists(atPath: KernelPaths.binary.path) else { return "未安装内核，无法校验" }
        return await Task.detached {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sail-check-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? data.write(to: tmp)) != nil else { return "写临时配置失败" }
            let p = Process()
            p.executableURL = KernelPaths.binary
            p.arguments = ["check", "-c", tmp.path]
            let errPipe = Pipe(); p.standardError = errPipe; p.standardOutput = Pipe()
            do { try p.run() } catch { return "无法运行内核校验" }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return nil }
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let trimmed = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "配置校验失败（code \(p.terminationStatus)）" : trimmed
        }.value
    }
}
