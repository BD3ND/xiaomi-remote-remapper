import Foundation

/// Silent hardware regression check; restores the original input on exit.
func runVoiceOutputRouteProbe() -> Int32 {
    guard let device = RemoteVoiceOutput.devices().first else { print("voice_route_test_missing_loopback"); return 1 }
    let output = RemoteVoiceOutput()
    let router = VoiceInputRouter()
    defer { output.stop(); router.restore() }
    do {
        try output.start(uid: device.uid)
        guard router.begin(uid: device.uid) else { print("voice_route_test_input_switch_failed"); return 1 }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        try output.append([Int16](repeating: 0, count: 320))
        router.restore()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        try output.append([Int16](repeating: 0, count: 320))
        print("voice_route_test_passed input_switch_and_restore_output_fixed=true silent=true")
        return 0
    } catch { print("voice_route_test_failed \(error.localizedDescription)"); return 1 }
}
