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

    let suppression = SuppressionMappingController.suppressionJSON(for: AppConfiguration.defaultMappings)
    if suppression.contains("0x70000004a") || suppression.contains("0x700000035") {
        failures.append("pass-through keys were included in suppression mapping")
    }
    if !suppression.contains("0x700000065") {
        failures.append("Application key was missing from suppression mapping")
    }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("XiaomiRemoteRemapperSelfTest-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")

    do {
        let store = ConfigurationStore(fileURL: url)
        try store.bindSerial("test-serial")
        try store.setAction(.logOnly, for: HIDUsage(page: 7, usage: 241))

        let reloaded = ConfigurationStore(fileURL: url)
        if reloaded.configuration.boundSerial != "test-serial" {
            failures.append("serial was not persisted")
        }
        if reloaded.configuration.action(for: HIDUsage(page: 7, usage: 241)) != .logOnly {
            failures.append("mapping edit was not persisted")
        }

        try reloaded.restoreDefaults()
        if reloaded.configuration.boundSerial != "test-serial" {
            failures.append("restoring mappings cleared serial binding")
        }
        if reloaded.configuration.action(for: HIDUsage(page: 7, usage: 241)) != .delete {
            failures.append("default mapping was not restored")
        }
    } catch {
        failures.append("configuration persistence threw: \(error)")
    }

    if failures.isEmpty {
        print("self_test_passed assertions=12")
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

    let store = ConfigurationStore()
    print("bound_serial=\(store.configuration.boundSerial ?? "unbound")")
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
    guard #available(macOS 13.0, *) else {
        AppLogger.shared.log("login_item unsupported_macos")
        return 1
    }
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
