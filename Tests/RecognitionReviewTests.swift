import Foundation
import AVFoundation

@main struct RecognitionReviewTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { checks += 1; if !value { print("FAIL \(checks): \(message)"); exit(1) } }
    @MainActor static func main() async throws {
        for length in 1...10 {
            let words = (0..<length).map { "word\($0)" }.joined(separator: " ") + " "
            let letters = String(Array("甲乙丙丁戊己庚辛壬癸").prefix(length))
            check(!RepeatedText.containsRun(String(repeating: words, count: 9)), "nine word-pattern copies allowed")
            check(RepeatedText.containsRun(String(repeating: words, count: 10)), "ten copies of one to ten words flagged")
            check(!RepeatedText.containsRun(String(repeating: letters, count: 9)), "nine character-pattern copies allowed")
            check(RepeatedText.containsRun(String(repeating: letters, count: 10)), "ten copies of one to ten characters flagged")
        }
        check(RepeatedText.containsRun(String(repeating: "I'm not sure if ", count: 10)), "exported English contraction loop caught")
        check(RepeatedText.containsRun(String(repeating: "I’m not sure if ", count: 10)), "curly apostrophe loop caught")
        check(!RepeatedText.containsRun("They do not need to start at the same level. The other use and event study to look for differences."), "normal exported English e frequency preserved")
        check(!RepeatedText.containsRun("Employees with negative information also write more negative content. The face, the idea that protection helps people speak"), "normal nonconsecutive repeated letters preserved")
        check(!RepeatedText.containsRun("데이터, 데이터, 데이터가 중요합니다."), "ordinary emphasis preserved")
        check(!RepeatedText.containsTranslationRun(String(repeating: "啊", count: 10)), "translation review keeps separate threshold")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let segmenter = AudioSegmenter(directory: root.appendingPathComponent("Capture"))
        var windows: [SpeechWindow] = []
        segmenter.onWindow = { if $0.isFinal { windows.append($0) } }
        let signal = (0..<(22*16000)).map { Float(sin(Double($0)*0.19)*0.04) }
        for start in stride(from: 0, to: signal.count, by: 1600) { segmenter.appendPCM(Array(signal[start..<min(start+1600,signal.count)])) }
        segmenter.flush()
        check(windows.count == 3, "22 seconds produces two full new windows and a tail")
        check(windows[0].contextSampleCount == 0 && windows[1].contextSampleCount == 24000 && windows[2].contextSampleCount == 24000, "hard-cut prefix is exactly 1.5 seconds")
        check(abs(windows[1].duration - 10) < 0.11, "context does not consume ten-second new-audio budget")
        var recovered: [Float] = []
        for w in windows {
            let file = try AVAudioFile(forReading: w.url)
            let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: pcm)
            let values = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: Int(pcm.frameLength)))
            check(values.count == w.contextSampleCount + Int((w.duration*16000).rounded()), "saved waveform matches declared timing")
            recovered += values.dropFirst(w.contextSampleCount)
        }
        check(recovered.count == signal.count && zip(recovered,signal).allSatisfy { abs($0-$1)<0.00004 }, "new audio conserved once and in order")
        check(windows[1].audioStartSample! + Int64(windows[1].contextSampleCount) == Int64((windows[0].duration*16000).rounded()), "sample timeline identifies the true new-audio boundary")
        let originalBytes = try Data(contentsOf: windows[1].url)
        let crop = try RecognitionAudio.croppedInput(windows[1].url, skipping: windows[1].contextSampleCount)
        defer { try? FileManager.default.removeItem(at: crop) }
        let croppedFile = try AVAudioFile(forReading: crop)
        check(croppedFile.length == AVAudioFramePosition((windows[1].duration*16000).rounded()), "retry strips prefix and keeps all new samples")
        check(try Data(contentsOf: windows[1].url) == originalBytes, "review leaves original audio untouched")
        let oldTimeline = windows[0].audioTimelineID
        segmenter.discard(); windows.removeAll()
        segmenter.appendPCM(Array(signal.prefix(16000))); segmenter.flush()
        check(windows.count == 1 && windows[0].contextSampleCount == 0 && windows[0].audioStartSample == 0 && windows[0].audioTimelineID != oldTimeline, "clear starts a fresh audio timeline without old context")

        let spans = [RecognitionSpan(text: "project ", start: 0, end: 0.7), RecognitionSpan(text: "schedule ", start: 0.7, end: 1.5), RecognitionSpan(text: "tomorrow.", start: 1.6, end: 2.4)]
        let timed = RecognitionResult(text: "project schedule tomorrow.", spans: spans)
        check(RecognitionBoundary.resolve(timed, previous: "We review the project schedule.", sharedSamples: 24000, maximumDuration: 4) == "tomorrow.", "word timing removes only previously covered audio")
        let crossing = RecognitionResult(text: "통계학 입니다.", spans: [.init(text: "통계학 ", start: 1.2, end: 1.8), .init(text: "입니다.", start: 1.8, end: 2.2)])
        check(RecognitionBoundary.resolve(crossing, sharedSamples: 24000, maximumDuration: 4) == crossing.text, "term crossing the boundary remains intact")
        check(RecognitionBoundary.resolve(.init(text: "Unrelated new words"), previous: "We review the project schedule.", sharedSamples: 24000, maximumDuration: 4) == nil, "unknown timing and failed text alignment request clean review")
        check(RecognitionBoundary.resolve(.init(text: "project schedule tomorrow."), previous: "We review the PROJECT schedule.", sharedSamples: 24000, maximumDuration: 4) == "tomorrow.", "text fallback tolerates case and punctuation")
        check(RecognitionBoundary.resolve(.init(text: "Please repeat this sentence."), previous: "Please repeat this sentence.", sharedSamples: 24000, maximumDuration: 4) == nil, "whole repeated sentence is verified against clean audio")
        let malformed = RecognitionResult(text: timed.text, spans: [.init(text: "project schedule ", start: 0, end: 99), .init(text: "tomorrow.", start: 0, end: 1)])
        check(RecognitionBoundary.resolve(malformed, sharedSamples: 24000, maximumDuration: 4) == nil, "out-of-range word timestamps not trusted")

        let store = try SessionStore(root: root.appendingPathComponent("Store"))
        var settings = AppSettings(); settings.recognitionEngine = .whisperTurbo
        let model = AppModel(store: store, settings: settings, startBackgroundWork: false)
        model.isRunning = true
        let epoch = model.currentCaptureEpoch, timeline = UUID(), now = Date()
        func jobWindow(_ offset: Int, text: String? = nil) throws -> SpeechWindow {
            let id = UUID(), url = store.audio.appendingPathComponent(id.uuidString+".wav")
            try Data([1,2,3]).write(to: url)
            return SpeechWindow(id: id, url: url, date: now.addingTimeInterval(Double(offset)), overlap: offset>0, isFinal: true,
                duration: 10, contextSampleCount: offset>0 ? 24000 : 0, audioStartSample: Int64(offset*16000-(offset>0 ? 24000 : 0)), audioTimelineID: timeline)
        }
        let previous = try jobWindow(0)
        model.acceptWindow(previous, epoch: epoch, settings: settings)
        check(model.commitRecognition("We review the project schedule.", for: previous.id), "previous segment confirmed")
        let current = try jobWindow(10)
        model.acceptWindow(current, epoch: epoch, settings: settings)
        check(model.commitRecognition(timed, for: current.id), "timed recognition accepted through actual journal path")
        check(model.jobs.last?.original == "tomorrow.", "only new text queued for translation")
        let persisted = try store.load().last!
        check(persisted.contextSampleCount == 24000 && persisted.audioStartSample == current.audioStartSample && persisted.audioTimelineID == timeline, "prefix and sample timeline survive restart")
        let suspect = try jobWindow(20)
        model.acceptCapturedAudio(url: suspect.url, date: suspect.date, overlap: true, epoch: epoch, settings: settings, id: suspect.id, preview: "Last clean draft", window: suspect)
        let repetition = String(repeating: "I'm not sure if ", count: 10)
        let generation = model.currentPipelineGeneration
        check(!model.commitRecognition(repetition, for: suspect.id), "ten repeats are held for review")
        check(model.jobs.last?.recognitionSuspected == true && model.jobs.last?.recognitionFailures == 1 && model.jobs.last?.original == "", "suspect is persisted without becoming official text")
        check(model.allCaptions.last?.original == "Last clean draft" && model.allCaptions.last?.displayText == "正在复核识别…", "last clean preview stays visible during review")
        check(model.currentPipelineGeneration == generation && model.isRunning, "only this segment is reviewed, capture continues")
        check(FileManager.default.fileExists(atPath: suspect.url.path), "full original audio retained during review")
        check(model.commitRecognition("A complete new sentence.", for: suspect.id), "clean retry accepted without stripping text again")
        check(model.jobs.last?.recognitionSuspected == false && model.jobs.last?.stage == .translate, "successful review restores normal flow")
        let uncertain = try jobWindow(30)
        model.acceptWindow(uncertain, epoch: epoch, settings: settings)
        check(!model.commitRecognition("A new uncertain boundary", for: uncertain.id), "unresolved boundary uses one review")
        check(model.jobs.last?.recognitionFailures == 1, "alignment uncertainty consumes shared retry allowance")
        check(!model.commitRecognition(repetition, for: uncertain.id), "repetition on retry stops this segment")
        check(model.jobs.last?.stage == .blocked && model.jobs.last?.recognitionFailures == 2 && FileManager.default.fileExists(atPath: uncertain.url.path), "no third retry and full audio is preserved")
        let legacy = AudioJob(id: UUID(), sessionID: UUID(), created: now, audioFile: "legacy.wav", language: "ko-KR", localRecognition: true, overlap: true)
        let migrated = try JSONDecoder().decode(AudioJob.self, from: Data("{\"id\":\"\(legacy.id.uuidString)\",\"sessionID\":\"\(legacy.sessionID.uuidString)\",\"created\":0,\"audioFile\":\"legacy.wav\",\"language\":\"ko-KR\",\"localRecognition\":true,\"overlap\":true,\"stage\":\"recognize\",\"original\":\"\",\"translated\":\"\",\"attempts\":0,\"retryAfter\":0,\"error\":\"\"}".utf8))
        check(migrated.effectiveContextSampleCount == 8000, "old pending jobs retain the original half-second prefix")
        await model.shutdown()
        print("PASS \(checks) recognition review checks — repetition ranges, waveform conservation, timing, clean retry and journal recovery")
    }
}
