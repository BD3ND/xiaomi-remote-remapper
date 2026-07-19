import Foundation
import IOKit.hid

final class HIDService {
    static let vendorID = 10_007
    static let productID = 12_984

    var onStateChange: ((ConnectionState) -> Void)?
    var onInput: ((String) -> Void)?

    private let store: ConfigurationStore
    private let emitter: EventEmitter
    private let suppressionMapping = SuppressionMappingController()
    private var manager: IOHIDManager?
    private var connectedDevices: Set<IOHIDDevice> = []
    private var pressedUsages: Set<HIDUsage> = []
    private enum OpenMode: String {
        case exclusive
        case sharedSuppressed = "shared_suppressed"
    }
    private var openMode: OpenMode = .exclusive
    private(set) var state: ConnectionState = .stopped {
        didSet { DispatchQueue.main.async { [weak self] in self?.onStateChange?(self?.state ?? .stopped) } }
    }

    init(store: ConfigurationStore, emitter: EventEmitter) {
        self.store = store
        self.emitter = emitter
    }

    var inputMonitoringAccess: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start(preferSharedSuppressed: Bool = false) {
        guard manager == nil else { return }
        guard inputMonitoringAccess == kIOHIDAccessTypeGranted else {
            state = .failed("需要输入监控权限")
            AppLogger.shared.log("hid_manager_not_started reason=input_monitoring_permission")
            return
        }

        if preferSharedSuppressed {
            guard startSharedSuppressed(exclusiveResult: nil, reason: "wake_recovery") else { return }
            return
        }

        if store.configuration.mappings.contains(where: { $0.action == .passThrough }) {
            guard startSharedSuppressed(exclusiveResult: nil, reason: "passthrough_configured") else { return }
            return
        }

        openMode = .exclusive
        let exclusiveResult = openManager(options: IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if exclusiveResult == kIOReturnSuccess {
            state = .waiting
            AppLogger.shared.log("hid_manager_started vendor=\(Self.vendorID) product=\(Self.productID) serial=\(store.configuration.boundSerial ?? "unbound") mode=exclusive")
            return
        }

        closeManager()
        guard exclusiveResult == kIOReturnNotPrivileged else {
            let message = exclusiveResult == kIOReturnExclusiveAccess
                ? "设备已被其他程序独占"
                : "IOHIDManagerOpen 返回 \(exclusiveResult)"
            state = .failed(message)
            AppLogger.shared.log("hid_manager_open_failed result=\(exclusiveResult) mode=exclusive")
            return
        }

        _ = startSharedSuppressed(exclusiveResult: exclusiveResult, reason: "exclusive_not_privileged")
    }

    @discardableResult
    private func startSharedSuppressed(exclusiveResult: IOReturn?, reason: String) -> Bool {
        openMode = .sharedSuppressed
        guard suppressionMapping.apply(mappings: store.configuration.mappings) else {
            state = .failed("无法应用原按键抑制映射")
            return false
        }
        let sharedResult = openManager(options: IOOptionBits(kIOHIDOptionsTypeNone))
        guard sharedResult == kIOReturnSuccess else {
            closeManager()
            suppressionMapping.clear()
            state = .failed("共享读取打开失败：\(sharedResult)")
            AppLogger.shared.log("hid_manager_open_failed result=\(sharedResult) mode=shared_suppressed")
            return false
        }
        state = .waiting
        let exclusiveDetail = exclusiveResult.map(String.init) ?? "skipped"
        AppLogger.shared.log("hid_manager_started vendor=\(Self.vendorID) product=\(Self.productID) serial=\(store.configuration.boundSerial ?? "unbound") mode=shared_suppressed exclusive_result=\(exclusiveDetail) reason=\(reason)")
        return true
    }

    private func openManager(options: IOOptionBits) -> IOReturn {
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = newManager

        var matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDPrimaryUsagePageKey as String: 1,
            kIOHIDPrimaryUsageKey as String: 6
        ]
        if let serial = store.configuration.boundSerial, !serial.isEmpty {
            matching[kIOHIDSerialNumberKey as String] = serial
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(newManager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(newManager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(newManager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(newManager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue().inputReceived(value)
        }, context)
        IOHIDManagerScheduleWithRunLoop(newManager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        return IOHIDManagerOpen(newManager, options)
    }

    func stop() {
        emitter.releaseHeldInputs()
        connectedDevices.removeAll()
        pressedUsages.removeAll()
        closeManager()
        if openMode == .sharedSuppressed {
            suppressionMapping.clear()
        }
        openMode = .exclusive
        state = .stopped
    }

    private func closeManager() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
    }

    func restart(preferSharedSuppressed: Bool = false) {
        stop()
        start(preferSharedSuppressed: preferSharedSuppressed)
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        connectedDevices.insert(device)
        if openMode == .sharedSuppressed {
            suppressionMapping.apply(mappings: store.configuration.mappings)
        }
        let product = property(kIOHIDProductKey, device: device) ?? "小米蓝牙遥控器 2 Pro"
        let serial = property(kIOHIDSerialNumberKey, device: device)

        if store.configuration.boundSerial == nil, let serial, !serial.isEmpty {
            do {
                try store.bindSerial(serial)
                AppLogger.shared.log("device_serial_bound serial=\(serial)")
            } catch {
                AppLogger.shared.log("device_serial_bind_failed error=\(error)")
            }
        }

        let displayProduct = openMode == .exclusive ? product : "\(product)（共享读取/原键抑制）"
        state = .connected(product: displayProduct, serial: serial)
        AppLogger.shared.log("device_connected product=\(product) serial=\(serial ?? "unavailable") mode=\(openMode.rawValue)")
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        connectedDevices.remove(device)
        emitter.releaseHeldInputs()
        pressedUsages.removeAll()
        state = connectedDevices.isEmpty ? .waiting : state
        AppLogger.shared.log("device_disconnected remaining=\(connectedDevices.count)")
    }

    private func inputReceived(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let input = HIDUsage(
            page: IOHIDElementGetUsagePage(element),
            usage: IOHIDElementGetUsage(element)
        )
        let integerValue = IOHIDValueGetIntegerValue(value)
        let isDown = integerValue != 0
        let mapping = store.configuration.mappings.first(where: { $0.usage == input })
        let action = mapping?.action
        let message = "usage=\(input) action=\(action?.rawValue ?? "unmapped") state=\(isDown ? "down" : "up") value=\(integerValue)"
        AppLogger.shared.log(message)

        guard let action else { return }
        if isDown {
            guard pressedUsages.insert(input).inserted else {
                AppLogger.shared.log("duplicate_key_state_ignored usage=\(input) state=down")
                return
            }
        } else {
            pressedUsages.remove(input)
        }
        if isDown, let mapping {
            let description = mapping.recentKeyDescription
            DispatchQueue.main.async { [weak self] in self?.onInput?(description) }
        }
        emitter.emit(action, isDown: isDown)
    }

    private func property(_ key: String, device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}
