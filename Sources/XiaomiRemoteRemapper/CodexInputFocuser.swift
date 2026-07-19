import AppKit
import ApplicationServices

final class CodexInputFocuser {
    private static let bundleIdentifier = "com.openai.codex"
    private static let escapeKeyCode: CGKeyCode = 53
    private let eventSource = CGEventSource(stateID: .combinedSessionState)
    private var requestID = 0

    func activateAndFocus(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            self?.activateOnMain(completion: completion)
        }
    }

    private func activateOnMain(completion: ((Bool) -> Void)?) {
        requestID += 1
        let currentRequest = requestID

        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.bundleIdentifier
        ).first {
            running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            dispatchComposerFocus(request: currentRequest, delay: 0.20, completion: completion)
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
            AppLogger.shared.log("codex_application_not_found bundle=\(Self.bundleIdentifier)")
            completion?(false)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] application, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    AppLogger.shared.log("codex_activation_failed error=\(error)")
                    completion?(false)
                    return
                }
                guard let application else {
                    AppLogger.shared.log("codex_activation_failed reason=no_running_application")
                    completion?(false)
                    return
                }
                application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                self.dispatchComposerFocus(request: currentRequest, delay: 0.45, completion: completion)
            }
        }
    }

    private func dispatchComposerFocus(
        request: Int,
        delay: TimeInterval,
        completion: ((Bool) -> Void)?
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, request == self.requestID else { return }
            let succeeded = self.postEscapeKey()
            AppLogger.shared.log("codex_input_focus success=\(succeeded) strategy=codex_escape_command")
            completion?(succeeded)
        }
    }

    private func postEscapeKey() -> Bool {
        guard let down = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: Self.escapeKeyCode,
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: eventSource,
            virtualKey: Self.escapeKeyCode,
            keyDown: false
        ) else { return false }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
