import CoreBluetooth
import Foundation

/// One-shot, read-only BLE inventory for Xiaomi voice remotes. It deliberately
/// never enables notifications or writes a characteristic, so running it cannot
/// start a microphone stream or change a remote's pairing/configuration.
final class VoiceCapabilityProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let atvvService = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private static let deviceInformationService = CBUUID(string: "180A")
    private static let modelNumberCharacteristic = CBUUID(string: "2A24")

    private var central: CBCentralManager!
    private var selectedPeripheral: CBPeripheral?
    private var completed = false
    private var exitCode: Int32 = 1
    private var foundATVV = false
    private var foundModelNumber = false
    private var waitingServices = Set<CBUUID>()
    private var timeoutTimer: Timer?

    func run(timeout: TimeInterval = 20) -> Int32 {
        central = CBCentralManager(delegate: self, queue: .main)
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.finish(reason: "timeout")
        }
        while !completed {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        return exitCode
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !completed else { return }
        guard central.state == .poweredOn else {
            print("voice_probe_error=bluetooth_state_\(central.state.rawValue)")
            finish(reason: "bluetooth_not_ready")
            return
        }
        // A paired HID remote commonly stops advertising while connected. Its
        // selected PhysicalDeviceUniqueID is also the CoreBluetooth identifier
        // on the tested Xiaomi remotes, so retrieve it before relying on scan.
        if let selectedID = ConfigurationStore().configuration.selectedDeviceID,
           let identifier = UUID(uuidString: selectedID),
           let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            selectedPeripheral = peripheral
            print("voice_probe=selected_device_retrieved read_only=true")
            central.connect(peripheral)
            return
        }
        print("voice_probe=scan_started read_only=true")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard selectedPeripheral == nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let normalized = name.lowercased()
        guard normalized.contains("小米") || normalized.contains("xiaomi") || normalized.contains("mi rc") else { return }
        selectedPeripheral = peripheral
        central.stopScan()
        print("voice_probe_device name=\(redacted(name)) peripheral=\(peripheral.identifier.uuidString) rssi=\(RSSI)")
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("voice_probe_connection=connected")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("voice_probe_error=connect_failed detail=\(error?.localizedDescription ?? "unknown")")
        finish(reason: "connect_failed")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            print("voice_probe_error=service_discovery_failed detail=\(error?.localizedDescription ?? "unknown")")
            finish(reason: "service_discovery_failed")
            return
        }
        let serviceIDs = services.map(\.uuid.uuidString).sorted().joined(separator: ",")
        foundATVV = services.contains(where: { $0.uuid == Self.atvvService })
        print("voice_probe_services=\(serviceIDs)")
        print("voice_probe_atvv=\(foundATVV ? "present" : "absent")")
        for service in services {
            waitingServices.insert(service.uuid)
            if service.uuid == Self.deviceInformationService {
                peripheral.discoverCharacteristics([Self.modelNumberCharacteristic], for: service)
            } else {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
        if waitingServices.isEmpty { finish(reason: "no_target_services") }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        defer {
            waitingServices.remove(service.uuid)
            if waitingServices.isEmpty { finish(reason: "inventory_complete") }
        }
        guard error == nil, let characteristics = service.characteristics else {
            print("voice_probe_error=characteristic_discovery_failed service=\(service.uuid.uuidString)")
            return
        }
        let characteristicDetails = characteristics
            .map { "\($0.uuid.uuidString):0x\(String($0.properties.rawValue, radix: 16))" }
            .sorted()
            .joined(separator: ",")
        print("voice_probe_characteristics service=\(service.uuid.uuidString) values=\(characteristicDetails)")
        guard service.uuid == Self.deviceInformationService,
              let model = characteristics.first(where: { $0.uuid == Self.modelNumberCharacteristic }) else { return }
        foundModelNumber = true
        peripheral.readValue(for: model)
        // Keep the run loop alive for the read callback.
        waitingServices.insert(CBUUID(string: "FFFF"))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.modelNumberCharacteristic else { return }
        waitingServices.remove(CBUUID(string: "FFFF"))
        if let value = characteristic.value,
           let model = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            print("voice_probe_model_number=\(model)")
        } else if let value = characteristic.value {
            print("voice_probe_model_number_hex=\(value.map { String(format: "%02X", $0) }.joined())")
        } else {
            print("voice_probe_model_number=unavailable")
        }
        if waitingServices.isEmpty { finish(reason: "inventory_complete") }
    }

    private func finish(reason: String) {
        guard !completed else { return }
        central?.stopScan()
        if let peripheral = selectedPeripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        timeoutTimer?.invalidate()
        if foundATVV {
            print("voice_probe_result=atvv_candidate")
            print("voice_probe_next=ATVV capability negotiation and short audio test require explicit approval")
            exitCode = 0
        } else {
            print("voice_probe_result=no_standard_atvv")
            exitCode = 2
        }
        if !foundModelNumber { print("voice_probe_model_number=not_exposed") }
        print("voice_probe_finished=\(reason)")
        completed = true
    }

    private func redacted(_ value: String) -> String {
        "name_len_\(value.count)"
    }
}

func runVoiceCapabilityProbe() -> Int32 {
    VoiceCapabilityProbe().run()
}

/// Temporary protocol triage for the second Xiaomi remote. It subscribes only
/// to the two observed notify characteristics and stores counts/lengths, never
/// payload bytes. No characteristic is written and no audio is persisted.
final class VoiceNotificationCapture: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let candidates: Set<CBUUID> = [CBUUID(string: "FF03"), CBUUID(string: "FF14")]
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var completed = false
    private var phase = "connecting"
    private var baseline = [CBUUID: (frames: Int, bytes: Int)]()
    private var speaking = [CBUUID: (frames: Int, bytes: Int)]()
    private var timeoutTimer: Timer?

    func run() -> Int32 {
        central = CBCentralManager(delegate: self, queue: .main)
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            self?.finish(reason: "setup_timeout")
        }
        while !completed {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        return 0
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { finish(reason: "bluetooth_not_ready"); return }
        guard let id = ConfigurationStore().configuration.selectedDeviceID,
              let identifier = UUID(uuidString: id),
              let device = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            print("voice_capture_error=selected_remote_not_available")
            finish(reason: "device_unavailable")
            return
        }
        peripheral = device
        central.connect(device)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("voice_capture_error=connect_failed")
        finish(reason: "connect_failed")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { finish(reason: "service_discovery_failed"); return }
        peripheral.services?.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] where candidates.contains(characteristic.uuid) {
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard candidates.contains(characteristic.uuid), error == nil, characteristic.isNotifying, phase == "connecting" else { return }
        phase = "listening"
        announce("voice_capture_ready=speak_any_time_duration_30_seconds")
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.completed else { return }
            self.finish(reason: "capture_complete")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, candidates.contains(characteristic.uuid), let value = characteristic.value else { return }
        if phase == "listening" {
            speaking[characteristic.uuid, default: (0, 0)].frames += 1
            speaking[characteristic.uuid, default: (0, 0)].bytes += value.count
        }
    }

    private func finish(reason: String) {
        guard !completed else { return }
        timeoutTimer?.invalidate()
        if let peripheral, peripheral.state != .disconnected { central.cancelPeripheralConnection(peripheral) }
        for uuid in candidates.sorted(by: { $0.uuidString < $1.uuidString }) {
            let idle = baseline[uuid, default: (0, 0)]
            let active = speaking[uuid, default: (0, 0)]
            print("voice_capture_stats characteristic=\(uuid.uuidString) baseline_frames=\(idle.frames) baseline_bytes=\(idle.bytes) speech_frames=\(active.frames) speech_bytes=\(active.bytes)")
        }
        print("voice_capture_finished=\(reason) payload_persisted=false")
        completed = true
    }

    private func announce(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
}

func runVoiceNotificationCapture() -> Int32 {
    VoiceNotificationCapture().run()
}

/// A short, in-memory ATVV transport check for remotes that expose the public
/// Xiaomi ATVV service. It uses only the documented capability request and the
/// documented microphone-open acknowledgement after the remote explicitly
/// requests it. Audio payloads are never printed, decoded, or written to disk.
final class ATVVVoiceFrameProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let serviceUUID = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private static let transmitUUID = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    private static let audioUUID = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    private static let controlUUID = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
    private static let getCapabilities = Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])
    private static let microphoneOpen = Data([0x0C, 0x00])

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var notificationUUIDs = Set<CBUUID>()
    private var completed = false
    private var capabilitiesReceived = false
    private var microphoneOpenSent = false
    private var microphoneRequests = 0
    private var streamStarts = 0
    private var syncPackets = 0
    private var controlPackets = 0
    private var controlOpcodes = Set<UInt8>()
    private var audioFrames = 0
    private var audioBytes = 0
    private var setupTimeout: Timer?
    private var speechTimeout: Timer?
    private var exitCode: Int32 = 1

    func run() -> Int32 {
        central = CBCentralManager(delegate: self, queue: .main)
        setupTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.finish(reason: "setup_timeout")
        }
        while !completed {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        return exitCode
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !completed else { return }
        guard central.state == .poweredOn else {
            announce("atvv_test_error=bluetooth_state_\(central.state.rawValue)")
            finish(reason: "bluetooth_not_ready")
            return
        }
        guard let selectedID = ConfigurationStore().configuration.selectedDeviceID,
              let identifier = UUID(uuidString: selectedID),
              let device = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            announce("atvv_test_error=selected_remote_not_available")
            finish(reason: "device_unavailable")
            return
        }
        peripheral = device
        central.connect(device)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        announce("atvv_test_connection=connected")
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        announce("atvv_test_error=connect_failed")
        finish(reason: "connect_failed")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            announce("atvv_test_error=atvv_service_missing")
            finish(reason: "service_discovery_failed")
            return
        }
        peripheral.discoverCharacteristics([Self.transmitUUID, Self.audioUUID, Self.controlUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, service.uuid == Self.serviceUUID, let characteristics = service.characteristics else {
            announce("atvv_test_error=characteristic_discovery_failed")
            finish(reason: "characteristic_discovery_failed")
            return
        }
        guard let tx = characteristics.first(where: { $0.uuid == Self.transmitUUID }),
              tx.properties.contains(.write),
              let audio = characteristics.first(where: { $0.uuid == Self.audioUUID }),
              audio.properties.contains(.notify),
              let control = characteristics.first(where: { $0.uuid == Self.controlUUID }),
              control.properties.contains(.notify) else {
            announce("atvv_test_error=required_atvv_characteristics_missing")
            finish(reason: "incompatible_atvv_service")
            return
        }
        transmit = tx
        peripheral.setNotifyValue(true, for: audio)
        peripheral.setNotifyValue(true, for: control)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else {
            announce("atvv_test_error=notification_subscription_failed characteristic=\(characteristic.uuid.uuidString)")
            finish(reason: "notification_subscription_failed")
            return
        }
        guard characteristic.uuid == Self.audioUUID || characteristic.uuid == Self.controlUUID else { return }
        notificationUUIDs.insert(characteristic.uuid)
        guard notificationUUIDs == [Self.audioUUID, Self.controlUUID], let transmit else { return }
        announce("atvv_test_capability_request=sent payload_persisted=false")
        peripheral.writeValue(Self.getCapabilities, for: transmit, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error != nil else { return }
        announce("atvv_test_error=command_write_failed")
        finish(reason: "command_write_failed")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        if characteristic.uuid == Self.audioUUID {
            // RC003 physical hold-to-talk can start its own stream without a
            // preceding host MIC_OPEN command. Count packets after CAPS even
            // for that direct path; no packet payload leaves memory.
            guard capabilitiesReceived else { return }
            audioFrames += 1
            audioBytes += value.count
            return
        }
        guard characteristic.uuid == Self.controlUUID, let opcode = value.first else { return }
        controlPackets += 1
        controlOpcodes.insert(opcode)
        switch opcode {
        case 0x0B:
            guard !capabilitiesReceived else { return }
            capabilitiesReceived = true
            setupTimeout?.invalidate()
            announce("atvv_test_ready=hold_voice_button_and_speak_for_5_seconds")
            speechTimeout = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
                self?.finish(reason: "voice_button_timeout")
            }
        case 0x08:
            guard capabilitiesReceived, !microphoneOpenSent, let transmit else { return }
            microphoneRequests += 1
            microphoneOpenSent = true
            peripheral.writeValue(Self.microphoneOpen, for: transmit, type: .withResponse)
            announce("atvv_test_microphone_open=acknowledged")
        case 0x04:
            guard capabilitiesReceived else { return }
            streamStarts += 1
        case 0x0A:
            guard capabilitiesReceived else { return }
            syncPackets += 1
        case 0x00:
            guard capabilitiesReceived, streamStarts > 0 || audioFrames > 0 else { return }
            finish(reason: "remote_stream_ended")
        default:
            break
        }
    }

    private func finish(reason: String) {
        guard !completed else { return }
        setupTimeout?.invalidate()
        speechTimeout?.invalidate()
        if let peripheral, peripheral.state != .disconnected { central.cancelPeripheralConnection(peripheral) }
        let receivedAudio = audioFrames > 0
        let opcodes = controlOpcodes.sorted().map { String(format: "%02X", $0) }.joined(separator: ",")
        announce("atvv_test_stats control_packets=\(controlPackets) control_opcodes=\(opcodes.isEmpty ? "none" : opcodes) microphone_requests=\(microphoneRequests) stream_starts=\(streamStarts) sync_packets=\(syncPackets) audio_frames=\(audioFrames) audio_bytes=\(audioBytes) payload_persisted=false")
        announce("atvv_test_result=\(receivedAudio ? "audio_transport_confirmed" : "no_audio_frames")")
        announce("atvv_test_finished=\(reason)")
        exitCode = receivedAudio ? 0 : 2
        completed = true
    }

    private func announce(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }
}

func runATVVVoiceFrameProbe() -> Int32 {
    ATVVVoiceFrameProbe().run()
}
