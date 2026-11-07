import Foundation
import AVFoundation

private final class FakeVAD: VoiceActivityDetecting {
    var calls = 0
    var resets = 0
    var failAt: Int?
    var invalid = false
    func reset() { resets += 1 }
    func probabilities(for samples: [Float]) throws -> [Float] {
        calls += 1
        if calls == failAt { throw SileroVAD.Unavailable() }
        if invalid { return [.nan] }
        // A quiet marker is speech, a loud marker is non-speech noise.
        return stride(from: 0, to: samples.count, by: 512).map { start in
            let amplitude = samples[start..<min(start + 512, samples.count)].map(abs).max() ?? 0
            return amplitude > 0 && amplitude < 0.003 ? 0.95 : 0
        }
    }
}

@main struct VADTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(value(), message)
    }
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    static func feed(_ values: [Float], into segmenter: AudioSegmenter, size: Int = 137) {
        for offset in stride(from: 0, to: values.count, by: size) {
            segmenter.appendPCM(Array(values[offset..<min(offset + size, values.count)]))
        }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("build/tests/vad-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ detector: VoiceActivityDetecting) -> AudioSegmenter { AudioSegmenter(directory: root, detector: detector) }

        let detector = FakeVAD(), segmenter = make(detector)
        var windows: [SpeechWindow] = []
        segmenter.onWindow = { windows.append($0) }
        feed([Float](repeating: 0, count: 32000), into: segmenter)
        feed([Float](repeating: 0.001, count: 16000), into: segmenter)
        feed([Float](repeating: 0, count: 6400), into: segmenter)
        check(windows.isEmpty, "brief pause must not commit")
        feed([Float](repeating: 0.001, count: 20800), into: segmenter)
        feed([Float](repeating: 0, count: 28800), into: segmenter)
        segmenter.flush()
        let finals = windows.filter(\.isFinal)
        check(finals.count == 1, "quiet speech joins across a brief pause, then commits")
        let pcm = try read(finals[0].url)
        check(pcm.filter { $0 > 0.0005 }.count == 36800, "every quiet speech sample retained, even below old energy threshold")
        let prefix = pcm.prefix { abs($0) < 0.00001 }.count
        check(prefix >= 8000 && prefix <= 17000, "bounded pre-roll retains speech onset")
        check(pcm.reversed().prefix { abs($0) < 0.00001 }.count >= 23000, "unfinished phrase keeps end padding and pause")
        check(detector.resets == 1, "rolling VAD state persists across windows until flush")

        let uncertain = make(FakeVAD()); var uncertainWindows: [SpeechWindow] = []
        uncertain.onWindow = { if $0.isFinal { uncertainWindows.append($0) } }
        feed([Float](repeating: 0.01, count: 9 * 16000), into: uncertain, size: 1600)
        check(uncertainWindows.isEmpty, "non-speech energy does not repeatedly trigger pause commits")
        feed([Float](repeating: 0.01, count: 3 * 16000), into: uncertain)
        uncertain.flush()
        check(uncertainWindows.count == 2, "uncertain audio uses bounded safety submission, never disappears")
        let uncertainPCM = try uncertainWindows.flatMap { try read($0.url) }
        check(uncertainPCM.count == 12 * 16000 + 24000, "safety cut preserves all samples plus explicit overlap")
        check(uncertainWindows[1].overlap, "uncertain hard cut advertises overlap")

        for invalid in [false, true] {
            let failing = FakeVAD(); failing.failAt = 2; failing.invalid = invalid
            let fallback = make(failing); var statuses: [String] = [], output: [URL] = []
            fallback.onVADStatus = { statuses.append($0) }
            fallback.onSegment = { url, _, _ in output.append(url) }
            let ordered = (0..<16000).map { Float(0.01 + Double($0) / 1_000_000) }
            feed(ordered, into: fallback)
            fallback.flush()
            check(statuses.count == 1 && statuses[0].contains("回退"), "failure reported once without fatal capture error")
            let fallbackCount = try output.map { try read($0).count }.reduce(0, +)
            check(fallbackCount == 16000, "failing batch and pending tail survive fallback")
            let restored = try output.flatMap { try read($0) }
            check(zip(restored, ordered).allSatisfy { abs($0 - $1) < 0.00004 }, "fallback preserves exact chronology across a partial pending batch")
        }

        let tail = make(FakeVAD()); var tailURLs: [URL] = []
        tail.onSegment = { url, _, _ in tailURLs.append(url) }
        feed([Float](repeating: 0.001, count: 5001), into: tail)
        tail.flush()
        check(tailURLs.count == 1, "stop flushes incomplete VAD batch")
        let tailCount = try read(tailURLs[0]).count
        check(tailCount == 5001, "zero padding for inference never leaks into saved WAV")

        let resetDetector = FakeVAD(), cleared = make(resetDetector)
        var clearedURLs: [URL] = []
        cleared.onSegment = { url, _, _ in clearedURLs.append(url) }
        feed([Float](repeating: 0.02, count: 2100), into: cleared)
        cleared.discard()
        feed([Float](repeating: 0.001, count: 4800), into: cleared); cleared.flush()
        check(resetDetector.resets == 2, "clear resets model history and pending frames")
        let clearedPCM = try read(clearedURLs[0])
        check(clearedPCM.allSatisfy { $0 < 0.002 }, "clear cannot leak old pending PCM into a new meeting")

        let continuous = make(FakeVAD()); var bounded: [SpeechWindow] = []
        continuous.onWindow = { if $0.isFinal { bounded.append($0) } }
        let continuousBlock = [Float](repeating: 0.001, count: 1600)
        for _ in 0..<12000 { continuous.appendPCM(continuousBlock) }
        continuous.flush()
        check(bounded.count >= 120 && bounded.allSatisfy { $0.duration <= 10.04 }, "20 minutes of accelerated VAD input has a bounded maximum window")
        let retained = try bounded.map { try read($0.url).count }.reduce(0, +)
        check(retained == 1200 * 16000 + bounded.map(\.contextSampleCount).reduce(0, +), "20-minute continuous path conserves PCM including declared overlap")

        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let appPath = ProcessInfo.processInfo.environment["TINGQIAO_VAD_APP"].map { URL(fileURLWithPath: $0) }
        let library = appPath?.appendingPathComponent("Contents/MacOS/libTingQiaoVAD.dylib") ?? project.appendingPathComponent("build/whisper-engine/libTingQiaoVAD.dylib")
        let model = appPath?.appendingPathComponent("Contents/Resources/\(SileroVAD.modelName)") ?? project.appendingPathComponent("Resources/\(SileroVAD.modelName)")
        let real = try SileroVAD(libraryURL: library, modelURL: model)
        var silenceProbs: [Float] = []
        for _ in 0..<24 { silenceProbs += try real.probabilities(for: [Float](repeating: 0, count: 2048)) }
        check(silenceProbs.allSatisfy { $0 < 0.5 }, "real bundled Silero rejects digital silence")
        do { _ = try SileroVAD(libraryURL: library, modelURL: project.appendingPathComponent("README.md")); preconditionFailure("bad hash accepted") }
        catch { check(true, "corrupt model rejected before loading native code") }
        do { _ = try SileroVAD(libraryURL: root.appendingPathComponent("missing.dylib"), modelURL: model); preconditionFailure("missing library accepted") }
        catch { check(true, "missing inference component safely rejected") }

        for scenario in [("en", Float(1)), ("ko", Float(1)), ("en", Float(0.05)), ("ko", Float(0.05))] {
            let (language, gain) = scenario
            real.reset()
            let speech = try read(project.appendingPathComponent("build/tests/vad-\(language).wav")).map { $0 * gain }
            var probabilities: [Float] = [], times: [Double] = []
            for offset in stride(from: 0, to: speech.count, by: 2048) {
                var frame = Array(speech[offset..<min(offset + 2048, speech.count)])
                frame += [Float](repeating: 0, count: 2048 - frame.count)
                let start = Date()
                probabilities += try real.probabilities(for: frame)
                times.append(Date().timeIntervalSince(start))
            }
            let ratio = Double(probabilities.filter { $0 >= 0.5 }.count) / Double(probabilities.count)
            check(ratio > 0.3, "real Silero recognizes synthesized \(language) speech")
            let sorted = times.sorted(), p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            print(String(format: "VAD %@ gain %.2f: speech frames %.1f%%, mean %.2f ms, p95 %.2f ms / 128 ms batch", language, gain, ratio * 100, times.reduce(0,+) / Double(times.count) * 1000, p95 * 1000))

            let actual = make(try SileroVAD(libraryURL: library, modelURL: model))
            var actualFinals: [SpeechWindow] = []
            actual.onWindow = { if $0.isFinal { actualFinals.append($0) } }
            feed([Float](repeating: 0, count: 32000) + speech + [Float](repeating: 0, count: 32000), into: actual, size: 1600)
            actual.flush()
            check(!actualFinals.isEmpty && actualFinals.allSatisfy { $0.duration <= 10.04 }, "real \(language) VAD feeds bounded final WAVs")
        }
        print("PASS: \(checks) VAD checks — quiet speech, pre-roll, pauses, PCM conservation, fallback, flush, reset, real Silero")
    }
}
