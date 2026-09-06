import AppKit

final class MainWindowController: NSWindowController {
    private let store: ConfigurationStore
    private let requestInputPermission: () -> Void
    private let requestAccessibilityPermission: () -> Void
    private let openInputSettings: () -> Void
    private let openAccessibilitySettings: () -> Void
    private let showMappings: () -> Void
    private let reconnect: () -> Void
    private let openLog: () -> Void
    private let setLoginItem: (Bool) -> Void
    private let selectDevice: (RemoteDeviceDescriptor) -> Void
    private let completeOnboarding: () -> Void

    private let statusIcon = NSImageView()
    private let connectionLabel = NSTextField(labelWithString: "正在检查连接…")
    private let inputStatusLabel = NSTextField(labelWithString: "检查中")
    private let accessibilityStatusLabel = NSTextField(labelWithString: "检查中")
    private let inputDetailLabel = NSTextField(wrappingLabelWithString: "用于读取遥控器原始 HID 按键。")
    private let accessibilityDetailLabel = NSTextField(wrappingLabelWithString: "用于发送 Delete、Fn、系统事件并聚焦 Codex 输入框。")
    private let mappingStack = NSStackView()
    private let lastKeyLabel = NSTextField(wrappingLabelWithString: "最近按键：暂无")
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时自动启动", target: nil, action: nil)
    private let devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var displayedDevices: [RemoteDeviceDescriptor?] = []
    private var displayedDeviceSignature: [String] = []
    private var inputRequestButton: NSButton!
    private var accessibilityRequestButton: NSButton!

    init(
        store: ConfigurationStore,
        requestInputPermission: @escaping () -> Void,
        requestAccessibilityPermission: @escaping () -> Void,
        openInputSettings: @escaping () -> Void,
        openAccessibilitySettings: @escaping () -> Void,
        showMappings: @escaping () -> Void,
        reconnect: @escaping () -> Void,
        openLog: @escaping () -> Void,
        setLoginItem: @escaping (Bool) -> Void,
        selectDevice: @escaping (RemoteDeviceDescriptor) -> Void,
        completeOnboarding: @escaping () -> Void
    ) {
        self.store = store
        self.requestInputPermission = requestInputPermission
        self.requestAccessibilityPermission = requestAccessibilityPermission
        self.openInputSettings = openInputSettings
        self.openAccessibilitySettings = openAccessibilitySettings
        self.showMappings = showMappings
        self.reconnect = reconnect
        self.openLog = openLog
        self.setLoginItem = setLoginItem
        self.selectDevice = selectDevice
        self.completeOnboarding = completeOnboarding

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "蓝牙遥控器"
        window.minSize = NSSize(width: 650, height: 610)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    func refresh(
        connection: ConnectionState,
        inputPermissionName: String,
        inputGranted: Bool,
        inputRequired: Bool,
        accessibilityGranted: Bool,
        loginEnabled: Bool,
        lastKey: String?,
        availableDevices: [RemoteDeviceDescriptor],
        selectedDeviceID: String?
    ) {
        connectionLabel.stringValue = connection.displayName
        let connected: Bool
        if case .connected = connection { connected = true } else { connected = false }
        let ready = connected && (!inputRequired || inputGranted) && accessibilityGranted
        statusIcon.contentTintColor = ready ? .systemGreen : .systemOrange
        statusIcon.image = NSImage(
            systemSymbolName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            accessibilityDescription: ready ? "运行正常" : "需要设置"
        )

        if inputRequired {
            updatePermissionLabel(inputStatusLabel, granted: inputGranted, fallback: inputPermissionName)
        } else {
            inputStatusLabel.stringValue = "● 不需要"
            inputStatusLabel.textColor = .systemGreen
        }
        updatePermissionLabel(
            accessibilityStatusLabel,
            granted: accessibilityGranted,
            fallback: "未授权"
        )
        inputDetailLabel.stringValue = inputRequired
            ? (inputGranted
                ? "已允许读取遥控器原始 HID 输入。"
                : "用于读取遥控器原始 HID 按键；授权后可能需要重新打开程序。")
            : "C2-RC-LITE 使用应用内 BLE 通道读取，不需要输入监控。"
        accessibilityDetailLabel.stringValue = accessibilityGranted
            ? "已允许发送映射按键和聚焦 Codex 输入框。"
            : "用于发送 Delete、Fn、系统事件并聚焦 Codex 输入框。"
        inputRequestButton.title = inputRequired ? (inputGranted ? "已完成" : "请求权限") : "不需要"
        inputRequestButton.isEnabled = inputRequired && !inputGranted
        accessibilityRequestButton.title = accessibilityGranted ? "已完成" : "请求权限"
        accessibilityRequestButton.isEnabled = !accessibilityGranted
        loginCheckbox.state = loginEnabled ? .on : .off
        lastKeyLabel.stringValue = "最近按键：\(lastKey ?? "暂无")"
        refreshDevicePopup(devices: availableDevices, selectedDeviceID: selectedDeviceID)
        rebuildMappings()
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        // Let NSWindow draw its adaptive background; a cached CGColor does not
        // follow system appearance changes alongside the semantic text colors.

        let title = NSTextField(labelWithString: "蓝牙遥控器按键映射")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        connectionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        connectionLabel.lineBreakMode = .byTruncatingTail
        connectionLabel.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [title, connectionLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4

        statusIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [statusIcon, heading])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let deviceTitle = NSTextField(labelWithString: "选择遥控器")
        deviceTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        deviceTitle.widthAnchor.constraint(equalToConstant: 90).isActive = true
        devicePopup.target = self
        devicePopup.action = #selector(deviceSelectionChanged)
        devicePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        let deviceSpacer = NSView()
        deviceSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let deviceRow = NSStackView(views: [deviceTitle, devicePopup, deviceSpacer])
        deviceRow.orientation = .horizontal
        deviceRow.alignment = .centerY
        deviceRow.spacing = 12

        let inputCard = permissionCard(
            symbol: "keyboard",
            title: "输入监控",
            statusLabel: inputStatusLabel,
            detailLabel: inputDetailLabel,
            requestAction: #selector(requestInput),
            settingsAction: #selector(openInputPrivacySettings)
        )
        let accessibilityCard = permissionCard(
            symbol: "accessibility",
            title: "辅助功能",
            statusLabel: accessibilityStatusLabel,
            detailLabel: accessibilityDetailLabel,
            requestAction: #selector(requestAccessibility),
            settingsAction: #selector(openAccessibilityPrivacySettings)
        )

        let mappingTitle = NSTextField(labelWithString: "按键映射")
        mappingTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        let editMappings = NSButton(title: "配置按键…", target: self, action: #selector(editMappings))
        editMappings.bezelStyle = .rounded
        editMappings.keyEquivalent = ","
        editMappings.keyEquivalentModifierMask = [.command]
        let mappingHeaderSpacer = NSView()
        mappingHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let mappingHeader = NSStackView(views: [mappingTitle, mappingHeaderSpacer, editMappings])
        mappingHeader.orientation = .horizontal
        mappingHeader.alignment = .centerY

        mappingStack.orientation = .vertical
        mappingStack.alignment = .leading
        mappingStack.spacing = 5
        let mappingBox = NSBox()
        mappingBox.boxType = .custom
        mappingBox.borderWidth = 1
        mappingBox.cornerRadius = 10
        mappingBox.borderColor = .separatorColor
        mappingBox.fillColor = .clear
        mappingBox.contentViewMargins = NSSize(width: 12, height: 10)
        mappingBox.contentView = mappingStack

        lastKeyLabel.textColor = .secondaryLabelColor
        lastKeyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        lastKeyLabel.lineBreakMode = .byTruncatingMiddle

        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginItemChanged)
        let reconnectButton = NSButton(title: "重新连接", target: self, action: #selector(reconnectDevice))
        let logButton = NSButton(title: "打开日志", target: self, action: #selector(showLog))
        let utilitySpacer = NSView()
        utilitySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let utilities = NSStackView(views: [loginCheckbox, utilitySpacer, reconnectButton, logButton])
        utilities.orientation = .horizontal
        utilities.alignment = .centerY
        utilities.spacing = 10

        let footerNote = NSTextField(wrappingLabelWithString: "只选择要映射的遥控器，不要选择日常键盘或鼠标。关闭窗口后程序继续在菜单栏运行。")
        footerNote.textColor = .secondaryLabelColor
        footerNote.font = .systemFont(ofSize: 11)
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "未知"
        let versionLabel = NSTextField(labelWithString: "版本 \(version)")
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        let finishButton = NSButton(title: "完成设置并在后台运行", target: self, action: #selector(finishSetup))
        finishButton.keyEquivalent = "\r"
        finishButton.bezelStyle = .rounded
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footerActions = NSStackView(views: [footerNote, footerSpacer, versionLabel, finishButton])
        footerActions.orientation = .horizontal
        footerActions.alignment = .centerY
        footerActions.spacing = 12
        footerNote.widthAnchor.constraint(lessThanOrEqualToConstant: 350).isActive = true

        let root = NSStackView(views: [
            header,
            separator(),
            deviceRow,
            inputCard,
            accessibilityCard,
            mappingHeader,
            mappingBox,
            lastKeyLabel,
            utilities,
            separator(),
            footerActions
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            deviceRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            inputCard.widthAnchor.constraint(equalTo: root.widthAnchor),
            accessibilityCard.widthAnchor.constraint(equalTo: root.widthAnchor),
            mappingHeader.widthAnchor.constraint(equalTo: root.widthAnchor),
            mappingBox.widthAnchor.constraint(equalTo: root.widthAnchor),
            lastKeyLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            utilities.widthAnchor.constraint(equalTo: root.widthAnchor),
            footerActions.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        rebuildMappings()
    }

    private func refreshDevicePopup(
        devices: [RemoteDeviceDescriptor],
        selectedDeviceID: String?
    ) {
        var choices: [(title: String, device: RemoteDeviceDescriptor?)] = []
        let selectedDevice = selectedDeviceID.flatMap { selectedID in
            devices.first(where: { $0.id == selectedID })
        }
        if let selectedDeviceID, selectedDevice == nil {
            let name = store.configuration.selectedDeviceName ?? "已选择的遥控器"
            choices.append((
                title: "\(name) · \(selectedDeviceID.suffix(6))（已选择，当前离线）",
                device: nil
            ))
        }
        choices.append(contentsOf: devices.map { ($0.selectionLabel, Optional($0)) })

        let signature = choices.map { choice in
            "\(choice.device?.id ?? "offline")|\(choice.title)"
        }
        guard signature != displayedDeviceSignature else { return }
        displayedDeviceSignature = signature
        displayedDevices = choices.map(\.device)
        devicePopup.removeAllItems()
        guard !choices.isEmpty else {
            devicePopup.addItem(withTitle: "未检测到支持的遥控器")
            devicePopup.isEnabled = false
            return
        }

        devicePopup.addItems(withTitles: choices.map(\.title))
        if selectedDeviceID != nil,
           let index = choices.firstIndex(where: { $0.device?.id == selectedDeviceID || $0.device == nil }) {
            devicePopup.selectItem(at: index)
        } else {
            devicePopup.select(nil)
        }
        devicePopup.isEnabled = choices.contains(where: { $0.device != nil })
    }

    @objc private func deviceSelectionChanged() {
        guard displayedDevices.indices.contains(devicePopup.indexOfSelectedItem),
              let device = displayedDevices[devicePopup.indexOfSelectedItem] else { return }
        selectDevice(device)
    }

    private func permissionCard(
        symbol: String,
        title: String,
        statusLabel: NSTextField,
        detailLabel: NSTextField,
        requestAction: Selector,
        settingsAction: Selector
    ) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let titleRow = NSStackView(views: [titleLabel, statusLabel])
        titleRow.orientation = .horizontal
        titleRow.spacing = 10

        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        let text = NSStackView(views: [titleRow, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let requestButton = NSButton(title: "请求权限", target: self, action: requestAction)
        let settingsButton = NSButton(title: "打开系统设置", target: self, action: settingsAction)
        requestButton.bezelStyle = .rounded
        settingsButton.bezelStyle = .rounded
        if title == "输入监控" {
            inputRequestButton = requestButton
        } else if title == "辅助功能" {
            accessibilityRequestButton = requestButton
        }
        let buttons = NSStackView(views: [requestButton, settingsButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, text, spacer, buttons])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let cardContent = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            row.topAnchor.constraint(equalTo: cardContent.topAnchor),
            row.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor)
        ])

        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.fillColor = .clear
        box.contentViewMargins = .zero
        box.contentView = cardContent
        box.heightAnchor.constraint(equalToConstant: 64).isActive = true
        box.setContentHuggingPriority(.required, for: .vertical)
        box.setContentCompressionResistancePriority(.required, for: .vertical)
        return box
    }

    private func rebuildMappings() {
        mappingStack.arrangedSubviews.forEach {
            mappingStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if store.mappings.isEmpty {
            let empty = NSTextField(labelWithString: "尚未识别按键，请打开“配置按键…”开始学习。")
            empty.textColor = .secondaryLabelColor
            mappingStack.addArrangedSubview(empty)
            return
        }
        for mapping in store.mappings {
            let key = NSTextField(labelWithString: mapping.keyName)
            key.font = .systemFont(ofSize: 12, weight: .medium)
            key.widthAnchor.constraint(equalToConstant: 90).isActive = true
            let usage = NSTextField(labelWithString: mapping.technicalDescription)
            usage.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            usage.textColor = .secondaryLabelColor
            usage.widthAnchor.constraint(equalToConstant: 145).isActive = true
            let arrow = NSTextField(labelWithString: "→")
            arrow.textColor = .secondaryLabelColor
            let action = NSTextField(labelWithString: mapping.action.displayName)
            action.textColor = .secondaryLabelColor
            let row = NSStackView(views: [key, usage, arrow, action])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            mappingStack.addArrangedSubview(row)
        }
    }

    private func updatePermissionLabel(_ label: NSTextField, granted: Bool, fallback: String) {
        label.stringValue = granted ? "● 已授权" : "● \(fallback)"
        label.textColor = granted ? .systemGreen : .systemOrange
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    @objc private func requestInput() { requestInputPermission() }
    @objc private func requestAccessibility() { requestAccessibilityPermission() }
    @objc private func openInputPrivacySettings() { openInputSettings() }
    @objc private func openAccessibilityPrivacySettings() { openAccessibilitySettings() }
    @objc private func editMappings() {
        AppLogger.shared.log("settings_button_pressed")
        showMappings()
    }
    @objc private func reconnectDevice() { reconnect() }
    @objc private func showLog() { openLog() }
    @objc private func loginItemChanged() { setLoginItem(loginCheckbox.state == .on) }
    @objc private func finishSetup() {
        completeOnboarding()
        close()
    }
}
