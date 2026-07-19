import AppKit
import IOKit.hid
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let onboardingCompletedKey = "onboardingCompletedV1"

    private let store = ConfigurationStore()
    private let emitter = EventEmitter()
    private lazy var hidService = HIDService(store: store, emitter: emitter)
    private lazy var settingsController = SettingsWindowController(store: store) { [weak self] in
        self?.hidService.restart()
        self?.refreshMenu()
    }
    private lazy var mainController = MainWindowController(
        store: store,
        requestInputPermission: { [weak self] in self?.requestInputPermission() },
        requestAccessibilityPermission: { [weak self] in self?.requestAccessibility() },
        openInputSettings: { [weak self] in self?.openPrivacyPane("Privacy_ListenEvent") },
        openAccessibilitySettings: { [weak self] in self?.openPrivacyPane("Privacy_Accessibility") },
        showMappings: { [weak self] in self?.showSettings() },
        reconnect: { [weak self] in self?.restartHID() },
        openLog: { [weak self] in self?.openLog() },
        setLoginItem: { [weak self] enabled in self?.setLoginItem(enabled) },
        completeOnboarding: {
            UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        }
    )

    private var statusItem: NSStatusItem!
    private let connectionItem = NSMenuItem(title: "连接：初始化中", action: nil, keyEquivalent: "")
    private let inputPermissionItem = NSMenuItem(title: "输入监控：检查中", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "辅助功能：检查中", action: nil, keyEquivalent: "")
    private let lastKeyItem = NSMenuItem(title: "最近按键：无", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
    private var permissionTimer: Timer?
    private var previousInputAccess: IOHIDAccessType?
    private var lastKeyMessage: String?
    private var wakeRecoveryWorkItem: DispatchWorkItem?
    private var wakeRecoveryPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        setupObservers()

        hidService.onStateChange = { [weak self] _ in self?.refreshMenu() }
        hidService.onInput = { [weak self] message in
            self?.lastKeyItem.title = "最近按键：\(message)"
            self?.lastKeyMessage = message
            self?.refreshMenu()
        }
        hidService.start()
        refreshMenu()
        permissionTimer = Timer.scheduledTimer(
            timeInterval: 2,
            target: self,
            selector: #selector(refreshPermissions),
            userInfo: nil,
            repeats: true
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let permissionsReady = self.hidService.inputMonitoringAccess == kIOHIDAccessTypeGranted
                && self.emitter.accessibilityTrusted
            if !UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey) || !permissionsReady {
                self.showMainWindow()
            }
        }
        AppLogger.shared.log("application_started")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeRecoveryWorkItem?.cancel()
        permissionTimer?.invalidate()
        hidService.stop()
        AppLogger.shared.log("application_stopped")
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "小米遥控器")

        let menu = NSMenu()
        [connectionItem, inputPermissionItem, accessibilityItem, lastKeyItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开控制面板…", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "按键映射…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "请求输入监控权限", action: #selector(requestInputPermission), keyEquivalent: "")
        menu.addItem(withTitle: "请求辅助功能权限", action: #selector(requestAccessibility), keyEquivalent: "")
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(withTitle: "打开日志", action: #selector(openLog), keyEquivalent: "")
        menu.addItem(withTitle: "重新连接", action: #selector(restartHID), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { if $0.target == nil && $0.action != nil { $0.target = self } }
        statusItem.menu = menu
    }

    private func setupObservers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(sessionBecameActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    private func refreshMenu() {
        connectionItem.title = "连接：\(hidService.state.displayName)"
        let inputAccess = hidService.inputMonitoringAccess
        inputPermissionItem.title = "输入监控：\(accessName(inputAccess))"
        accessibilityItem.title = "辅助功能：\(emitter.accessibilityTrusted ? "已授权" : "未授权")"

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let ready: Bool
        if case .connected = hidService.state {
            ready = inputAccess == kIOHIDAccessTypeGranted && emitter.accessibilityTrusted
        } else {
            ready = false
        }
        statusItem.button?.contentTintColor = ready ? .systemGreen : .systemOrange
        let loginEnabled = SMAppService.mainApp.status == .enabled
        mainController.refresh(
            connection: hidService.state,
            inputPermissionName: accessName(inputAccess),
            inputGranted: inputAccess == kIOHIDAccessTypeGranted,
            accessibilityGranted: emitter.accessibilityTrusted,
            loginEnabled: loginEnabled,
            lastKey: lastKeyMessage
        )
    }

    @objc private func refreshPermissions() {
        let currentAccess = hidService.inputMonitoringAccess
        if previousInputAccess != currentAccess {
            AppLogger.shared.log("input_monitoring_changed access=\(accessName(currentAccess))")
            if currentAccess == kIOHIDAccessTypeGranted,
               case .failed = hidService.state {
                hidService.restart()
            }
            previousInputAccess = currentAccess
        }
        refreshMenu()
    }

    private func accessName(_ access: IOHIDAccessType) -> String {
        switch access {
        case kIOHIDAccessTypeGranted: return "已授权"
        case kIOHIDAccessTypeDenied: return "已拒绝"
        default: return "未决定"
        }
    }

    @objc private func requestInputPermission() {
        hidService.requestInputMonitoring()
        refreshMenu()
    }

    @objc private func requestAccessibility() {
        _ = emitter.requestAccessibility()
        refreshMenu()
    }

    @objc private func showSettings() {
        settingsController.refresh()
        settingsController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showMainWindow() {
        refreshMenu()
        mainController.present()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(AppLogger.shared.logURL)
    }

    @objc private func restartHID() {
        hidService.restart()
        refreshMenu()
    }

    @objc private func toggleLoginItem() {
        setLoginItem(SMAppService.mainApp.status != .enabled)
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSApp.presentError(error)
        }
        refreshMenu()
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func systemWillSleep() {
        wakeRecoveryPending = true
        wakeRecoveryWorkItem?.cancel()
        wakeRecoveryWorkItem = nil
        AppLogger.shared.log("system_will_sleep")
        hidService.stop()
    }

    @objc private func systemDidWake() {
        AppLogger.shared.log("system_did_wake recovery=scheduled")
        scheduleWakeRecovery(reason: "system_wake", delay: 3.0)
    }

    @objc private func sessionBecameActive() {
        if wakeRecoveryPending {
            AppLogger.shared.log("session_became_active recovery=scheduled")
            scheduleWakeRecovery(reason: "session_active", delay: 2.0)
        } else if case .stopped = hidService.state {
            AppLogger.shared.log("session_became_active recovery=ordinary_start")
            hidService.start()
        }
    }

    private func scheduleWakeRecovery(reason: String, delay: TimeInterval) {
        wakeRecoveryPending = true
        wakeRecoveryWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeRecoveryWorkItem = nil
            self.wakeRecoveryPending = false
            AppLogger.shared.log("wake_recovery_started reason=\(reason) mode=shared_suppressed")
            self.hidService.restart(preferSharedSuppressed: true)
            self.refreshMenu()
        }
        wakeRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
