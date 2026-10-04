import AVFoundation
import CoreAudio
import AudioToolbox

struct VoiceOutputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Sends only remote PCM to an explicitly selected loopback output. Never
/// accesses a microphone or changes the system default input/output device.
final class RemoteVoiceOutput {
    private var unit: AudioUnit?
    private var deviceID: AudioDeviceID = 0
    private let lock = NSLock()
    private var ring: [Float] = []
    private var readIndex = 0
    private var writeIndex = 0
    private var queuedSamples = 0
    private var sampleRate = 48_000.0
    private var generation = 0
    deinit { stop() }

    static func devices() -> [VoiceOutputDevice] {
        allDevices().filter { $0.name.hasPrefix("BlackHole") || $0.name.hasPrefix("MiRemoteV") }
    }

    static func inputDevices() -> [VoiceOutputDevice] {
        allDevices().filter { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: 0)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device.id, &address, 0, nil, &size) == noErr && size > 0
        }
    }

    private static func allDevices() -> [VoiceOutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let name = stringProperty(id, kAudioObjectPropertyName),
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return VoiceOutputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }

    func start(uid: String) throws {
        stop()
        guard let device = Self.devices().first(where: { $0.uid == uid }) else { throw failure("虚拟麦克风未安装或已断开") }
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw failure("无法创建固定设备音频输出") }
        var created: AudioUnit?
        guard AudioComponentInstanceNew(component, &created) == noErr, let unit = created else { throw failure("无法创建固定设备音频输出") }
        self.unit = unit
        do {
        var enabled: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enabled, 4))
        enabled = 0
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, 4))
        var id = device.id
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, 4))
        deviceID = id
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, &size))
        sampleRate = format.mSampleRate
        guard sampleRate >= 16_000, sampleRate <= 192_000, format.mChannelsPerFrame > 0 else { throw failure("虚拟麦克风格式不支持") }
        format.mFormatID = kAudioFormatLinearPCM
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved
        format.mBytesPerPacket = 4; format.mFramesPerPacket = 1
        format.mBytesPerFrame = 4; format.mBitsPerChannel = 32
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, size))
        ring = [Float](repeating: 0, count: Int(sampleRate * 2))
        var callback = AURenderCallbackStruct(inputProc: { reference, _, _, _, frames, buffers in
            guard let buffers else { return noErr }
            Unmanaged<RemoteVoiceOutput>.fromOpaque(reference).takeUnretainedValue().render(frames: Int(frames), buffers: buffers)
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check(AudioUnitInitialize(unit))
        try check(AudioOutputUnitStart(unit))
        try verifyDevice()
        AppLogger.shared.log("remote_voice_output_bound fixed_device=true")
        } catch { stop(); throw error }
    }

    func append(_ samples: [Int16]) throws {
        try verifyDevice()
        guard !samples.isEmpty else { return }
        let count = Int(Double(samples.count) * sampleRate / 16_000)
        lock.lock(); defer { lock.unlock() }
        guard queuedSamples + count <= ring.count else { throw failure("音频输出积压，请重新连接") }
        for i in 0..<count {
            let position = Double(i) * 16_000 / sampleRate
            let index = min(Int(position), samples.count - 1)
            let fraction = Float(position - Double(index))
            let a = Float(samples[index]) / 32768
            let b = Float(samples[min(index + 1, samples.count - 1)]) / 32768
            ring[writeIndex] = a + (b - a) * fraction
            writeIndex = (writeIndex + 1) % ring.count
        }
        queuedSamples += count
    }

    private func render(frames: Int, buffers: UnsafeMutablePointer<AudioBufferList>) {
        lock.lock(); defer { lock.unlock() }
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        for i in 0..<frames {
            var value: Float = 0
            if queuedSamples > 0 {
                value = ring[readIndex]; readIndex = (readIndex + 1) % ring.count; queuedSamples -= 1
            }
            for buffer in list {
                if let data = buffer.mData, i * 4 < Int(buffer.mDataByteSize) {
                    data.assumingMemoryBound(to: Float.self)[i] = value
                }
            }
        }
    }

    private func verifyDevice() throws {
        guard let unit else { throw failure("音频输出未启动") }
        var actual: AudioDeviceID = 0
        var size: UInt32 = 4
        try check(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actual, &size))
        guard actual == deviceID else { throw failure("音频输出设备发生变化，已阻止扬声器播放") }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw failure("固定音频输出失败（\(status)）") }
    }

    func drain() {
        let token = generation
        finishDrain(token: token, deadline: Date(timeIntervalSinceNow: 3))
    }

    private func finishDrain(token: Int, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.generation == token else { return }
            self.lock.lock()
            let empty = self.queuedSamples == 0
            self.lock.unlock()
            if empty || Date() >= deadline { self.stop() }
            else { self.finishDrain(token: token, deadline: deadline) }
        }
    }

    func stop() {
        generation += 1
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        lock.lock(); defer { lock.unlock() }
        ring = []; readIndex = 0; writeIndex = 0
        queuedSamples = 0
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "RemoteVoiceOutput", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
