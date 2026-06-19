import SwiftUI
import AppKit

@main
struct SailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(
                    minWidth: 1000,
                    minHeight: 700
                )
        }
    }
}

/// 应用级钩子：菜单栏（托盘）图标、静默启动、关窗收进托盘、退出收尾。
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var mainWindow: NSWindow?

    // 关掉最后一个窗口不退出——留在托盘
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @MainActor
    func applicationWillFinishLaunching(_ notification: Notification) {
        if SettingsStore.shared.silentStart {
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        SettingsStore.shared.applyAppearance()   // 恢复上次选择的主题外观
        Task { await AppUpdater.shared.check() }  // 静默检查新版本（结果在「设置→关于」展示）
        // 内核随 app 常驻：启动即拉起（已安装时）
        Task { await KernelRunner.shared.start() }
        LatencyTester.shared.restartAuto()       // 自动延迟检查（按设置）
        SubscriptionStore.shared.startAutoUpdate()  // 订阅自动更新（按各订阅间隔）

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
        let menu = NSMenu()
        menu.delegate = self      // 打开前动态重建，刷新勾选状态
        item.menu = menu
        statusItem = item
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

        // 当前节点 + 切换节点子菜单
        let store = SubscriptionStore.shared
        let nodeHeader = NSMenuItem(title: "节点：\(store.selectedNode?.label ?? "未选择")", action: nil, keyEquivalent: "")
        nodeHeader.isEnabled = false
        menu.addItem(nodeHeader)
        if let sub = store.selectedSubscription, !sub.nodes.isEmpty {
            let switchItem = NSMenuItem(title: "切换节点", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for node in sub.nodes {
                let ni = NSMenuItem(title: node.label, action: #selector(selectNodeFromTray(_:)), keyEquivalent: "")
                ni.target = self
                ni.representedObject = node.outboundJSON
                ni.state = store.isSelected(node) ? .on : .off
                submenu.addItem(ni)
            }
            switchItem.submenu = submenu
            menu.addItem(switchItem)
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

    @objc private func selectNodeFromTray(_ sender: NSMenuItem) {
        guard let json = sender.representedObject as? String else { return }
        Task { @MainActor in
            let store = SubscriptionStore.shared
            if let node = store.allNodes.first(where: { $0.outboundJSON == json }) {
                await store.selectNode(node)
            }
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
        NSApp.windows.forEach { $0.orderOut(nil) }
        NSApp.setActivationPolicy(.accessory)   // 同时隐藏 Dock 图标
    }
}
