import CoreBluetooth
import Foundation

final class RemoteVoiceService: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let enabledKey = "remoteVoiceEnabled"
    static let outputKey = "remoteVoiceOutputUID"
    private let store: ConfigurationStore
    private let output = RemoteVoiceOutput()
    private let inputRouter = VoiceInputRouter()

    func remoteFnChanged(_ down: Bool) -> Bool {
        guard UserDefaults.standard.bool(forKey: VoiceInputRouter.automaticKey), running, session.ready else { return false }
        if !down { inputRouter.end(); return false }
        let changed = inputRouter.begin(uid: UserDefaults.standard.string(forKey: Self.outputKey) ?? "")
        if !changed { update("无法自动切换输入：请先选择正常的电脑麦克风") }
        return changed
    }
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var subscriptions = Set<CBUUID>()
    private var session = ATVVAudioSession()
    private var timeout: Timer?
    private var recovery: DispatchWorkItem?
    private var capsSent = false
    private var modelConfirmed = false
    private var running = false
    private var generation = 0
    private var lastAudioAt = Date.distantPast
    private var watchdog: Timer?
    private(set) var status = "未启用"
    private(set) var frames = 0
    private(set) var bytes = 0
    private(set) var peak: Float = 0
    var onChange: (() -> Void)?
    private static let service = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private static let transmit = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    private static let audio = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    private static let control = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")

    init(store: ConfigurationStore) { self.store = store }

    func restart() { stop(); start() }
    func start() {
        inputRouter.restore()
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { update("未启用"); return }
        guard let id = store.configuration.selectedDeviceID, UUID(uuidString: id) != nil else {
            update("请选择已配对的 2 Pro HID 遥控器"); return
        }
        guard let uid = UserDefaults.standard.string(forKey: Self.outputKey),
              RemoteVoiceOutput.devices().contains(where: { $0.uid == uid }) else {
            update("请选择已安装的虚拟麦克风"); return
        }
        running = true
        update("正在连接遥控器麦克风…")
        central = CBCentralManager(delegate: self, queue: .main)
        let token = generation
        timeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.retry("语音连接超时，等待重连")
        }
    }

    func stop() {
        inputRouter.restore()
        running = false
        generation += 1
        recovery?.cancel(); recovery = nil
        timeout?.invalidate(); timeout = nil
        watchdog?.invalidate(); watchdog = nil
        output.stop()
        peripheral?.delegate = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.delegate = nil
        central = nil; peripheral = nil; tx = nil
        subscriptions.removeAll()
        capsSent = false; modelConfirmed = false
        session = ATVVAudioSession()
        peak = 0
        update("已停止")
    }

    private func update(_ value: String) { status = value; onChange?() }
    private func retry(_ message: String) {
        guard running else { return }
        stop()
        update(message)
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.start()
        }
        recovery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        guard central.state == .poweredOn else {
            if central.state == .unauthorized { update("请在系统设置中允许蓝牙访问") }
            else { update("等待蓝牙开启") }
            return
        }
        guard let id = store.configuration.selectedDeviceID.flatMap(UUID.init(uuidString:)),
              let remote = central.retrievePeripherals(withIdentifiers: [id]).first else {
            retry("所选遥控器暂不可用"); return
        }
        peripheral = remote
        central.connect(remote)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central else { return }
        peripheral.delegate = self
        peripheral.discoverServices([Self.service, CBUUID(string: "180A")])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.central === central else { return }
        retry("遥控器未连接，等待重连")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.central === central else { return }
        retry("遥控器已离线，等待重连")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, let services = peripheral.services,
              services.contains(where: { $0.uuid == Self.service }) else {
            stop(); update("此遥控器没有标准语音服务"); return
        }
        for service in services {
            peripheral.discoverCharacteristics(service.uuid == Self.service ? [Self.transmit, Self.audio, Self.control] : [CBUUID(string: "2A24")], for: service)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, error == nil else { return }
        for c in service.characteristics ?? [] {
            if c.uuid == CBUUID(string: "2A24") { peripheral.readValue(for: c) }
            else if c.uuid == Self.transmit { tx = c }
            else if c.uuid == Self.audio || c.uuid == Self.control { peripheral.setNotifyValue(true, for: c) }
        }
        negotiate()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard error == nil, characteristic.isNotifying else { retry("语音订阅失败"); return }
        subscriptions.insert(characteristic.uuid)
        negotiate()
    }
    private func negotiate() {
        guard modelConfirmed, !capsSent, tx != nil, subscriptions.contains(Self.audio), subscriptions.contains(Self.control) else { return }
        capsSent = true
        write(Data([0x0A,1,0,0,3,3]))
    }
    private func write(_ data: Data) {
        guard let peripheral, let tx else { return }
        peripheral.writeValue(data, for: tx, type: tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if error != nil { retry("语音协商写入失败") }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, error == nil, let data = characteristic.value else { return }
        if characteristic.uuid == CBUUID(string: "2A24") {
            guard String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "RC003" else {
                stop(); update("语音暂仅支持已验证的 2 Pro（RC003）"); return
            }
            modelConfirmed = true; negotiate(); return
        }
        if characteristic.uuid == Self.control {
            if data.first == 8, session.ready, !session.streaming { write(Data([0x0C,0])); return }
            let wasStreaming = session.streaming
            _ = session.control(data)
            if data.first == 0x0B {
                guard session.ready else { stop(); update("遥控器未提供兼容的 16 kHz 语音"); return }
                timeout?.invalidate()
                update("已就绪 · 按住语音键说话")
                watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    guard let self, self.session.streaming, Date().timeIntervalSince(self.lastAudioAt) > 3 else { return }
                    self.write(Data([0x0D,self.session.sessionID]))
                    self.retry("语音流超时，正在重新连接")
                }
            }
            if !wasStreaming, session.streaming {
                do {
                    try output.start(uid: UserDefaults.standard.string(forKey: Self.outputKey) ?? "")
                    frames = 0; bytes = 0; peak = 0; lastAudioAt = Date()
                    update("正在接收遥控器语音")
                } catch { stop(); update(error.localizedDescription) }
            } else if wasStreaming, !session.streaming {
                output.drain()
                peak = 0
                update("本次收到 \(frames) 包 · 已松键停止")
                AppLogger.shared.log("remote_voice_finished frames=\(frames) bytes=\(bytes) audio_saved=false")
            }
        } else if characteristic.uuid == Self.audio, session.streaming {
            lastAudioAt = Date(); frames += 1; bytes += data.count
            let samples = session.audio(data)
            peak = samples.reduce(Float(0)) { max($0, abs(Float($1)) / 32768) }
            do { try output.append(samples) }
            catch { stop(); update(error.localizedDescription) }
        }
    }
}
