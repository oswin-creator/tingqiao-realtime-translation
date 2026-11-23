import AVFoundation
import CoreAudio
import AudioToolbox

struct SpokenOutput: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let automaticEligible: Bool

    static var defaultDevice: AudioDeviceID {
        number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    }

    static func available() -> [Self] {
        var property = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &bytes) == noErr, bytes > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        let result = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &property, 0, nil, &bytes, $0.baseAddress!)
        }
        guard result == noErr else { return [] }
        return devices.compactMap(resolve).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func resolve(_ id: AudioDeviceID) -> Self? {
        guard id != kAudioObjectUnknown, number(id, kAudioDevicePropertyDeviceIsAlive) != 0 else { return nil }
        var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
              let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName)
        else { return nil }

        let transport = number(id, kAudioDevicePropertyTransportType)
        let source = number(id, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        var jackProperty = address(kAudioDevicePropertyJackIsConnected, scope: kAudioObjectPropertyScopeOutput)
        let hasJack = AudioObjectHasProperty(id, &jackProperty)
        let jack = number(id, kAudioDevicePropertyJackIsConnected, scope: kAudioObjectPropertyScopeOutput)
        let headphoneSource: UInt32 = 0x6864706e  // hdpn
        let namedHeadphones = ["headphone", "headset", "earbud", "airpods", "耳机", "ヘッドフォン", "헤드폰"]
            .contains { name.localizedCaseInsensitiveContains($0) }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            guard source == headphoneSource || namedHeadphones, !hasJack || jack == 1 else { return nil }
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB:
            break
        default:
            guard namedHeadphones else { return nil }
        }
        return Self(id: id, uid: uid, name: name, automaticEligible: transport == kAudioDeviceTransportTypeBuiltIn || namedHeadphones)
    }

    fileprivate static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var property = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

final class SpokenOutputListener {
    private let block: AudioObjectPropertyListenerBlock
    private var system = [(AudioObjectID, AudioObjectPropertyAddress)]()
    private var device = [(AudioObjectID, AudioObjectPropertyAddress)]()
    private var watched: AudioDeviceID?

    init(onChange: @escaping @Sendable () -> Void) {
        block = { _, _ in onChange() }
        let id = AudioObjectID(kAudioObjectSystemObject)
        system = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice].compactMap {
            add(id, SpokenOutput.address($0))
        }
    }

    func watch(_ id: AudioDeviceID?) {
        guard id != watched else { return }
        remove(device)
        watched = id
        guard let id else { device = []; return }
        device = [
            SpokenOutput.address(kAudioDevicePropertyDeviceIsAlive),
            SpokenOutput.address(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput),
            SpokenOutput.address(kAudioDevicePropertyJackIsConnected, scope: kAudioObjectPropertyScopeOutput)
        ].compactMap { add(id, $0) }
    }

    private func add(_ id: AudioObjectID, _ value: AudioObjectPropertyAddress) -> (AudioObjectID, AudioObjectPropertyAddress)? {
        var address = value
        guard AudioObjectHasProperty(id, &address),
              AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr else { return nil }
        return (id, address)
    }

    private func remove(_ entries: [(AudioObjectID, AudioObjectPropertyAddress)]) {
        for (id, var address) in entries { AudioObjectRemovePropertyListenerBlock(id, &address, .main, block) }
    }

    deinit { remove(device); remove(system) }
}

@MainActor
protocol SpokenPlaying: AnyObject {
    func matches(_ output: SpokenOutput, sampleRate: Int) -> Bool
    func play(_ clip: SpokenClip, speed: Double, completion: @escaping @Sendable () -> Void) throws
    func setSpeed(_ speed: Double)
    func setVolume(_ volume: Double)
    func enqueue(_ clip: SpokenClip, completion: @escaping @Sendable () -> Void) throws
    func pause()
    func finishLine()
    func stop()
}

@MainActor
final class SpokenAudioPlayer: SpokenPlaying {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let rate = AVAudioUnitTimePitch()
    private let output: SpokenOutput
    private let format: AVAudioFormat

    init(output: SpokenOutput, sampleRate: Int) throws {
        self.output = output
        format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        guard let unit = engine.outputNode.audioUnit else { throw BridgeError("无法打开耳机输出。") }
        var device = output.id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, size) == noErr,
              bound(to: output) else { throw BridgeError("无法绑定所选耳机。") }
        engine.attach(player)
        engine.attach(rate)
        engine.connect(player, to: rate, format: format)
        engine.connect(rate, to: engine.mainMixerNode, format: format)
    }

    func matches(_ output: SpokenOutput, sampleRate: Int) -> Bool {
        self.output == output && format.sampleRate == Double(sampleRate) && bound(to: output)
    }

    private func bound(to output: SpokenOutput) -> Bool {
        guard SpokenOutput.resolve(output.id)?.uid == output.uid, let unit = engine.outputNode.audioUnit else { return false }
        var selected = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, &size) == noErr
            && selected == output.id
    }

    func play(_ clip: SpokenClip, speed: Double, completion: @escaping @Sendable () -> Void) throws {
        guard bound(to: output) else { throw BridgeError("耳机已断开。") }
        if !engine.isRunning { try engine.start() }
        setSpeed(speed)
        try enqueue(clip, completion: completion)
        player.play()
    }

    func setSpeed(_ speed: Double) {
        rate.rate = Float(speed)
    }

    func setVolume(_ volume: Double) {
        player.volume = Float(volume.isFinite ? min(1, max(0, volume)) : 1)
    }

    func enqueue(_ clip: SpokenClip, completion: @escaping @Sendable () -> Void) throws {
        guard bound(to: output) else { throw BridgeError("耳机已断开。") }
        let frames = AVAudioFrameCount(clip.pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { throw BridgeError("无法准备播报音频。") }
        buffer.frameLength = frames
        clip.pcm.withUnsafeBytes { bytes in
            for i in 0..<Int(frames) {
                samples[i] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
    }

    func pause() {
        player.pause()
    }

    func finishLine() {
        player.stop()
    }

    func stop() {
        player.stop()
        engine.stop()
    }
}
