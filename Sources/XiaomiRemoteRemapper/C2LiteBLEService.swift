import CoreBluetooth
import Foundation

/// BLE GATT adapter. C2-RC-LITE is the validated profile; other named BLE
/// devices can be selected and learned when they expose a notify characteristic.
///
/// It intentionally uses a separate transport from `HIDService`: the remote
/// has no HID service (0x1812), and reports its five buttons as one-byte GATT
/// notifications on FFC2. macOS pairing in System Settings is not required.
final class C2LiteBLEService: NSObject {
    static let serviceUUID = CBUUID(string: "DBA3FFC0-B4EE-3A90-714E-7D0233123998")
    static let inputCharacteristicUUID = CBUUID(string: "DBA3FFC2-B4EE-3A90-714E-7D0233123998")
    private static let c2DevicePrefix = "ble-c2:"
    private static let genericDevicePrefix = "ble-gatt:"

    private enum DeviceKind {
        case c2
        case generic

        var prefix: String {
            switch self {
            case .c2: return C2LiteBLEService.c2DevicePrefix
            case .generic: return C2LiteBLEService.genericDevicePrefix
            }
        }

        var isC2: Bool {
            switch self {
            case .c2: return true
            case .generic: return false
            }
        }
    }

    var onStateChange: ((ConnectionState) -> Void)?
    var onInput: ((String) -> Void)?
    var onRawInput: ((HIDUsage, Bool) -> Void)?
    var onDevicesChange: (([RemoteDeviceDescriptor]) -> Void)?

    private(set) var availableDevices: [RemoteDeviceDescriptor] = []
    private(set) var state: ConnectionState = .stopped {
        didSet { DispatchQueue.main.async { [weak self] in self?.onStateChange?(self?.state ?? .stopped) } }
    }

    private let store: ConfigurationStore
    private let emitter: EventEmitter
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var deviceKinds: [UUID: DeviceKind] = [:]
    private var inputCharacteristics: [UUID: CBCharacteristic] = [:]
    private var connectingIDs = Set<UUID>()
    private var learningModeEnabled = false
    private var pulseWorkItems: [HIDUsage: DispatchWorkItem] = [:]

    init(store: ConfigurationStore, emitter: EventEmitter) {
        self.store = store
        self.emitter = emitter
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isSelected: Bool {
        store.configuration.selectedDeviceID?.hasPrefix("ble-") == true
    }

    func start() {
        guard central.state == .poweredOn else {
            state = .waiting(selectedDeviceName: store.configuration.selectedDeviceName)
            return
        }
        scanAndReconnect()
    }

    func stop() {
        central.stopScan()
        pulseWorkItems.values.forEach { $0.cancel() }
        pulseWorkItems.removeAll()
        for peripheral in peripherals.values where peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        connectingIDs.removeAll()
        inputCharacteristics.removeAll()
        availableDevices.removeAll()
        onDevicesChange?([])
        state = .stopped
    }

    func restart() {
        stop()
        start()
    }

    func setLearningMode(_ enabled: Bool) {
        learningModeEnabled = enabled
        emitter.releaseHeldInputs()
    }

    private func scanAndReconnect() {
        guard central.state == .poweredOn else { return }
        // A device may expose its useful service only after connecting. Scan
        // broadly, but list only named BLE peripherals so users can explicitly
        // choose a custom remote for learning.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // A previously discovered peripheral can be reconnected immediately,
        // including after sleep/wake, without waiting for the next advertisement.
        guard let selectedID = selectedPeripheralUUID() else {
            state = .waiting(selectedDeviceName: store.configuration.selectedDeviceName)
            return
        }
        for peripheral in central.retrievePeripherals(withIdentifiers: [selectedID]) {
            register(peripheral, kind: selectedDeviceKind ?? .generic)
            connect(peripheral)
        }
    }

    private func selectedPeripheralUUID() -> UUID? {
        guard let id = store.configuration.selectedDeviceID else { return nil }
        for prefix in [Self.c2DevicePrefix, Self.genericDevicePrefix] where id.hasPrefix(prefix) {
            return UUID(uuidString: String(id.dropFirst(prefix.count)))
        }
        return nil
    }

    private var selectedDeviceKind: DeviceKind? {
        guard let id = store.configuration.selectedDeviceID else { return nil }
        if id.hasPrefix(Self.c2DevicePrefix) { return .c2 }
        if id.hasPrefix(Self.genericDevicePrefix) { return .generic }
        return nil
    }

    private func descriptor(for peripheral: CBPeripheral, kind: DeviceKind? = nil) -> RemoteDeviceDescriptor {
        let kind = kind ?? deviceKinds[peripheral.identifier] ?? selectedDeviceKind ?? .generic
        let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteDeviceDescriptor(
            id: kind.prefix + peripheral.identifier.uuidString.lowercased(),
            name: name?.isEmpty == false ? name! : (kind.isC2 ? "C2-RC-LITE" : "未命名 BLE 设备"),
            serial: peripheral.identifier.uuidString,
            transport: kind.isC2 ? "Bluetooth Low Energy（C2 私有协议）" : "Bluetooth Low Energy（通用 GATT）"
        )
    }

    private func register(_ peripheral: CBPeripheral, kind: DeviceKind) {
        peripherals[peripheral.identifier] = peripheral
        deviceKinds[peripheral.identifier] = kind
        let descriptor = descriptor(for: peripheral, kind: kind)
        if let index = availableDevices.firstIndex(where: { $0.id == descriptor.id }) {
            availableDevices[index] = descriptor
        } else {
            availableDevices.append(descriptor)
            availableDevices.sort {
                $0.selectionLabel.localizedStandardCompare($1.selectionLabel) == .orderedAscending
            }
        }
        onDevicesChange?(availableDevices)
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard isSelected,
              descriptor(for: peripheral).id == store.configuration.selectedDeviceID,
              peripheral.state == .disconnected,
              connectingIDs.insert(peripheral.identifier).inserted else { return }
        state = .waiting(selectedDeviceName: store.configuration.selectedDeviceName)
        central.connect(peripheral)
        AppLogger.shared.log("ble_gatt_connect_requested id=\(peripheral.identifier.uuidString)")
    }

    private func process(_ data: Data, peripheral: CBPeripheral) {
        guard descriptor(for: peripheral).id == store.configuration.selectedDeviceID else { return }
        for byte in data {
            let usage = HIDUsage(page: 0xFF00, usage: UInt32(byte))
            onRawInput?(usage, true)
            guard !learningModeEnabled else { continue }
            guard let mapping = store.mappings.first(where: { $0.usage == usage }) else {
                AppLogger.shared.log("c2_ble_input byte=0x\(String(format: "%02X", byte)) action=unmapped")
                continue
            }
            onInput?(mapping.recentKeyDescription)
            AppLogger.shared.log("c2_ble_input byte=0x\(String(format: "%02X", byte)) action=\(mapping.action.rawValue)")
            if mapping.action == .fnModifier {
                emitter.toggleFnModifier()
                continue
            }
            emitter.emit(mapping.action, isDown: true)

            // This protocol exposes press notifications only. A short, explicit
            // release preserves ordinary key actions without leaving modifiers
            // or Delete held indefinitely.
            pulseWorkItems[usage]?.cancel()
            let release = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pulseWorkItems.removeValue(forKey: usage)
                self.emitter.emit(mapping.action, isDown: false)
            }
            pulseWorkItems[usage] = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: release)
        }
    }
}

extension C2LiteBLEService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            AppLogger.shared.log("c2_ble_central_powered_on")
            start()
        case .unauthorized:
            state = .failed("需要允许蓝牙访问")
        case .poweredOff:
            state = .failed("蓝牙已关闭")
        case .unsupported:
            state = .failed("此 Mac 不支持蓝牙低功耗")
        default:
            state = .waiting(selectedDeviceName: store.configuration.selectedDeviceName)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isC2 = advertisedName.localizedCaseInsensitiveCompare("C2-RC-LITE") == .orderedSame
            || advertisedServices.contains(Self.serviceUUID)
        guard isC2 || !advertisedName.isEmpty else { return }
        register(peripheral, kind: isC2 ? .c2 : .generic)
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectingIDs.remove(peripheral.identifier)
        peripheral.delegate = self
        if deviceKinds[peripheral.identifier] == .c2 {
            peripheral.discoverServices([Self.serviceUUID])
        } else {
            peripheral.discoverServices(nil)
        }
        AppLogger.shared.log("ble_gatt_connected id=\(peripheral.identifier.uuidString)")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectingIDs.remove(peripheral.identifier)
        state = .waiting(selectedDeviceName: store.configuration.selectedDeviceName)
        AppLogger.shared.log("ble_gatt_connect_failed error=\(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectingIDs.remove(peripheral.identifier)
        inputCharacteristics.removeValue(forKey: peripheral.identifier)
        guard descriptor(for: peripheral).id == store.configuration.selectedDeviceID else { return }
        emitter.releaseHeldInputs()
        state = .waiting(selectedDeviceName: store.configuration.selectedDeviceName)
        AppLogger.shared.log("ble_gatt_disconnected error=\(error?.localizedDescription ?? "none")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scanAndReconnect() }
    }
}

extension C2LiteBLEService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            state = .failed("未找到可用的 BLE 服务")
            return
        }
        if deviceKinds[peripheral.identifier] == .c2 {
            guard let service = services.first(where: { $0.uuid == Self.serviceUUID }) else {
                state = .failed("未找到 C2 按键服务")
                return
            }
            peripheral.discoverCharacteristics([Self.inputCharacteristicUUID], for: service)
        } else {
            services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        let characteristic: CBCharacteristic?
        if deviceKinds[peripheral.identifier] == .c2 {
            characteristic = characteristics.first(where: { $0.uuid == Self.inputCharacteristicUUID })
        } else {
            characteristic = characteristics.first(where: {
                $0.properties.contains(.notify) || $0.properties.contains(.indicate)
            })
        }
        guard let characteristic else { return }
        guard inputCharacteristics[peripheral.identifier] == nil else { return }
        inputCharacteristics[peripheral.identifier] = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard inputCharacteristics[peripheral.identifier]?.uuid == characteristic.uuid else { return }
        guard error == nil, characteristic.isNotifying else {
            state = .failed("无法订阅 BLE 按键通知")
            return
        }
        let name = descriptor(for: peripheral).name
        state = .connected(product: "\(name)（BLE 按键通知）", serial: peripheral.identifier.uuidString)
        AppLogger.shared.log("ble_gatt_notify_enabled characteristic=\(characteristic.uuid.uuidString)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard inputCharacteristics[peripheral.identifier]?.uuid == characteristic.uuid,
              error == nil,
              let value = characteristic.value else { return }
        process(value, peripheral: peripheral)
    }
}
