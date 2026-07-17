import AppKit

final class SettingsWindowController: NSWindowController {
    private let store: ConfigurationStore
    private let onConfigurationChange: () -> Void
    private let mappingsStack = NSStackView()
    private let serialLabel = NSTextField(labelWithString: "")

    init(store: ConfigurationStore, onConfigurationChange: @escaping () -> Void) {
        self.store = store
        self.onConfigurationChange = onConfigurationChange

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 475),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "小米遥控器按键映射"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        serialLabel.stringValue = "绑定序列号：\(store.configuration.boundSerial ?? "首次连接时自动绑定")"
        rebuildMappings()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "目标设备：小米蓝牙遥控器 2 Pro")
        title.font = .boldSystemFont(ofSize: 14)
        let deviceDetail = NSTextField(labelWithString: "VID 10007 / PID 12984 · 共享/独占模式自动选择")
        deviceDetail.textColor = .secondaryLabelColor
        serialLabel.textColor = .secondaryLabelColor

        mappingsStack.orientation = .vertical
        mappingsStack.alignment = .leading
        mappingsStack.spacing = 9

        let resetMappings = NSButton(title: "恢复默认映射", target: self, action: #selector(restoreDefaults))
        let clearSerial = NSButton(title: "解除序列号绑定", target: self, action: #selector(clearSerialBinding))
        let buttons = NSStackView(views: [resetMappings, clearSerial])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let note = NSTextField(wrappingLabelWithString: "修改后立即保存，并安全释放按住的 Fn、刷新抑制映射、重新打开设备。选择“保持原按键”时不会屏蔽该键。Power 的默认动作是系统事件重放，并非字节级透传。")
        note.textColor = .secondaryLabelColor

        let root = NSStackView(views: [title, deviceDetail, serialLabel, mappingsStack, note, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            note.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
        refresh()
    }

    private func rebuildMappings() {
        mappingsStack.arrangedSubviews.forEach { view in
            mappingsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for mapping in store.configuration.mappings {
            let label = NSTextField(
                labelWithString: "\(mapping.keyName)（\(mapping.sourceCodeName)）  [\(mapping.usage)]"
            )
            label.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: RemoteAction.allCases.map(\.displayName))
            popup.selectItem(at: RemoteAction.allCases.firstIndex(of: mapping.action) ?? 0)
            popup.identifier = NSUserInterfaceItemIdentifier(mapping.usage.description)
            popup.target = self
            popup.action = #selector(mappingChanged(_:))
            popup.widthAnchor.constraint(equalToConstant: 260).isActive = true
            let row = NSStackView(views: [label, popup])
            row.orientation = .horizontal
            row.spacing = 16
            mappingsStack.addArrangedSubview(row)
        }
    }

    @objc private func mappingChanged(_ sender: NSPopUpButton) {
        guard let identifier = sender.identifier?.rawValue,
              let mapping = store.configuration.mappings.first(where: { $0.usage.description == identifier }),
              RemoteAction.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        do {
            try store.setAction(RemoteAction.allCases[sender.indexOfSelectedItem], for: mapping.usage)
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

    @objc private func clearSerialBinding() {
        do {
            try store.clearSerial()
            refresh()
            onConfigurationChange()
        } catch {
            presentError(error)
        }
    }
}
