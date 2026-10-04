import AppKit
import IOKit.hid
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let onboardingCompletedKey = "onboardingCompletedV1"

    private let store = ConfigurationStore()
    private let emitter = EventEmitter()
    private lazy var hidService = HIDService(store: store, emitter: emitter)
    private lazy var c2LiteService = C2LiteBLEService(store: store, emitter: emitter)
    private lazy var voiceService = RemoteVoiceService(store: store)
    private lazy var voiceWindow = VoiceWindowController(service: voiceService)
    private lazy var settingsController = SettingsWindowController(
        store: store,
        onConfigurationChange: { [weak self] in
            self?.restartServices()
            self?.refreshMenu()
        },
        onLearningChange: { [weak self] enabled in
            self?.hidService.setLearningMode(enabled)
            self?.c2LiteService.setLearningMode(enabled)
        }
    )
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
        selectDevice: { [weak self] device in self?.selectDevice(device) },
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
        emitter.remoteFnChanged = { [weak self] down in self?.voiceService.remoteFnChanged(down) ?? false }
        NSApp.setActivationPolicy(.accessory)
        setupMenu()
        setupObservers()
        mainController.showVoiceSettings = { [weak self] in self?.showVoice() }

        hidService.onStateChange = { [weak self] _ in self?.refreshMenu() }
        hidService.onInput = { [weak self] message in
            self?.lastKeyItem.title = "最近按键：\(message)"
            self?.lastKeyMessage = message
            self?.refreshMenu()
        }
        hidService.onRawInput = { [weak self] usage, isDown in
            self?.settingsController.receiveInput(usage, isDown: isDown)
        }
        hidService.onDevicesChange = { [weak self] _ in self?.refreshMenu() }
        c2LiteService.onStateChange = { [weak self] _ in self?.refreshMenu() }
        c2LiteService.onInput = { [weak self] message in
            self?.lastKeyItem.title = "最近按键：\(message)"
            self?.lastKeyMessage = message
            self?.refreshMenu()
        }
        c2LiteService.onRawInput = { [weak self] usage, isDown in
            self?.settingsController.receiveInput(usage, isDown: isDown)
        }
        c2LiteService.onDevicesChange = { [weak self] _ in self?.refreshMenu() }
        hidService.start()
        c2LiteService.start()
        voiceService.start()
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
            let permissionsReady = (!self.selectedDeviceIsC2
                || self.hidService.inputMonitoringAccess == kIOHIDAccessTypeGranted)
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
        c2LiteService.stop()
        voiceService.stop()
        AppLogger.shared.log("application_stopped")
    }

    private func setupMenu() {
        // A square item reserves visible menu-bar space even before AppKit has
        // measured the image. Variable-length image-only items can collapse to
        // zero width on some menu-bar layouts.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let statusImage = NSImage(
            systemSymbolName: "dot.radiowaves.left.and.right",
            accessibilityDescription: "蓝牙遥控器"
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        statusImage?.isTemplate = true
        statusItem.button?.image = statusImage
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.contentTintColor = .labelColor
        statusItem.button?.setAccessibilityLabel("蓝牙遥控器按键映射")
        statusItem.isVisible = true

        let menu = NSMenu()
        [connectionItem, inputPermissionItem, accessibilityItem, lastKeyItem].forEach {
            $0.isEnabled = false
            menu.addItem($0)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开控制面板…", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(withTitle: "按键映射…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "遥控器麦克风…", action: #selector(showVoice), keyEquivalent: "")
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
        connectionItem.title = "连接：\(activeConnectionState.displayName)"
        let inputAccess = hidService.inputMonitoringAccess
        inputPermissionItem.title = "输入监控：\(accessName(inputAccess))"
        accessibilityItem.title = "辅助功能：\(emitter.accessibilityTrusted ? "已授权" : "未授权")"

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        let ready: Bool
        if case .connected = activeConnectionState {
            ready = (!selectedDeviceIsC2 || inputAccess == kIOHIDAccessTypeGranted) && emitter.accessibilityTrusted
        } else {
            ready = false
        }
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = ready
            ? "蓝牙遥控器按键映射：工作正常"
            : "蓝牙遥控器按键映射：需要检查连接或权限"
        let loginEnabled = SMAppService.mainApp.status == .enabled
        mainController.refresh(
            connection: activeConnectionState,
            inputPermissionName: accessName(inputAccess),
            inputGranted: inputAccess == kIOHIDAccessTypeGranted,
            inputRequired: !selectedDeviceIsC2,
            accessibilityGranted: emitter.accessibilityTrusted,
            loginEnabled: loginEnabled,
            lastKey: lastKeyMessage,
            availableDevices: availableDevices,
            selectedDeviceID: store.configuration.selectedDeviceID
        )
    }

    @objc private func refreshPermissions() {
        let currentAccess = hidService.inputMonitoringAccess
        if previousInputAccess != currentAccess {
            AppLogger.shared.log("input_monitoring_changed access=\(accessName(currentAccess))")
            if !selectedDeviceIsC2,
               currentAccess == kIOHIDAccessTypeGranted,
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
        AppLogger.shared.log("settings_window_requested")
        settingsController.present()
    }

    @objc private func showVoice() { voiceWindow.present() }

    @objc private func showMainWindow() {
        refreshMenu()
        mainController.present()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(AppLogger.shared.logURL)
    }

    @objc private func restartHID() {
        restartServices()
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

    private func selectDevice(_ device: RemoteDeviceDescriptor) {
        guard store.configuration.selectedDeviceID != device.id else { return }
        do {
            try store.selectDevice(device)
            AppLogger.shared.log("device_selected_by_user name=\(device.name) id=\(device.id)")
            restartServices()
            refreshMenu()
        } catch {
            NSApp.presentError(error)
        }
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
        c2LiteService.stop()
        voiceService.stop()
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
            restartServices()
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
            self.c2LiteService.restart()
            self.voiceService.restart()
            self.refreshMenu()
        }
        wakeRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
    private var selectedDeviceIsC2: Bool {
        store.configuration.selectedDeviceID?.hasPrefix("ble-") == true
    }

    private var activeConnectionState: ConnectionState {
        selectedDeviceIsC2 ? c2LiteService.state : hidService.state
    }

    private var availableDevices: [RemoteDeviceDescriptor] {
        (hidService.availableDevices + c2LiteService.availableDevices)
            .reduce(into: [String: RemoteDeviceDescriptor]()) { $0[$1.id] = $1 }
            .values
            .sorted { $0.selectionLabel.localizedStandardCompare($1.selectionLabel) == .orderedAscending }
    }

    private func restartServices() {
        hidService.restart()
        c2LiteService.restart()
        voiceService.restart()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
