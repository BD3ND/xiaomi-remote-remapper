import Foundation
import ApplicationServices
import IOKit.hid
import ServiceManagement

func runSelfTests() -> Int32 {
    var failures: [String] = []

    let expected: [(HIDUsage, RemoteAction)] = [
        (HIDUsage(page: 7, usage: 241), .delete),
        (HIDUsage(page: 7, usage: 62), .fnModifier),
        (HIDUsage(page: 7, usage: 74), .passThrough),
        (HIDUsage(page: 7, usage: 101), .activateCodex),
        (HIDUsage(page: 7, usage: 53), .passThrough),
        (HIDUsage(page: 7, usage: 102), .power)
    ]
    for (usage, action) in expected where AppConfiguration.defaults.action(for: usage) != action {
        failures.append("default mapping \(usage) should be \(action.rawValue)")
    }

    let expectedNames: [(HIDUsage, String)] = [
        (HIDUsage(page: 7, usage: 241), "返回键"),
        (HIDUsage(page: 7, usage: 62), "语音键"),
        (HIDUsage(page: 7, usage: 74), "主页键"),
        (HIDUsage(page: 7, usage: 101), "菜单键"),
        (HIDUsage(page: 7, usage: 53), "直播键"),
        (HIDUsage(page: 7, usage: 102), "电源键")
    ]
    for (usage, name) in expectedNames
        where AppConfiguration.defaultMappings.first(where: { $0.usage == usage })?.keyName != name {
        failures.append("default mapping \(usage) should be named \(name)")
    }
    if AppConfiguration.defaultMappings[3].recentKeyDescription
        != "菜单键（Application）→ Codex 前台并聚焦输入框" {
        failures.append("recent key description was not user-facing")
    }
    let expectedRemoteActions: [RemoteAction] = [
        .tab, .escape, .pageUp, .pageDown, .space, .returnKey,
        .missionControl, .showDesktop, .spotlight, .playPause, .mute
    ]
    if RemoteAction.remoteFirstBatch != expectedRemoteActions
        || !expectedRemoteActions.allSatisfy(RemoteAction.allCases.contains) {
        failures.append("remote-first action list was incomplete or reordered")
    }
    let customShortcutPreferences: [String: Any] = [
        "36": [
            "enabled": true,
            "value": ["parameters": [65_535, 103, CGEventFlags.maskCommand.rawValue]]
        ]
    ]
    let customShowDesktop = SystemShortcutResolver.resolve(
        .showDesktop,
        preferences: customShortcutPreferences
    )
    if customShowDesktop.keyCode != 103
        || customShowDesktop.flags != .maskCommand
        || customShowDesktop.source != "user_configuration"
        || !customShowDesktop.isEnabled {
        failures.append("custom show desktop shortcut was not resolved")
    }
    let disabledShortcutPreferences: [String: Any] = ["36": ["enabled": false]]
    let disabledShowDesktop = SystemShortcutResolver.resolve(
        .showDesktop,
        preferences: disabledShortcutPreferences
    )
    if disabledShowDesktop.source != "user_configuration_disabled"
        || disabledShowDesktop.isEnabled {
        failures.append("disabled show desktop shortcut was not marked disabled")
    }
    if SystemShortcutResolver.resolve(.missionControl, preferences: nil)
        != SystemShortcutResolver.Shortcut.missionControl.fallback {
        failures.append("missing Mission Control shortcut did not use the documented fallback")
    }
    let customSpotlightPreferences: [String: Any] = [
        "64": [
            "enabled": true,
            "value": ["parameters": [65_535, 100, CGEventFlags.maskAlternate.rawValue]]
        ]
    ]
    let customSpotlight = SystemShortcutResolver.resolve(
        .spotlight,
        preferences: customSpotlightPreferences
    )
    if customSpotlight.keyCode != 100
        || customSpotlight.flags != .maskAlternate
        || customSpotlight.source != "user_configuration"
        || !customSpotlight.isEnabled {
        failures.append("custom Spotlight shortcut was not resolved")
    }
    if SystemShortcutResolver.resolve(.spotlight, preferences: nil)
        != SystemShortcutResolver.Shortcut.spotlight.fallback {
        failures.append("missing Spotlight shortcut did not use the documented fallback")
    }
    if ConnectionState.waiting(selectedDeviceName: "测试遥控器").displayName
        != "已选择：测试遥控器（当前离线，等待自动重连）" {
        failures.append("offline selected device state did not preserve user selection")
    }
    if ConnectionState.waiting(selectedDeviceName: nil).displayName != "尚未选择遥控器" {
        failures.append("unselected waiting state was not distinguishable from an offline selection")
    }

    let suppression = SuppressionMappingController.suppressionJSON(for: AppConfiguration.defaultMappings)
    if suppression.contains("0x70000004a") || suppression.contains("0x700000035") {
        failures.append("pass-through keys were included in suppression mapping")
    }
    if !suppression.contains("0x700000065") {
        failures.append("Application key was missing from suppression mapping")
    }
    let preciseMatching = SuppressionMappingController.matchingJSON(deviceID: "test-device-id")
    if !preciseMatching.contains("PhysicalDeviceUniqueID")
        || !preciseMatching.contains("test-device-id")
        || preciseMatching.contains("VendorID") {
        failures.append("suppression matching was not device-specific")
    }
    if HIDUsage(page: 7, usage: UInt32.max).isLearnable
        || HIDUsage(page: 7, usage: 0).isLearnable
        || !HIDUsage(page: 7, usage: 241).isLearnable {
        failures.append("HID learning filter accepted an array placeholder or rejected a key")
    }
    if HIDUsage.decodedArrayUsage(page: 7, value: 241) != HIDUsage(page: 7, usage: 241)
        || HIDUsage.decodedArrayUsage(page: 7, value: -15) != nil
        || HIDUsage.decodedArrayUsage(page: 7, value: 0) != nil {
        failures.append("keyboard array value was not safely decoded into a usage")
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("XiaomiRemoteRemapperSelfTest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")

    do {
        let store = ConfigurationStore(fileURL: url)
        try store.bindSerial("test-serial")
        let selectedDevice = RemoteDeviceDescriptor(
            id: "test-physical-device-id",
            name: "小米语音遥控器",
            serial: "test-serial",
            vendorID: HIDService.vendorID,
            productID: HIDService.productID
        )
        try store.selectDevice(selectedDevice)
        try store.setAction(.logOnly, for: HIDUsage(page: 7, usage: 241))
        let learnedUsage = HIDUsage(page: 12, usage: 34)
        let learnedFirstTime = try store.learnUsage(learnedUsage)
        let learnedSecondTime = try store.learnUsage(learnedUsage)
        if !learnedFirstTime || learnedSecondTime {
            failures.append("learned usage was not added exactly once")
        }

        let secondDevice = RemoteDeviceDescriptor(
            id: "second-physical-device-id",
            name: "小米语音遥控器 2",
            serial: nil,
            vendorID: HIDService.vendorID,
            productID: HIDService.productID
        )
        try store.selectDevice(secondDevice)
        if store.mappings.first(where: { $0.usage == HIDUsage(page: 7, usage: 241) })?.action != .delete
            || store.mappings.contains(where: { $0.usage == learnedUsage }) {
            failures.append("new device did not receive an independent default profile")
        }
        try store.setAction(.escape, for: HIDUsage(page: 7, usage: 241))
        try store.selectDevice(selectedDevice)
        if store.mappings.first(where: { $0.usage == HIDUsage(page: 7, usage: 241) })?.action != .logOnly
            || !store.mappings.contains(where: { $0.usage == learnedUsage }) {
            failures.append("switching devices did not restore the saved profile")
        }

        let reloaded = ConfigurationStore(fileURL: url)
        if reloaded.configuration.boundSerial != "test-serial" {
            failures.append("serial was not persisted")
        }
        if reloaded.configuration.selectedDeviceID != selectedDevice.id
            || reloaded.configuration.selectedDeviceName != selectedDevice.name {
            failures.append("selected device was not persisted")
        }
        if reloaded.mappings.first(where: { $0.usage == HIDUsage(page: 7, usage: 241) })?.action != .logOnly
            || reloaded.configuration.deviceProfiles?.count != 2 {
            failures.append("device profiles were not persisted")
        }

        try reloaded.restoreDefaults()
        if reloaded.configuration.boundSerial != "test-serial" {
            failures.append("restoring mappings cleared serial binding")
        }
        if reloaded.configuration.selectedDeviceID != selectedDevice.id {
            failures.append("restoring mappings cleared selected device")
        }
        if reloaded.mappings.first(where: { $0.usage == HIDUsage(page: 7, usage: 241) })?.action != .delete
            || reloaded.mappings.contains(where: { $0.usage == learnedUsage }) {
            failures.append("default mapping was not restored")
        }
        try reloaded.selectDevice(secondDevice)
        if reloaded.mappings.first(where: { $0.usage == HIDUsage(page: 7, usage: 241) })?.action != .escape {
            failures.append("restoring one device changed another device profile")
        }

        let genericDevice = RemoteDeviceDescriptor(
            id: "generic-bluetooth-remote-id",
            name: "通用蓝牙遥控器",
            serial: "generic-serial",
            vendorID: 1234,
            productID: 5678,
            transport: "Bluetooth Low Energy"
        )
        try reloaded.selectDevice(genericDevice)
        if !reloaded.mappings.isEmpty {
            failures.append("unknown Bluetooth device did not start with an empty profile")
        }
        let genericUsage = HIDUsage(page: 12, usage: 205)
        if try !reloaded.learnUsage(genericUsage)
            || reloaded.mappings.first?.keyName != "按键 1" {
            failures.append("generic Bluetooth key was not learned with a neutral name")
        }
        try reloaded.renameMapping(for: genericUsage, to: "返回键")
        if reloaded.mappings.first?.keyName != "返回键" {
            failures.append("custom key name was not persisted")
        }
        try reloaded.deleteMapping(for: genericUsage)
        if !reloaded.mappings.isEmpty {
            failures.append("custom mapping was not deleted")
        }
        try reloaded.restoreDefaults()
        if !reloaded.mappings.isEmpty {
            failures.append("generic device restore unexpectedly installed Xiaomi defaults")
        }

        let migrationURL = directory.appendingPathComponent("legacy-config.json")
        var legacyMappings = AppConfiguration.defaultMappings.map {
            KeyMapping(usage: $0.usage, action: $0.action, keyName: $0.sourceCodeName)
        }
        legacyMappings[3].action = .logOnly
        let legacy = AppConfiguration(
            schemaVersion: 2,
            boundSerial: "legacy-serial",
            mappings: legacyMappings
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(legacy).write(to: migrationURL)

        let migrated = ConfigurationStore(fileURL: migrationURL)
        if migrated.configuration.schemaVersion != AppConfiguration.currentSchemaVersion {
            failures.append("legacy configuration schema was not migrated")
        }
        if migrated.configuration.mappings.map(\.keyName) != AppConfiguration.defaultMappings.map(\.keyName) {
            failures.append("legacy key names were not migrated to remote button names")
        }
        if migrated.mappings.first(where: { $0.usage == HIDUsage(page: 7, usage: 101) })?.action != .logOnly {
            failures.append("key name migration changed a customized action")
        }
        if migrated.configuration.boundSerial != "legacy-serial"
            || migrated.configuration.selectedDeviceID != nil {
            failures.append("legacy serial migration did not preserve device discovery state")
        }
    } catch {
        failures.append("configuration persistence threw: \(error)")
    }

    if failures.isEmpty {
        print("self_test_passed assertions=51")
        return 0
    }
    failures.forEach { fputs("self_test_failed \($0)\n", stderr) }
    return 1
}

func runDiagnostics() -> Int32 {
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    let accessName: String
    switch access {
    case kIOHIDAccessTypeGranted: accessName = "granted"
    case kIOHIDAccessTypeDenied: accessName = "denied"
    default: accessName = "unknown"
    }
    print("input_monitoring=\(accessName) raw=\(access.rawValue)")
    print("accessibility=\(AXIsProcessTrusted() ? "granted" : "denied")")
    print("show_desktop_shortcut=\(SystemShortcutResolver.resolve(.showDesktop).diagnosticDescription)")
    print("mission_control_shortcut=\(SystemShortcutResolver.resolve(.missionControl).diagnosticDescription)")
    print("spotlight_shortcut=\(SystemShortcutResolver.resolve(.spotlight).diagnosticDescription)")

    let store = ConfigurationStore()
    print("bound_serial=\(store.configuration.boundSerial ?? "unbound")")
    print("selected_device_id=\(store.configuration.selectedDeviceID ?? "unbound")")
    print("selected_device_name=\(store.configuration.selectedDeviceName ?? "unknown")")
    print("saved_device_profiles=\(store.configuration.deviceProfiles?.count ?? 0)")
    print("executable=\(CommandLine.arguments[0])")
    return 0
}

func requestPermissions() -> Int32 {
    let inputRequested = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    AppLogger.shared.log("permission_request input=\(inputRequested) accessibility=\(accessibilityTrusted)")
    return 0
}

func probeHIDOpenPaths() -> Int32 {
    func report(_ message: String) {
        print(message)
        AppLogger.shared.log("hid_probe \(message)")
    }

    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matching: [String: Any] = [
        kIOHIDVendorIDKey as String: HIDService.vendorID,
        kIOHIDProductIDKey as String: HIDService.productID,
        kIOHIDPrimaryUsagePageKey as String: 1,
        kIOHIDPrimaryUsageKey as String: 6
    ]
    IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

    let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    report("manager_none=\(managerResult)")
    guard managerResult == kIOReturnSuccess else { return 1 }

    let copiedDevices = IOHIDManagerCopyDevices(manager)
    let devices: [IOHIDDevice] = (copiedDevices as NSSet?)?.allObjects.map { $0 as! IOHIDDevice } ?? []
    report("device_count=\(devices.count)")
    IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))

    for device in devices {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? "unavailable"
        let normalResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        report("device_none=\(normalResult) product=\(product) serial=\(serial)")
        if normalResult == kIOReturnSuccess {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        let seizeResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        report("device_seize=\(seizeResult) product=\(product) serial=\(serial)")
        if seizeResult == kIOReturnSuccess {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }
    return devices.isEmpty ? 2 : 0
}

func setLoginItem(enabled: Bool) -> Int32 {
    do {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        let status = SMAppService.mainApp.status
        AppLogger.shared.log("login_item requested=\(enabled) status=\(status.rawValue)")
        return enabled && status != .enabled ? 2 : 0
    } catch {
        AppLogger.shared.log("login_item requested=\(enabled) failed=\(error)")
        return 1
    }
}

func runCodexFocusProbe() -> Int32 {
    let focuser = CodexInputFocuser()
    var finished = false
    var succeeded = false
    focuser.activateAndFocus { result in
        succeeded = result
        finished = true
    }

    let deadline = Date().addingTimeInterval(3)
    while !finished, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    print("codex_input_focus_dispatch=\(succeeded ? "success" : "failed")")
    return succeeded ? 0 : 1
}
