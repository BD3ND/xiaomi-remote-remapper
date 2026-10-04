import CoreAudio
import Foundation

/// Changes only the default input, retaining a crash-recovery record by UID.
final class VoiceInputRouter {
    static let automaticKey = "remoteVoiceAutomaticInput"
    private let savedKey = "remoteVoiceRestoreInputUID"
    private var routedID: AudioDeviceID?
    private var generation = 0

    private func current() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr ? id : nil
    }

    private func set(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var value = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    func begin(uid: String) -> Bool {
        generation += 1
        guard let target = RemoteVoiceOutput.devices().first(where: { $0.uid == uid }), let original = current() else { return false }
        if routedID == target.id { return true }
        guard original != target.id,
              let source = RemoteVoiceOutput.inputDevices().first(where: { $0.id == original }) else { return false }
        UserDefaults.standard.set(source.uid, forKey: savedKey)
        guard set(target.id) else { UserDefaults.standard.removeObject(forKey: savedKey); return false }
        routedID = target.id
        return true
    }

    func end() {
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.generation == token else { return }
            self.restore()
        }
    }

    func restore() {
        generation += 1
        guard let uid = UserDefaults.standard.string(forKey: savedKey) else { routedID = nil; return }
        // Do not overwrite a microphone the user chose while recording.
        if let now = current(), RemoteVoiceOutput.devices().contains(where: { $0.id == now }) {
            guard let original = RemoteVoiceOutput.inputDevices().first(where: { $0.uid == uid }) else {
                AppLogger.shared.log("voice_input_restore_pending original_device_unavailable")
                return
            }
            guard set(original.id) else { return }
        }
        UserDefaults.standard.removeObject(forKey: savedKey)
        routedID = nil
    }
}
