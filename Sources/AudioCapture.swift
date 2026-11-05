import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CoreMedia

struct InputDevice: Identifiable, Hashable { var id: String; var name: String }
struct MeetingApplication: Identifiable, Hashable { var id: String; var name: String }

final class AudioSegmenter {
    private let directory: URL
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var previousFormat: AVAudioFormat?
    private let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var silence = 0.0
    private var voiced = 0.0
    private var energyVoiced = 0.0
    private var detector: VoiceActivityDetecting?
    private var pendingPCM: [Float] = []
    private var vadSpeaking = false
    private var carriesOverlap = false
    private var lastMeter = Date.distantPast
    private var windowID = UUID()
    private var lastPreview = 0.0
    private var complete = false
    private var latestPause = 0
    private let meetingRules: Bool
    var onWindow: ((SpeechWindow) -> Void)?
    var onSegment: ((URL, Date, Bool) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?
    var onVADStatus: ((String) -> Void)?
    init(directory: URL, meetingRules: Bool = true, detector: VoiceActivityDetecting? = nil) {
        self.directory = directory; self.meetingRules = meetingRules; self.detector = detector
        samples.reserveCapacity(320000); pendingPCM.reserveCapacity(4096)
    }
    // Run on the sample queue before capture starts, not on the UI thread.
    func enableSilero() {
        do { detector = try SileroVAD(); onVADStatus?("Silero VAD · 本机语音检测") }
        catch { detector = nil; onVADStatus?(SileroVAD.Unavailable().localizedDescription) }
    }
    func setComplete(_ value: Bool, id: UUID) { if id == windowID { complete = value } }

    // Called exclusively on the capture's serial sample queue.
    func append(_ sample: CMSampleBuffer) {
        guard sample.isValid, let description = sample.formatDescription, sample.numSamples > 0 else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else { return }
        pcm.frameLength = pcm.frameCapacity
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(sample.numSamples), into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }
        if previousFormat != format {
            converter = AVAudioConverter(from: format, to: target)
            previousFormat = format
        }
        guard let converter,
              let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * 16000 / format.sampleRate) + 64) else { return }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: converted, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return pcm
        }
        guard result != .error, let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
        appendPCM(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
    }

    // 128 ms batches amortize inference; individual 32 ms probabilities still
    // drive pause timing. Every original sample is passed to the segmenter.
    func appendPCM(_ values: [Float]) {
        guard !values.isEmpty else { return }
        guard detector != nil else { consume(values, speech: nil); return }
        pendingPCM.append(contentsOf: values)
        var offset = 0
        while pendingPCM.count - offset >= 2048 {
            consumeVAD(Array(pendingPCM[offset..<(offset + 2048)]))
            offset += 2048
        }
        if offset > 0 { pendingPCM.removeFirst(offset) }
        if detector == nil, !pendingPCM.isEmpty {
            // A failure can occur with a sub-batch tail already buffered. Drain
            // it now, before the next callback enters the unbuffered fallback.
            let tail = pendingPCM; pendingPCM.removeAll(keepingCapacity: true)
            consume(tail, speech: nil)
        }
    }

    private func consumeVAD(_ values: [Float]) {
        guard let detector else { consume(values, speech: nil); return }
        let padded = values + [Float](repeating: 0, count: (512 - values.count % 512) % 512)
        do {
            let probabilities = try detector.probabilities(for: padded)
            guard probabilities.count == padded.count / 512,
                  probabilities.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw SileroVAD.Unavailable() }
            for (frame, probability) in probabilities.enumerated() {
                // Hysteresis prevents weak syllables from flickering at 0.5.
                vadSpeaking = probability >= (vadSpeaking ? 0.35 : 0.5)
                let start = frame * 512, end = min(start + 512, values.count)
                if start < end { consume(Array(values[start..<end]), speech: vadSpeaking) }
            }
        } catch {
            // Do not stop capture, discard the failing batch, or retry forever.
            self.detector = nil; vadSpeaking = false
            onVADStatus?(SileroVAD.Unavailable().localizedDescription)
            consume(values, speech: nil)
        }
    }

    private func consume(_ values: [Float], speech: Bool?) {
        let count = values.count
        let energy = sqrt(values.reduce(0.0) { $0 + Double($1 * $1) } / Double(count))
        let duration = Double(count) / 16000
        if energy > 0.0035 { energyVoiced += duration }
        if speech ?? (energy > 0.0035) { voiced += duration; silence = 0 } else { silence += duration }
        samples.append(contentsOf: values)
        if Date().timeIntervalSince(lastMeter) > 0.12 {
            lastMeter = Date(); onLevel?(min(1, energy * 12))
        }
        let elapsed = Double(samples.count) / 16000
        if meetingRules {
            if voiced >= 0.12, silence >= 0.18 && silence <= 0.4 && elapsed >= MeetingRules.earliestNaturalCut { latestPause = samples.count }
            if voiced >= 0.12, MeetingRules.shouldEnd(duration: elapsed, silence: silence, complete: complete) { emit(keepOverlap: false) }
            else if elapsed >= MeetingRules.naturalCutSearchStart, latestPause > 0 { emit(keepOverlap: false, cut: latestPause) }
            else if elapsed >= MeetingRules.maximumWindow { emit(keepOverlap: silence < 0.4 || (speech != nil && energy > 0.0035)) }
            else if voiced >= 0.3, silence < 1.0, elapsed - lastPreview >= MeetingRules.previewInterval, onWindow != nil {
                lastPreview = elapsed
                if let url = write(samples, draft: true) { onWindow?(SpeechWindow(id: windowID, url: url, date: Date().addingTimeInterval(-elapsed), overlap: carriesOverlap, isFinal: false, duration: elapsed)) }
            }
            // Idle silence must never produce an ever-growing buffer.
            // Keep 0.5 s before speech. Energy without VAD confirmation is not
            // aggressively thrown away: it reaches the maximum-window safety
            // submission (or flush), rather than causing frequent noise cuts.
            if voiced == 0 && energyVoiced == 0 && samples.count > 16000 { samples = Array(samples.suffix(8000)); silence = Double(samples.count) / 16000; lastPreview = 0 }
            return
        }
        if elapsed >= 5.0 { emit(keepOverlap: silence < 0.4) }
        else if elapsed >= 1.6 && silence >= 0.55 { emit(keepOverlap: false) }
    }

    func flush() {
        if !pendingPCM.isEmpty { let tail = pendingPCM; pendingPCM.removeAll(keepingCapacity: true); consumeVAD(tail) }
        if !samples.isEmpty { emit(keepOverlap: false) }
        detector?.reset(); vadSpeaking = false
        converter = nil; previousFormat = nil
    }
    func discard() {
        samples.removeAll(keepingCapacity: true)
        silence = 0; voiced = 0; energyVoiced = 0; carriesOverlap = false
        pendingPCM.removeAll(keepingCapacity: true); detector?.reset(); vadSpeaking = false
        windowID = UUID(); lastPreview = 0; complete = false; latestPause = 0
        converter = nil; previousFormat = nil
    }

    private func emit(keepOverlap: Bool, cut: Int? = nil) {
        let count = min(cut ?? samples.count, samples.count)
        let captured = Array(samples.prefix(count)), remainder = Array(samples.dropFirst(count))
        let id = windowID
        let hadOverlap = carriesOverlap
        let hasSpeech = voiced >= 0.12 || energyVoiced >= 0.12
        samples = (keepOverlap && hasSpeech ? Array(captured.suffix(8000)) : []) + remainder
        carriesOverlap = keepOverlap && hasSpeech
        voiced = 0; energyVoiced = 0; silence = 0
        windowID = UUID(); lastPreview = 0; complete = false; latestPause = 0
        if !remainder.isEmpty { voiced = Double(remainder.count) / 16000 }
        guard hasSpeech, let url = write(captured, draft: false) else { return }
        let date = Date().addingTimeInterval(-Double(captured.count + remainder.count) / 16000)
        onSegment?(url, date, hadOverlap)
        onWindow?(SpeechWindow(id: id, url: url, date: date, overlap: hadOverlap, isFinal: true, duration: Double(captured.count) / 16000))
    }
    private func write(_ captured: [Float], draft: Bool) -> URL? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(captured.count)), let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = buffer.frameCapacity
        captured.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: captured.count) }
        let folder = draft ? directory.deletingLastPathComponent().appendingPathComponent("Drafts") : directory
        let url = folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).wav")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file?.write(from: buffer)
            file = nil // close the WAV header before recognition starts
            return url
        } catch { if !draft { onFailure?("音频保存失败：\(error.localizedDescription)") }; return nil }
    }
}

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let segmenter: AudioSegmenter
    private let sampleQueue = DispatchQueue(label: "cn.tingqiao.samples", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "cn.tingqiao.microphone", qos: .userInitiated)
    private var stream: SCStream?
    private var microphone: AVCaptureSession?
    private var observers: [NSObjectProtocol] = []
    private var epoch: UUID
    var onSegment: ((URL, Date, Bool, UUID) -> Void)?
    var onWindow: ((SpeechWindow, UUID) -> Void)?
    var onFailure: ((String) -> Void)?

    init(directory: URL, epoch: UUID = UUID()) {
        segmenter = AudioSegmenter(directory: directory); self.epoch = epoch
        super.init()
        segmenter.onSegment = { [weak self] url, date, overlap in
            guard let self else { return }
            self.onSegment?(url, date, overlap, self.epoch)
        }
        segmenter.onWindow = { [weak self] window in guard let self else { return }; self.onWindow?(window, self.epoch) }
    }
    func setComplete(_ value: Bool, id: UUID) { sampleQueue.async { self.segmenter.setComplete(value, id: id) } }

    func discardPendingAudio(epoch: UUID) async {
        await withCheckedContinuation { continuation in
            sampleQueue.async {
                self.segmenter.discard(); self.epoch = epoch
                continuation.resume()
            }
        }
    }

    static func devices() -> [InputDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.map { InputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
    static func applications() async throws -> [MeetingApplication] {
        let content = try await shareableContent()
        let candidates = content.applications.filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier && !$0.applicationName.isEmpty }.map { MeetingApplication(id: $0.bundleIdentifier, name: $0.applicationName) }
        return candidates.reduce(into: [MeetingApplication]()) { result, app in
            if !result.contains(where: { $0.id == app.id }) { result.append(app) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func shareableContent() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) }
        catch { throw BridgeError("请到系统设置 → 隐私与安全性 → 屏幕与系统音频录制，允许“听桥”，然后退出并重新打开软件。系统提示：\(error.localizedDescription)", retryable: false) }
    }

    func start(settings: AppSettings) async throws {
        await withCheckedContinuation { continuation in
            sampleQueue.async { self.segmenter.enableSilero(); continuation.resume() }
        }
        if settings.mode == .online {
            let content = try await Self.shareableContent()
            guard let display = content.displays.first else { throw BridgeError("没有可用的屏幕，请检查系统录音/屏幕录制权限。", retryable: false) }
            let filter: SCContentFilter
            if settings.applicationID.isEmpty {
                filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }, exceptingWindows: [])
            } else {
                let selected = content.applications.filter { $0.bundleIdentifier == settings.applicationID }
                guard !selected.isEmpty else { throw BridgeError("所选会议软件未运行，请先打开它，或选择全部系统声音。") }
                filter = SCContentFilter(display: display, including: selected, exceptingWindows: [])
            }
            let config = SCStreamConfiguration()
            config.width = 2; config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.capturesAudio = true; config.excludesCurrentProcessAudio = true
            config.sampleRate = 16000; config.channelCount = 1
            if #available(macOS 15.0, *) { config.captureMicrophone = false }
            let capture = SCStream(filter: filter, configuration: config, delegate: self)
            try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            stream = capture
            do { try await capture.startCapture() }
            catch { stream = nil; throw BridgeError("系统声音启动失败。请到系统设置 → 隐私与安全性 → 屏幕与系统音频录制，允许“听桥”，再重新打开软件。\n\(error.localizedDescription)", retryable: false) }
        } else {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw BridgeError("请在系统设置 → 隐私与安全性 → 麦克风中允许“听桥”。", retryable: false) }
            let available = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
            let device: AVCaptureDevice?
            if settings.microphoneID.isEmpty { device = AVCaptureDevice.default(for: .audio) }
            else { device = available.first { $0.uniqueID == settings.microphoneID } }
            guard let device else { throw BridgeError("所选麦克风已断开，等待重新连接，或停止后选择其他麦克风。") }
            let session = AVCaptureSession()
            session.beginConfiguration()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw BridgeError("无法使用所选麦克风。") }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: sampleQueue)
            guard session.canAddOutput(output) else { throw BridgeError("无法建立麦克风音频输出。") }
            session.addOutput(output); session.commitConfiguration()
            microphone = session
            observers.append(NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in self?.onFailure?("麦克风中断，正在尝试重新连接。") })
            observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in self?.onFailure?("麦克风已断开，正在等待设备恢复。") })
            await withCheckedContinuation { continuation in sessionQueue.async { session.startRunning(); continuation.resume() } }
            guard session.isRunning else { throw BridgeError("麦克风未能开始收音。") }
        }
    }

    func stop() async {
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        if let capture = stream { stream = nil; try? await capture.stopCapture() }
        if let session = microphone {
            microphone = nil
            await withCheckedContinuation { continuation in sessionQueue.async { session.stopRunning(); continuation.resume() } }
        }
        await withCheckedContinuation { continuation in sampleQueue.async { self.segmenter.flush(); continuation.resume() } }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        if outputType == .audio { segmenter.append(sampleBuffer) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onFailure?("系统声音连接中断：\(error.localizedDescription)") }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { segmenter.append(sampleBuffer) }
}
