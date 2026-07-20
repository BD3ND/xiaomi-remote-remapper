import AppKit

final class SettingsWindowController: NSWindowController {
    private let store: ConfigurationStore
    private let onConfigurationChange: () -> Void
    private let onLearningChange: (Bool) -> Void
    private let mappingsStack = NSStackView()
    private let deviceLabel = NSTextField(labelWithString: "")
    private let learningButton = NSButton(title: "开始识别按键", target: nil, action: nil)
    private let learningStatus = NSTextField(wrappingLabelWithString: "点击“开始识别按键”，然后依次按下遥控器按键。")
    private let mappingsScrollView = NSScrollView()
    private var isLearning = false
    private var highlightedUsage: HIDUsage?

    init(
        store: ConfigurationStore,
        onConfigurationChange: @escaping () -> Void,
        onLearningChange: @escaping (Bool) -> Void
    ) {
        self.store = store
        self.onConfigurationChange = onConfigurationChange
        self.onLearningChange = onLearningChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "蓝牙遥控器按键映射"
        window.minSize = NSSize(width: 660, height: 560)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let name = store.configuration.selectedDeviceName ?? "尚未选择"
        let suffix = store.configuration.selectedDeviceID.map { String($0.suffix(6)) } ?? "—"
        deviceLabel.stringValue = "当前遥控器：\(name) · \(suffix)"
        rebuildMappings()
    }

    func present() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        AppLogger.shared.log("settings_window_presented")
    }

    func receiveInput(_ usage: HIDUsage, isDown: Bool) {
        guard isLearning, isDown, window?.isVisible == true else { return }
        do {
            let added = try store.learnUsage(usage)
            highlightedUsage = usage
            let mapping = store.mappings.first(where: { $0.usage == usage })
            learningStatus.stringValue = added
                ? "已识别 \(mapping?.keyName ?? usage.description)。请在右侧选择功能，然后继续按下一个键。"
                : "已定位 \(mapping?.keyName ?? usage.description)。可修改右侧功能，或继续按下一个键。"
            rebuildMappings()
            if added { onConfigurationChange() }
            AppLogger.shared.log("mapping_learning usage=\(usage) added=\(added)")
        } catch {
            presentError(error)
        }
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "蓝牙遥控器按键映射")
        title.font = .boldSystemFont(ofSize: 14)
        let deviceDetail = NSTextField(labelWithString: "选择蓝牙 HID 遥控器后，可逐键识别、命名并配置映射。")
        deviceDetail.textColor = .secondaryLabelColor
        deviceLabel.textColor = .secondaryLabelColor

        learningButton.target = self
        learningButton.action = #selector(toggleLearning)
        learningButton.bezelStyle = .rounded
        learningStatus.textColor = .secondaryLabelColor
        learningStatus.font = .systemFont(ofSize: 12)
        let learningControls = NSStackView(views: [learningButton, learningStatus])
        learningControls.orientation = .horizontal
        learningControls.alignment = .centerY
        learningControls.spacing = 12
        learningStatus.widthAnchor.constraint(equalToConstant: 480).isActive = true

        mappingsStack.orientation = .vertical
        mappingsStack.alignment = .leading
        mappingsStack.spacing = 9

        mappingsScrollView.hasVerticalScroller = true
        mappingsScrollView.autohidesScrollers = true
        mappingsScrollView.borderType = .bezelBorder
        mappingsScrollView.drawsBackground = false
        mappingsScrollView.documentView = mappingsStack
        mappingsScrollView.heightAnchor.constraint(equalToConstant: 320).isActive = true
        mappingsStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mappingsStack.leadingAnchor.constraint(equalTo: mappingsScrollView.contentView.leadingAnchor, constant: 8),
            mappingsStack.trailingAnchor.constraint(equalTo: mappingsScrollView.contentView.trailingAnchor, constant: -8),
            mappingsStack.topAnchor.constraint(equalTo: mappingsScrollView.contentView.topAnchor, constant: 8),
            mappingsStack.widthAnchor.constraint(equalTo: mappingsScrollView.contentView.widthAnchor, constant: -16),
            mappingsStack.bottomAnchor.constraint(greaterThanOrEqualTo: mappingsScrollView.contentView.bottomAnchor, constant: -8)
        ])

        let resetMappings = NSButton(title: "恢复默认映射", target: self, action: #selector(restoreDefaults))
        let buttons = NSStackView(views: [resetMappings])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let note = NSTextField(wrappingLabelWithString: "每只遥控器的键名和映射独立保存在本机。未知设备从空配置开始；新识别按键默认只记录日志。选择“保持原按键”时不会屏蔽该键。")
        note.textColor = .secondaryLabelColor

        let root = NSStackView(views: [title, deviceDetail, deviceLabel, learningControls, mappingsScrollView, note, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            mappingsScrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            note.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        refresh()
    }

    private func rebuildMappings() {
        mappingsStack.arrangedSubviews.forEach { view in
            mappingsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        var highlightedRow: NSView?
        if store.mappings.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "尚未识别按键。点击“开始识别按键”，然后按下遥控器上的第一个键。")
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            mappingsStack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: mappingsStack.widthAnchor).isActive = true
            return
        }
        for mapping in store.mappings {
            let nameField = NSTextField(string: mapping.keyName)
            nameField.identifier = NSUserInterfaceItemIdentifier(mapping.usage.description)
            nameField.delegate = self
            nameField.placeholderString = "按键名称"
            nameField.widthAnchor.constraint(equalToConstant: 150).isActive = true
            let technical = NSTextField(labelWithString: mapping.technicalDescription)
            technical.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            technical.textColor = .tertiaryLabelColor
            technical.widthAnchor.constraint(equalToConstant: 115).isActive = true
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: RemoteAction.allCases.map(\.displayName))
            popup.selectItem(at: RemoteAction.allCases.firstIndex(of: mapping.action) ?? 0)
            popup.identifier = NSUserInterfaceItemIdentifier(mapping.usage.description)
            popup.target = self
            popup.action = #selector(mappingChanged(_:))
            popup.widthAnchor.constraint(equalToConstant: 245).isActive = true
            let deleteButton = NSButton(title: "删除", target: self, action: #selector(deleteMapping(_:)))
            deleteButton.identifier = NSUserInterfaceItemIdentifier(mapping.usage.description)
            deleteButton.bezelStyle = .rounded
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [nameField, technical, popup, spacer, deleteButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 16
            if mapping.usage == highlightedUsage {
                nameField.textColor = .controlAccentColor
                nameField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                highlightedRow = row
            }
            mappingsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: mappingsStack.widthAnchor).isActive = true
        }
        if let highlightedRow {
            DispatchQueue.main.async {
                highlightedRow.scrollToVisible(highlightedRow.bounds)
            }
        }
    }

    @objc private func mappingChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.identifier?.rawValue,
              let mapping = store.mappings.first(where: { $0.usage.description == identifier }),
              RemoteAction.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        do {
            try store.setAction(RemoteAction.allCases[sender.indexOfSelectedItem], for: mapping.usage)
            highlightedUsage = mapping.usage
            learningStatus.stringValue = "已设置 \(mapping.keyName) → \(RemoteAction.allCases[sender.indexOfSelectedItem].displayName)。可继续按下一个键。"
            onConfigurationChange()
        } catch {
            presentError(error)
        }
    }

    @objc private func mappingNameChanged(_ sender: NSTextField) {
        guard let identifier = sender.identifier?.rawValue,
              let mapping = store.mappings.first(where: { $0.usage.description == identifier }) else { return }
        do {
            try store.renameMapping(for: mapping.usage, to: sender.stringValue)
            highlightedUsage = mapping.usage
            learningStatus.stringValue = "已将 \(mapping.usage) 命名为“\(sender.stringValue)”。"
            onConfigurationChange()
        } catch {
            presentError(error)
        }
    }

    @objc private func deleteMapping(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let mapping = store.mappings.first(where: { $0.usage.description == identifier }) else { return }
        do {
            try store.deleteMapping(for: mapping.usage)
            highlightedUsage = nil
            learningStatus.stringValue = "已删除“\(mapping.keyName)”。重新识别该按键可再次添加。"
            refresh()
            onConfigurationChange()
        } catch {
            presentError(error)
        }
    }

    @objc private func restoreDefaults() {
        do {
            try store.restoreDefaults()
            refresh()
            onConfigurationChange()
        } catch {
            presentError(error)
        }
    }

    @objc private func toggleLearning() {
        isLearning.toggle()
        onLearningChange(isLearning)
        learningButton.title = isLearning ? "停止识别" : "开始识别按键"
        learningButton.contentTintColor = isLearning ? .systemRed : nil
        learningStatus.stringValue = isLearning
            ? "正在等待当前遥控器按键…按下后会新增或定位对应行。"
            : "识别已停止。点击“开始识别按键”可继续。"
    }

}

extension SettingsWindowController: NSWindowDelegate, NSTextFieldDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        mappingNameChanged(field)
    }

    func windowWillClose(_ notification: Notification) {
        isLearning = false
        onLearningChange(false)
        learningButton.title = "开始识别按键"
        learningButton.contentTintColor = nil
        learningStatus.stringValue = "点击“开始识别按键”，然后依次按下遥控器按键。"
    }
}
