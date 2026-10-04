import AppKit

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTests())
} else if CommandLine.arguments.contains("--diagnostics") {
    exit(runDiagnostics())
} else if CommandLine.arguments.contains("--test-voice-output-route") {
    exit(runVoiceOutputRouteProbe())
} else if CommandLine.arguments.contains("--request-permissions") {
    exit(requestPermissions())
} else if CommandLine.arguments.contains("--probe-hid-open") {
    exit(probeHIDOpenPaths())
} else if CommandLine.arguments.contains("--enable-login-item") {
    exit(setLoginItem(enabled: true))
} else if CommandLine.arguments.contains("--disable-login-item") {
    exit(setLoginItem(enabled: false))
} else if CommandLine.arguments.contains("--focus-codex-input") {
    exit(runCodexFocusProbe())
} else if CommandLine.arguments.contains("--probe-xiaomi-voice") {
    exit(runVoiceCapabilityProbe())
} else if CommandLine.arguments.contains("--capture-xiaomi-voice-notify") {
    exit(runVoiceNotificationCapture())
} else if CommandLine.arguments.contains("--test-xiaomi-atvv") {
    exit(runATVVVoiceFrameProbe())
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
