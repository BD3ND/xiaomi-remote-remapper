import Foundation
import IOKit.hid

final class HIDService {
    static let vendorID = 10_007
    static let productID = 12_984

    var onStateChange: ((ConnectionState) -> Void)?
    var onInput: ((String) -> Void)?
    var onRawInput: ((HIDUsage, Bool) -> Void)?
    var onDevicesChange: (([RemoteDeviceDescriptor]) -> Void)?

    private(set) var availableDevices: [RemoteDeviceDescriptor] = []

    private let store: ConfigurationStore
    private let emitter: EventEmitter
    private let suppressionMapping = SuppressionMappingController()
    private var manager: IOHIDManager?
    private var connectedDevices: Set<IOHIDDevice> = []
    private var deviceDescriptors: [IOHIDDevice: RemoteDeviceDescriptor] = [:]
    private var pressedUsages: Set<HIDUsage> = []
    private var arrayElementUsages: [IOHIDElement: HIDUsage] = [:]
    private var suppressedDeviceID: String?
    private(set) var learningModeEnabled = false
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

        let reason = preferSharedSuppressed ? "wake_recovery" : "device_selection"
        _ = startSharedSuppressed(reason: reason)
    }

    @discardableResult
    private func startSharedSuppressed(reason: String) -> Bool {
        _ = suppressionMapping.clearLegacyBroadMapping()
        if let selectedDeviceID = store.configuration.selectedDeviceID,
           !selectedDeviceID.hasPrefix("ble-") {
            guard suppressionMapping.apply(
                mappings: suppressionMappings,
                deviceID: selectedDeviceID
            ) else {
                state = .failed("无法应用所选遥控器的原按键抑制映射")
                return false
            }
            suppressedDeviceID = selectedDeviceID
        }
        let sharedResult = openManager(options: IOOptionBits(kIOHIDOptionsTypeNone))
        guard sharedResult == kIOReturnSuccess else {
            closeManager()
            if let suppressedDeviceID {
                suppressionMapping.clear(deviceID: suppressedDeviceID)
                self.suppressedDeviceID = nil
            }
            if sharedResult == kIOReturnExclusiveAccess {
                state = .failed("蓝牙 HID 被其他映射程序占用，请让 Karabiner 忽略目标设备")
            } else {
                state = .failed("共享读取打开失败：\(sharedResult)")
            }
            AppLogger.shared.log("hid_manager_open_failed result=\(sharedResult) mode=shared_suppressed")
            return false
        }
        state = .waiting(selectedDeviceName: store.configuration.selectedDeviceName)
        AppLogger.shared.log(
            "hid_manager_started scope=bluetooth_hid selected_device=\(store.configuration.selectedDeviceID ?? "unbound") mode=shared_suppressed reason=\(reason)"
        )
        return true
    }

    private func openManager(options: IOOptionBits) -> IOReturn {
        let newManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = newManager

        let matching: [[String: Any]] = [
            [kIOHIDTransportKey as String: kIOHIDTransportBluetoothValue as String],
            [kIOHIDTransportKey as String: "Bluetooth Low Energy"],
            [kIOHIDTransportKey as String: kIOHIDTransportBluetoothLowEnergyValue as String]
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatchingMultiple(newManager, matching as CFArray)
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
        deviceDescriptors.removeAll()
        availableDevices.removeAll()
        DispatchQueue.main.async { [weak self] in self?.onDevicesChange?([]) }
        pressedUsages.removeAll()
        arrayElementUsages.removeAll()
        closeManager()
        if let suppressedDeviceID {
            suppressionMapping.clear(deviceID: suppressedDeviceID)
            self.suppressedDeviceID = nil
        }
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

    func setLearningMode(_ enabled: Bool) {
        guard learningModeEnabled != enabled else { return }
        learningModeEnabled = enabled
        emitter.releaseHeldInputs()
        pressedUsages.removeAll()
        arrayElementUsages.removeAll()
        if let selectedDeviceID = store.configuration.selectedDeviceID,
           !selectedDeviceID.hasPrefix("ble-"),
           suppressionMapping.apply(mappings: suppressionMappings, deviceID: selectedDeviceID) {
            suppressedDeviceID = selectedDeviceID
        }
        AppLogger.shared.log("mapping_learning_mode enabled=\(enabled)")
    }

    private var suppressionMappings: [KeyMapping] {
        guard learningModeEnabled else { return store.mappings }
        return store.mappings.map {
            KeyMapping(usage: $0.usage, action: .logOnly, keyName: $0.keyName)
        }
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        guard let descriptor = descriptor(for: device) else {
            AppLogger.shared.log("device_ignored reason=missing_physical_device_id")
            return
        }
        deviceDescriptors[device] = descriptor
        publishAvailableDevices()

        if store.configuration.selectedDeviceID == nil {
            let shouldAutoSelect: Bool
            if let boundSerial = store.configuration.boundSerial {
                shouldAutoSelect = boundSerial == descriptor.serial
            } else {
                shouldAutoSelect = descriptor.isKnownXiaomiRemote
            }
            guard shouldAutoSelect else {
                AppLogger.shared.log(
                    "device_available selected=false name=\(descriptor.name) id=\(descriptor.id)"
                )
                return
            }
            do {
                try store.selectDevice(descriptor)
                AppLogger.shared.log(
                    "device_selected_automatically name=\(descriptor.name) id=\(descriptor.id)"
                )
            } catch {
                AppLogger.shared.log("device_selection_save_failed error=\(error)")
            }
        }

        guard store.configuration.selectedDeviceID == descriptor.id else {
            AppLogger.shared.log(
                "device_available selected=false name=\(descriptor.name) id=\(descriptor.id)"
            )
            return
        }

        connectedDevices.insert(device)
        if suppressionMapping.apply(mappings: suppressionMappings, deviceID: descriptor.id) {
            suppressedDeviceID = descriptor.id
        }

        let displayProduct = "\(descriptor.name)（共享读取/原键抑制）"
        state = .connected(product: displayProduct, serial: descriptor.serial)
        AppLogger.shared.log(
            "device_connected product=\(descriptor.name) id=\(descriptor.id) mode=shared_suppressed"
        )
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let descriptor = deviceDescriptors.removeValue(forKey: device)
        publishAvailableDevices()
        guard descriptor?.id == store.configuration.selectedDeviceID else { return }
        connectedDevices.remove(device)
        emitter.releaseHeldInputs()
        pressedUsages.removeAll()
        arrayElementUsages.removeAll()
        state = connectedDevices.isEmpty
            ? .waiting(selectedDeviceName: store.configuration.selectedDeviceName)
            : state
        AppLogger.shared.log("device_disconnected remaining=\(connectedDevices.count)")
    }

    private func inputReceived(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let device = IOHIDElementGetDevice(element)
        guard let descriptor = deviceDescriptors[device] ?? descriptor(for: device),
              descriptor.id == store.configuration.selectedDeviceID else { return }
        let rawInput = HIDUsage(
            page: IOHIDElementGetUsagePage(element),
            usage: IOHIDElementGetUsage(element)
        )
        let integerValue = IOHIDValueGetIntegerValue(value)
        let input: HIDUsage
        let isDown: Bool
        if rawInput.usage == UInt32.max {
            if let decoded = HIDUsage.decodedArrayUsage(page: rawInput.page, value: integerValue) {
                input = decoded
                isDown = true
                arrayElementUsages[element] = decoded
            } else if integerValue == 0, let released = arrayElementUsages.removeValue(forKey: element) {
                input = released
                isDown = false
            } else {
                return
            }
        } else {
            input = rawInput
            isDown = integerValue != 0
        }
        if input.isLearnable {
            DispatchQueue.main.async { [weak self] in self?.onRawInput?(input, isDown) }
        }
        guard !learningModeEnabled else { return }
        let mapping = store.mappings.first(where: { $0.usage == input })
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
            guard pressedUsages.remove(input) != nil else {
                AppLogger.shared.log("duplicate_key_state_ignored usage=\(input) state=up")
                return
            }
        }
        if isDown, let mapping {
            let description = mapping.recentKeyDescription
            DispatchQueue.main.async { [weak self] in self?.onInput?(description) }
        }
        emitter.emit(action, isDown: isDown)
    }

    private func descriptor(for device: IOHIDDevice) -> RemoteDeviceDescriptor? {
        guard let id = property("PhysicalDeviceUniqueID", device: device) else { return nil }
        let transport = property(kIOHIDTransportKey, device: device) ?? "Bluetooth"
        guard transport.localizedCaseInsensitiveContains("bluetooth") else { return nil }
        let name = property(kIOHIDProductKey, device: device) ?? "蓝牙 HID 遥控器"
        let serial = property(kIOHIDSerialNumberKey, device: device)
        return RemoteDeviceDescriptor(
            id: id,
            name: name,
            serial: serial,
            vendorID: numberProperty(kIOHIDVendorIDKey, device: device),
            productID: numberProperty(kIOHIDProductIDKey, device: device),
            transport: transport
        )
    }

    private func publishAvailableDevices() {
        availableDevices = Array(Set(deviceDescriptors.values.map(\.id)))
            .compactMap { id in deviceDescriptors.values.first(where: { $0.id == id }) }
            .sorted { $0.selectionLabel.localizedStandardCompare($1.selectionLabel) == .orderedAscending }
        let devices = availableDevices
        DispatchQueue.main.async { [weak self] in self?.onDevicesChange?(devices) }
    }

    private func property(_ key: String, device: IOHIDDevice) -> String? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private func numberProperty(_ key: String, device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
    }
}
