import AppKit
import ApplicationServices

final class EventEmitter {
    private let source = CGEventSource(stateID: .combinedSessionState)
    private let codexInputFocuser = CodexInputFocuser()
    private var fnIsDown = false

    var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func emit(_ action: RemoteAction, isDown: Bool) {
        switch action {
        case .passThrough:
            break
        case .delete:
            postKey(keyCode: 51, isDown: isDown)
        case .fnModifier:
            postFn(isDown: isDown)
        case .showDesktop:
            if isDown { postShortcut(keyCode: 103, flags: []) }
        case .activateCodex:
            if isDown { codexInputFocuser.activateAndFocus() }
        case .spotlight:
            if isDown { postShortcut(keyCode: 49, flags: .maskCommand) }
        case .power:
            postSystemDefined(keyType: 6, isDown: isDown)
        case .logOnly:
            break
        }
    }

    func releaseHeldModifiers() {
        if fnIsDown { postFn(isDown: false) }
    }

    private func postKey(keyCode: CGKeyCode, isDown: Bool, flags: CGEventFlags = []) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
            AppLogger.shared.log("event_create_failed keyCode=\(keyCode)")
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postFn(isDown: Bool) {
        fnIsDown = isDown
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: isDown) else {
            AppLogger.shared.log("fn_event_create_failed")
            return
        }
        event.type = .flagsChanged
        event.flags = isDown ? .maskSecondaryFn : []
        event.post(tap: .cghidEventTap)
    }

    private func postShortcut(keyCode: CGKeyCode, flags: CGEventFlags) {
        postKey(keyCode: keyCode, isDown: true, flags: flags)
        postKey(keyCode: keyCode, isDown: false, flags: flags)
    }

    // IOHID 独占后系统收不到遥控器的 Power 报告。这里重放 macOS 的
    // NX_SYSDEFINED/NX_POWER_KEY 事件，不声称是字节级硬件透传。
    private func postSystemDefined(keyType: Int, isDown: Bool) {
        let keyState = isDown ? 0x0A00 : 0x0B00
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (keyType << 16) | keyState,
            data2: -1
        )?.cgEvent else {
            AppLogger.shared.log("system_event_create_failed keyType=\(keyType)")
            return
        }
        event.post(tap: .cghidEventTap)
    }
}
