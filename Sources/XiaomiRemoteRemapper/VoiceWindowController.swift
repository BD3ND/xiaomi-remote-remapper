import AppKit

final class VoiceWindowController: NSWindowController {
    private let service: RemoteVoiceService
    private let enabled = NSButton(checkboxWithTitle: "启用 2 Pro 遥控器麦克风", target: nil, action: nil)
    private let devices = NSPopUpButton()
    private let automatic = NSButton(checkboxWithTitle: "自动切换麦克风（松键后恢复原麦克风）", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let level = NSLevelIndicator()
    private var outputs: [VoiceOutputDevice] = []
    private var timer: Timer?

    init(service: RemoteVoiceService) {
        self.service = service
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 570,height: 390), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.title = "遥控器麦克风"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        enabled.target = self; enabled.action = #selector(change)
        automatic.target = self; automatic.action = #selector(changeAutomatic)
        devices.target = self; devices.action = #selector(changeOutput)
        level.minValue = 0; level.maxValue = 1
        level.levelIndicatorStyle = .continuousCapacity
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        let help = NSTextField(wrappingLabelWithString: "自动模式：豆包请选择「自动检测」，系统先选好电脑麦克风。遥控器按下时临时切换至虚拟麦克风，松键后恢复；普通键盘 Fn 不切换。关闭自动模式时，豆包需手动选择下方设备。声音仅在内存中转发。")
        help.textColor = .secondaryLabelColor
        let install = NSButton(title: "安装 BlackHole 2ch…", target: self, action: #selector(installDriver))
        let reload = NSButton(title: "刷新设备", target: self, action: #selector(refreshDevices))
        let reconnect = NSButton(title: "重新连接语音", target: self, action: #selector(reconnectVoice))
        let actions = NSStackView(views: [install,reload,reconnect])
        actions.spacing = 10
        let root = NSStackView(views: [enabled,automatic,help,NSTextField(labelWithString: "输出至虚拟麦克风："),devices,statusLabel,level,countLabel,actions])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor,constant: 20),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor,constant: -20),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor,constant: 20),
            help.widthAnchor.constraint(equalTo: root.widthAnchor),
            devices.widthAnchor.constraint(equalTo: root.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            level.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        refreshDevices()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25,repeats: true) { [weak self] _ in self?.refresh() }
    }
    required init?(coder: NSCoder) { nil }
    deinit { timer?.invalidate() }
    func present() { refreshDevices(); window?.center(); showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    private func refresh() {
        enabled.state = UserDefaults.standard.bool(forKey: RemoteVoiceService.enabledKey) ? .on : .off
        automatic.state = UserDefaults.standard.bool(forKey: VoiceInputRouter.automaticKey) ? .on : .off
        statusLabel.stringValue = service.status
        countLabel.stringValue = "遥控器音频：\(service.frames) 包 / \(service.bytes) 字节"
        level.doubleValue = Double(service.peak)
    }
    @objc private func refreshDevices() {
        outputs = RemoteVoiceOutput.devices()
        devices.removeAllItems()
        if outputs.isEmpty { devices.addItem(withTitle: "尚未安装虚拟麦克风"); devices.isEnabled = false }
        else {
            devices.isEnabled = true
            devices.addItems(withTitles: outputs.map(\.name))
            if let index = outputs.firstIndex(where: { $0.uid == UserDefaults.standard.string(forKey: RemoteVoiceService.outputKey) }) { devices.selectItem(at: index) }
        }
        refresh()
    }
    @objc private func change() {
        if enabled.state == .on, outputs.isEmpty {
            enabled.state = .off
            let alert = NSAlert(); alert.messageText = "请先安装 BlackHole 2ch"
            alert.informativeText = "安装后刷新设备，再开启遥控器麦克风。"; alert.runModal(); return
        }
        if outputs.indices.contains(devices.indexOfSelectedItem) {
            UserDefaults.standard.set(outputs[devices.indexOfSelectedItem].uid,forKey: RemoteVoiceService.outputKey)
        }
        UserDefaults.standard.set(enabled.state == .on,forKey: RemoteVoiceService.enabledKey)
        service.restart(); refresh()
    }
    @objc private func changeOutput() {
        guard outputs.indices.contains(devices.indexOfSelectedItem) else { return }
        UserDefaults.standard.set(outputs[devices.indexOfSelectedItem].uid,forKey: RemoteVoiceService.outputKey)
        service.restart()
    }
    @objc private func reconnectVoice() { service.restart(); refresh() }
    @objc private func changeAutomatic() {
        UserDefaults.standard.set(automatic.state == .on, forKey: VoiceInputRouter.automaticKey)
        service.restart(); refresh()
    }
    @objc private func installDriver() {
        NSWorkspace.shared.open(URL(string: "https://existential.audio/blackhole/")!)
    }
}
