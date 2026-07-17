import AppKit
import ApplicationServices

final class CodexInputFocuser {
    private static let bundleIdentifier = "com.openai.codex"
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
            dispatchComposerClick(
                application: running,
                request: currentRequest,
                delay: 0.20,
                completion: completion
            )
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
                self.dispatchComposerClick(
                    application: application,
                    request: currentRequest,
                    delay: 0.45,
                    completion: completion
                )
            }
        }
    }

    private func dispatchComposerClick(
        application: NSRunningApplication,
        request: Int,
        delay: TimeInterval,
        completion: ((Bool) -> Void)?
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, request == self.requestID else { return }
            guard let window = self.primaryWindowBounds(processIdentifier: application.processIdentifier) else {
                AppLogger.shared.log("codex_input_focus success=false reason=window_not_found")
                completion?(false)
                return
            }

            // The Codex composer is anchored to the bottom of the main window.
            // Its horizontal span always crosses the window center, including
            // sidebar/review-panel layouts. Clamp the inset for small windows.
            let bottomInset = min(64, max(48, window.height * 0.043))
            let target = CGPoint(x: window.midX, y: window.maxY - bottomInset)
            let originalPointer = CGEvent(source: nil)?.location
            let succeeded = self.postClick(at: target)
            if let originalPointer {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    CGWarpMouseCursorPosition(originalPointer)
                }
            }
            AppLogger.shared.log(
                "codex_input_focus success=\(succeeded) strategy=window_relative_click window=\(Int(window.width))x\(Int(window.height)) target=\(Int(target.x)),\(Int(target.y))"
            )
            completion?(succeeded)
        }
    }

    private func primaryWindowBounds(processIdentifier: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        return windowInfo.compactMap { info -> CGRect? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == Int(processIdentifier),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (boundsDictionary["X"] as? NSNumber)?.doubleValue,
                  let y = (boundsDictionary["Y"] as? NSNumber)?.doubleValue,
                  let width = (boundsDictionary["Width"] as? NSNumber)?.doubleValue,
                  let height = (boundsDictionary["Height"] as? NSNumber)?.doubleValue else { return nil }
            let bounds = CGRect(x: x, y: y, width: width, height: height)
            guard
                  bounds.width >= 500,
                  bounds.height >= 400 else { return nil }
            return bounds
        }.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    private func postClick(at point: CGPoint) -> Bool {
        guard let down = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: eventSource,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return false }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
