import Foundation

@main struct PipelineRecoveryTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(value(), message)
    }
    @MainActor static func main() async throws {
        check(!RepeatedText.containsRun(String(repeating: "啊", count: 14)), "14 repeated characters accepted")
        check(RepeatedText.containsRun(String(repeating: "啊", count: 15)), "15 repeated characters trigger")
        check(RepeatedText.containsRun(String(repeating: "아 ", count: 15)), "spaced Korean repetition detected")
        check(RepeatedText.containsRun(String(repeating: "啊，", count: 15)), "punctuated repetition detected")
        check(!RepeatedText.containsRun("非常非常重要，这是一个非常非常重要的问题。"), "ordinary emphasis preserved")
        check(!RepeatedText.containsRun("aaaaaaaaaaaaaaBaaaaaaaaaaaaaa"), "a different character breaks the run")
        check(!RepeatedText.containsRun(String(repeating: "数据，", count: 14)), "14 two-character repetitions accepted")
        check(RepeatedText.containsRun(String(repeating: "数据，", count: 15)), "15 consecutive pairs trigger across separators")
        check(!RepeatedText.containsRun(String(repeating: "有数据。无数据。", count: 3)), "scattered topic words do not count as a loop")
        check(!RepeatedText.containsRun("데이터, 데이터, 데이터가 중요합니다."), "ordinary Korean emphasis preserved")
        check(RepeatedText.containsRun(String(repeating: "형태의 데이터 ", count: 27)), "screenshot-style two-word loop detected")
        let repeatedTail = "전환하게 되면은 아까 게임 " + String(repeating: "데이터 ", count: 27)
        check(RepeatedText.containsRun(repeatedTail), "valid prefix does not hide a repeating word tail")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-pipeline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        var settings = AppSettings(); settings.recognitionEngine = .whisperTurbo
        let model = AppModel(store: store, settings: settings, startBackgroundWork: false)
        model.isRunning = true
        let epoch = model.currentCaptureEpoch
        let id = UUID(), date = Date(), url = store.audio.appendingPathComponent("window.wav")
        try Data([0,1,2]).write(to: url)
        var window = SpeechWindow(id: id, url: url, date: date, overlap: false, isFinal: false, duration: 10)
        check(model.commitPreview("The meeting starts at nine", window: window, epoch: epoch), "publish provisional original")
        check(model.allCaptions.map(\.id) == [id], "one provisional row")
        window.isFinal = true
        model.acceptWindow(window, epoch: epoch, settings: settings)
        check(model.allCaptions.map(\.id) == [id] && model.allCaptions[0].original == "The meeting starts at nine", "final audio keeps provisional row and text")
        check(model.jobs[0].stage == .recognize && model.jobs[0].original.isEmpty, "provisional original never enters translation queue")
        check(TranscriptExport.render(model.jobs).isEmpty, "provisional original is not an exported confirmed transcript")
        let reopened = AppModel(store: store, settings: settings, startBackgroundWork: false)
        check(reopened.allCaptions.first?.original == "The meeting starts at nine", "pending original survives restart")
        check(model.commitRecognition("The meeting starts at nine.", for: id), "confirm original")
        check(model.allCaptions.count == 1 && model.allCaptions[0].id == id, "recognition updates the same row")
        check(model.commitTranslation("会议九点开始。", for: id), "complete translation")
        check(model.allCaptions[0].id == id && model.allCaptions[0].translated == "会议九点开始。", "translation fills existing row")

        let badURL = store.audio.appendingPathComponent("repeat.wav"), badID = UUID()
        try Data([4,5,6]).write(to: badURL)
        model.acceptCapturedAudio(url: badURL, date: date.addingTimeInterval(10), overlap: false, epoch: epoch, settings: settings, id: badID, preview: "Original retained during recovery")
        let oldSession = model.jobs.first { $0.id == id }?.sessionID
        let generation = model.currentPipelineGeneration
        check(!model.commitRecognition(repeatedTail, for: badID), "bad recognition rejected")
        check(model.isRunning && model.currentCaptureEpoch == epoch, "recovery does not stop capture or discard its epoch")
        check(model.jobs.first { $0.id == badID }?.recognitionFailures == 1 && model.currentPipelineGeneration == generation, "only the affected segment is scheduled to retry")
        check(FileManager.default.fileExists(atPath: badURL.path), "bad segment audio retained")
        check(model.jobs.first { $0.id == badID }?.original == "", "bad text never becomes the source")
        check(model.allCaptions.contains { $0.id == badID && $0.original == "Original retained during recovery" && $0.displayText == "正在重新识别…" }, "clean preview stays in the same row during retry")
        check(model.allCaptions.contains { $0.id == id && $0.translated == "会议九点开始。" }, "previous captions stay visible during recovery")
        model.failed(badID, error: BridgeError("Whisper 识别超时"))
        check(model.jobs.first { $0.id == badID }?.stage == .blocked, "repetition and timeout share one retry budget")
        check(!model.commitRecognition("Late old result", for: badID), "late recognition cannot overwrite a blocked row")
        check(model.allCaptions.contains { $0.id == badID && $0.original == "Original retained during recovery" && $0.displayText.contains("识别失败") }, "failed caption still shows its last clean preview")
        check(FileManager.default.fileExists(atPath: badURL.path), "audio still retained after retry exhausted")
        check(!TranscriptExport.render(model.jobs).contains("Original retained during recovery"), "failed preview is never exported as confirmed text")

        let nextURL = store.audio.appendingPathComponent("next.wav"), nextID = UUID()
        try Data([7]).write(to: nextURL)
        model.acceptCapturedAudio(url: nextURL, date: date.addingTimeInterval(20), overlap: false, epoch: epoch, settings: settings, id: nextID)
        check(model.jobs.first { $0.id == nextID }?.sessionID == oldSession, "ASR failure does not erase translation history")
        check(model.commitRecognition("The report is ready.", for: nextID), "valid next segment proceeds")
        let beforeTranslation = model.currentPipelineGeneration
        check(!model.commitTranslation(String(repeating: "啊，", count: 15), for: nextID), "repeated translation rejected")
        await model.waitForPipelineRecovery()
        check(model.currentPipelineGeneration == beforeTranslation + 1, "translation repetition resets pipeline too")
        check(model.jobs.first { $0.id == nextID }?.original == "The report is ready.", "translation recovery keeps valid original")
        check(model.commitTranslation("报告已准备好。", for: nextID), "clean translation accepted after recovery")

        let bothURL = store.audio.appendingPathComponent("both.wav"), bothID = UUID()
        try Data([8]).write(to: bothURL)
        model.acceptCapturedAudio(url: bothURL, date: date.addingTimeInterval(30), overlap: false, epoch: epoch, settings: settings, id: bothID)
        _ = model.commitRecognition(String(repeating: "아 ", count: 15), for: bothID)
        await model.waitForPipelineRecovery()
        check(model.commitRecognition("Clean source after recognition recovery", for: bothID), "source recovers before translation")
        let countBeforeBoth = model.pipelineRecoveryCount
        _ = model.commitTranslation(String(repeating: "啊，", count: 15), for: bothID)
        await model.waitForPipelineRecovery()
        check(model.pipelineRecoveryCount == countBeforeBoth + 1, "recognition and translation each get an independent bounded recovery")
        check(model.jobs.first { $0.id == bothID }?.stage == .translate, "first translation failure not blocked by previous recognition recovery")

        let preview = SpeechWindow(id: UUID(), url: root.appendingPathComponent("preview.wav"), date: Date(), overlap: false, isFinal: false, duration: 10)
        let count = model.pipelineRecoveryCount
        check(model.commitPreview("정상 문장", window: preview, epoch: epoch), "clean draft accepted")
        check(!model.commitPreview(repeatedTail, window: preview, epoch: epoch), "repeated draft rejected")
        check(model.pipelineRecoveryCount == count && model.allCaptions.last?.original == "정상 문장", "bad preview leaves the clean draft and pipeline alone")
        check(!model.allCaptions.contains { RepeatedText.containsRun($0.original) || RepeatedText.containsRun($0.translated) }, "no new repeated text in visible captions")

        var toxic = AudioJob(id: UUID(), sessionID: UUID(), created: Date(), audioFile: "none.wav", language: "ko-KR", localRecognition: true)
        toxic.original = repeatedTail; toxic.stage = .done
        var healthy = toxic; healthy.id = UUID(); healthy.original = "정상 문장"; healthy.translated = "正常句子。"
        var target = healthy; target.id = UUID()
        let context = TranslationHistory.context(before: target, in: [toxic, healthy, target], limit: 4)
        check(context.count == 1 && context[0].original == healthy.original, "historical toxic source excluded from context")
        toxic.original = "Source is normal"; toxic.translated = String(repeating: "啊，", count: 15)
        check(TranslationHistory.context(before: target, in: [toxic, target], limit: 4).isEmpty, "toxic earlier translation excluded")
        await model.clearRecords()
        check(model.allCaptions.isEmpty, "clear removes retained pending placeholders too")
        await model.shutdown(); await reopened.shutdown()
        print("PASS: \(checks) pipeline checks — repetition boundaries, bounded recognition, audio preservation, stable subtitle identity")
    }
}
