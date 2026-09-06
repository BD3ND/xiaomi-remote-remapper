import AppKit
import ApplicationServices

final class EventEmitter {
    private let source = CGEventSource(stateID: .combinedSessionState)
    private let codexInputFocuser = CodexInputFocuser()
    private var fnIsDown = false
    private var deleteIsDown = false
    private var deleteRepeatTimer: DispatchSourceTimer?

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
        case .tab:
            postKey(keyCode: 48, isDown: isDown)
        case .escape:
            postKey(keyCode: 53, isDown: isDown)
        case .pageUp:
            postKey(keyCode: 116, isDown: isDown)
        case .pageDown:
            postKey(keyCode: 121, isDown: isDown)
        case .space:
            postKey(keyCode: 49, isDown: isDown)
        case .returnKey:
            postKey(keyCode: 36, isDown: isDown)
        case .missionControl:
            if isDown { postSystemShortcut(.missionControl) }
        case .showDesktop:
            if isDown { postSystemShortcut(.showDesktop) }
        case .spotlight:
            if isDown { postSystemShortcut(.spotlight) }
        case .playPause:
            postSystemDefined(keyType: 16, isDown: isDown)
        case .mute:
            postSystemDefined(keyType: 7, isDown: isDown)
        case .delete:
            postDelete(isDown: isDown)
        case .fnModifier:
            postFn(isDown: isDown)
        case .activateCodex:
            if isDown { codexInputFocuser.activateAndFocus() }
        case .power:
            postSystemDefined(keyType: 6, isDown: isDown)
        case .logOnly:
            break
        }
    }

    func releaseHeldInputs() {
        stopDeleteRepeat(postKeyUp: true)
        if fnIsDown { postFn(isDown: false) }
    }

    /// BLE remotes such as C2-RC-LITE only report a press notification and
    /// provide no reliable release event. Their Fn action therefore uses an
    /// explicit latch: press once to hold Fn, press again to release it.
    func toggleFnModifier() {
        postFn(isDown: !fnIsDown)
    }

    private func postDelete(isDown: Bool) {
        if isDown {
            guard !deleteIsDown else { return }
            deleteIsDown = true
            postKey(keyCode: 51, isDown: true)

            let timer = DispatchSource.makeTimerSource(queue: .main)
            let delay = max(NSEvent.keyRepeatDelay, 0.1)
            let interval = max(NSEvent.keyRepeatInterval, 0.02)
            timer.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in
                guard let self, self.deleteIsDown else { return }
                self.postKey(keyCode: 51, isDown: true, isRepeat: true)
            }
            deleteRepeatTimer = timer
            timer.resume()
        } else {
            stopDeleteRepeat(postKeyUp: true)
        }
    }

    private func stopDeleteRepeat(postKeyUp: Bool) {
        deleteRepeatTimer?.setEventHandler {}
        deleteRepeatTimer?.cancel()
        deleteRepeatTimer = nil
        guard deleteIsDown else { return }
        deleteIsDown = false
        if postKeyUp { postKey(keyCode: 51, isDown: false) }
    }

    private func postKey(
        keyCode: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags = [],
        isRepeat: Bool = false
    ) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else {
            AppLogger.shared.log("event_create_failed keyCode=\(keyCode)")
            return
        }
        event.flags = flags
        if isRepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
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

    private func postSystemShortcut(_ shortcut: SystemShortcutResolver.Shortcut) {
        let resolution = SystemShortcutResolver.resolve(shortcut)
        AppLogger.shared.log(
            "system_shortcut action=\(shortcut) \(resolution.diagnosticDescription)"
        )
        guard resolution.isEnabled else {
            AppLogger.shared.log("system_shortcut_skipped action=\(shortcut) reason=disabled")
            return
        }
        postShortcut(keyCode: resolution.keyCode, flags: resolution.flags)
    }

    // 原始 Power 报告被设备精确抑制后，系统不会再收到它。这里重放
    // macOS 的 NX_SYSDEFINED/NX_POWER_KEY，不声称是字节级硬件透传。
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
