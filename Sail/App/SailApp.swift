import SwiftUI
import AppKit

@main
struct SailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 单窗口 Window（非 WindowGroup）：tray 应用只该有一个窗口。
        // WindowGroup 在被重新激活 / reopen 时会再开一个窗口 → 「两个窗口」「关一个全没」等连锁问题。
        Window("Sail", id: "main") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 700)
        }
        // 必须显式 contentMinSize：Window 默认尺寸会持续跟随内容理想尺寸自适应，而
        // NavigationSplitView 的理想尺寸算不稳 → 窗口尺寸反馈死循环、主线程布局打满 CPU。
        // contentMinSize 让窗口仅以内容最小尺寸为下限、其余由用户/默认尺寸决定，断开该循环。
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1100, height: 760)
    }
}

/// 应用级钩子：菜单栏（托盘）图标、静默启动、关窗收进托盘、退出收尾。
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let trayMenu = NSMenu()
    private weak var mainWindow: NSWindow?

    // 单实例文件锁：第一个实例持锁到进程退出（fd 故意不关）；进程死亡时 OS 自动释放，无残留。
    private var instanceLockFD: Int32 = -1
    private var didEnforceSingleInstance = false

    // 关掉最后一个窗口不退出——留在托盘
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()   // 尽早拦截多余实例（在内核 / 系统代理任何动作之前）

        if SettingsStore.shared.silentStart {
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    /// 多余实例通知现有实例显示主窗的跨进程通知名。
    static let showWindowNotification = Notification.Name("com.unreadcode.Sail.showWindow")

    /// 单实例强约束：用 flock 文件锁判定，内核级、零竞态、不依赖 LaunchServices 与启动时机。
    /// 第一个实例拿到锁并持有到退出；拿不到锁说明已有实例在跑 → 唤起它、本进程 exit(0)（不跑收尾，
    /// 避免多余实例误撤现有实例的系统代理）。在 will/didFinishLaunching 两处调用，靠 flag 保证只执行一次。
    @MainActor
    private func enforceSingleInstance() {
        guard !didEnforceSingleInstance else { return }
        didEnforceSingleInstance = true

        try? FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
        let lockPath = KernelPaths.supportDir.appendingPathComponent(".instance.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return }   // 连锁文件都建不了：放行，绝不冒险误杀唯一实例
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            instanceLockFD = fd         // 本进程是唯一实例，持锁到退出（不 close）
            return
        }
        close(fd)

        // 已有实例持锁 → 唤起它（让它从托盘/隐藏状态显示主窗），自己退出
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() && !$0.isTerminated }
        others.first?.activate()
        DistributedNotificationCenter.default().postNotificationName(
            Self.showWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()   // 兜底：万一 willFinishLaunching 没触发，这里在拉起内核前再拦一次
        setupStatusItem()
        SettingsStore.shared.applyAppearance()   // 恢复上次选择的主题外观
        // 收到「多余实例」的跨进程请求时，显示主窗（让用户从启动台再点时看到现有实例）
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleShowWindowRequest),
            name: Self.showWindowNotification, object: nil)
        Task { await AppUpdater.shared.check() }  // 静默检查新版本（结果在「设置→关于」展示）
        // 内核随 app 常驻：启动即拉起（已安装时）
        Task { await KernelRunner.shared.start() }
        LatencyTester.shared.restartAuto()       // 自动延迟检查（按设置）
        SubscriptionStore.shared.startAutoUpdate()  // 订阅自动更新（按各订阅间隔）

        // SwiftUI 的 WindowGroup 窗口可能在启动后才创建、或重置我们设的 delegate；
        // 监听「成为主窗口」事件每次重新挂 delegate，确保关闭拦截一定生效（否则关窗后 Dock 图标残留）。
        NotificationCenter.default.addObserver(self, selector: #selector(attachToWindow(_:)),
                                               name: NSWindow.didBecomeMainNotification, object: nil)

        let silent = SettingsStore.shared.silentStart
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            mainWindow = NSApp.windows.first { $0.canBecomeMain }
            mainWindow?.delegate = self   // 拦截关闭，改为隐藏到托盘
            if silent {
                mainWindow?.orderOut(nil)
                NSApp.setActivationPolicy(.accessory)   // 从 prohibited 切回，恢复托盘交互
            }
        }
    }

    /// 任何窗口成为主窗口时，把它记为主窗并挂上关闭拦截 delegate。
    @objc private func attachToWindow(_ note: Notification) {
        guard let w = note.object as? NSWindow, w.canBecomeMain else { return }
        mainWindow = w
        if !(w.delegate is AppDelegate) { w.delegate = self }
    }

    /// 多余实例请求 → 显示主窗。
    @objc private func handleShowWindowRequest() {
        showMainWindow()
    }

    // 点 Dock 图标 / 重新打开 → 显示主窗
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        KernelRunner.shared.terminateForAppExit()
    }

    // 红叉关闭 → 不真正关，收进托盘（窗口保活，便于再次唤出）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideToTray()
        return false
    }

    // MARK: 托盘

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: "Sail")
        icon?.isTemplate = true   // 跟随菜单栏明暗自动反色，保证可见
        item.button?.image = icon
        trayMenu.delegate = self  // 打开前动态重建，刷新勾选状态
        // 不设 item.menu（否则左右键都弹菜单）。改为按钮 action：左键呼出主界面，右键弹菜单。
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    /// 左键 → 显示主界面；右键 / Control+左键 → 弹托盘菜单。
    @objc private func statusItemClicked() {
        let e = NSApp.currentEvent
        let isRight = e?.type == .rightMouseUp || (e?.modifierFlags.contains(.control) ?? false)
        if isRight, let button = statusItem?.button {
            trayMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        } else {
            showMainWindow()
        }
    }

    // 每次打开托盘菜单前重建，反映当前模式/开关
    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuildTrayMenu(menu) }
    }

    @MainActor
    private func rebuildTrayMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = SettingsStore.shared

        // 有新版本：置顶高亮一个下载入口（菜单栏常驻，比埋在设置里更易被看到）
        let updater = AppUpdater.shared
        if updater.installing {
            let item = NSMenuItem(title: "⏳ 正在下载并安装更新…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item); menu.addItem(.separator())
        } else if updater.updateAvailable, let v = updater.latest?.version {
            let item = trayItem("🆕 发现新版本 v\(v)，点击更新", #selector(downloadUpdateFromTray))
            menu.addItem(item)
            menu.addItem(.separator())
        }

        menu.addItem(trayItem("显示主界面", #selector(showMainWindow)))
        menu.addItem(.separator())

        // 代理分组（订阅自带 proxy-groups）：每组一个子菜单，selector 组可点选成员切换、
        // url-test 组只读高亮。无分组时回退到扁平的「切换节点」列表。
        // 后台刷新一次，保证下次打开托盘的分组/选择是最新的（窗口可见时已在轮询）。
        Task { await ProxyGroupStore.shared.refresh() }
        let groups = ProxyGroupStore.shared.groups
        if !groups.isEmpty {
            // 顶层只放一个「分组」二级菜单，展开才是各分组；再展开是组内成员（三级），避免菜单被一堆分组刷满
            let groupsRoot = NSMenuItem(title: "分组", action: nil, keyEquivalent: "")
            let groupsMenu = NSMenu()
            for group in groups {
                let isSelector = group.kind == .selector
                let groupItem = NSMenuItem(title: Self.trayTruncate(group.name), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                if !isSelector {
                    let note = NSMenuItem(title: "自动（内核按延迟选择）", action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    submenu.addItem(note)
                }
                for m in group.members {
                    let mi = NSMenuItem(title: Self.trayTruncate(m.name),
                                        action: isSelector ? #selector(selectGroupMemberFromTray(_:)) : nil,
                                        keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = ["group": group.name, "member": m.name]
                    mi.state = m.name == group.now ? .on : .off
                    mi.isEnabled = isSelector
                    submenu.addItem(mi)
                }
                groupItem.submenu = submenu
                groupsMenu.addItem(groupItem)
            }
            groupsRoot.submenu = groupsMenu
            menu.addItem(groupsRoot)
        } else {
            let note = NSMenuItem(title: "暂无分组（先到「订阅」添加）", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        menu.addItem(.separator())

        let header = NSMenuItem(title: "代理模式", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for mode in ProxyMode.allCases {
            let mi = trayItem("　" + mode.label, #selector(selectProxyMode(_:)))
            mi.representedObject = mode.rawValue
            mi.state = s.routeMode == mode ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())

        let sp = trayItem("系统代理", #selector(toggleSystemProxyFromTray))
        sp.state = s.systemProxyEnabled ? .on : .off
        menu.addItem(sp)
        let tun = trayItem("虚拟网卡 (TUN)", #selector(toggleTunFromTray))
        tun.state = s.tunEnabled ? .on : .off
        menu.addItem(tun)
        menu.addItem(.separator())

        let restart = trayItem("重启内核", #selector(restartKernelFromTray))
        restart.isEnabled = !KernelRunner.shared.isBusy
        menu.addItem(restart)
        menu.addItem(.separator())

        // 用自定义动作而非 terminate:，避免 macOS 给「退出」自动加系统图标
        let quit = NSMenuItem(title: "退出 Sail", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func trayItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        return mi
    }

    /// 截断过长的菜单文案，避免节点名把托盘菜单撑得很宽。
    private static func trayTruncate(_ s: String, _ max: Int = 28) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    @objc private func selectProxyMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ProxyMode(rawValue: raw) else { return }
        Task { @MainActor in SettingsStore.shared.setRouteMode(mode) }
    }

    @objc private func toggleSystemProxyFromTray() {
        Task { @MainActor in let s = SettingsStore.shared; await s.setSystemProxy(!s.systemProxyEnabled) }
    }

    @objc private func toggleTunFromTray() {
        Task { @MainActor in let s = SettingsStore.shared; await s.setTunEnabled(!s.tunEnabled) }
    }

    @objc private func restartKernelFromTray() {
        Task { @MainActor in await KernelRunner.shared.restart() }
    }

    @objc private func downloadUpdateFromTray() {
        Task { @MainActor in await AppUpdater.shared.downloadAndInstall() }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func selectGroupMemberFromTray(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let groupName = info["group"], let member = info["member"] else { return }
        Task { @MainActor in
            let gs = ProxyGroupStore.shared
            guard let group = gs.groups.first(where: { $0.name == groupName }) else { return }
            await gs.select(group, member)
        }
    }

    @objc private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let window = mainWindow ?? NSApp.windows.first { $0.canBecomeMain }
        if let window {
            mainWindow = window
            window.delegate = self
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func hideToTray() {
        // 只隐藏内容窗口：NSApp.windows 还包含状态栏那个窗口，若一并 orderOut 会把托盘图标也藏掉
        // （「叉掉窗口后托盘也没了」的根因）。canBecomeMain 可滤出真正的内容窗口。
        NSApp.windows.filter(\.canBecomeMain).forEach { $0.orderOut(nil) }
        NSApp.setActivationPolicy(.accessory)   // 同时隐藏 Dock 图标
        // 收托盘后把 malloc 在浏览高峰时申请、释放后仍留存的空闲页还给系统，
        // 避免 RSS 长期卡在高水位。延后一拍，等 orderOut + SwiftUI 释放离屏绘制资源后再回收。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
