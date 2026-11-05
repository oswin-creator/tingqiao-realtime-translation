import Foundation

@main struct RecordBehaviorTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("FAIL: \(message)") }
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-record-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let session = UUID()
        var initial: [AudioJob] = (0..<350).map { n in
            var job = AudioJob(id: UUID(), sessionID: session, created: Date(timeIntervalSince1970: Double(n)), audioFile: "\(n).wav", language: "en-US", localRecognition: true)
            job.original = "Source \(n)"; job.translated = "译文 \(n)"; job.stage = .done
            return job
        }
        initial[348].stage = .translate; initial[348].translated = ""
        initial[349].stage = .recognize; initial[349].original = ""; initial[349].translated = ""
        try Data([0]).write(to: store.audio.appendingPathComponent(initial[349].audioFile))
        try store.save(initial)
        var preferences = AppSettings(); preferences.provider = .custom
        let model = AppModel(store: store, settings: preferences, startBackgroundWork: false)
        check(model.captions.count == 200 && model.allCaptions.count == 349, "floating has all text beyond main display cap")
        let export = TranscriptExport.render(model.jobs)
        check(export.contains("原文：Source 0\n译文：译文 0") && export.contains("原文：Source 348\n译文：（待翻译）"), "TXT includes earliest original/translation and pending placeholder")
        check(export.components(separatedBy: "原文：").count - 1 == 349, "TXT does not truncate at 200 or 300")
        let oldEpoch = model.currentCaptureEpoch
        model.isRunning = true // A clear must work during capture and pending translation.
        await model.clearRecords()
        check(model.visibleJobs.isEmpty && model.allCaptions.isEmpty && model.pendingCount == 0, "clear hides history, floating and pending queue while running")
        check(model.isRunning && model.currentCaptureEpoch != oldEpoch, "clear keeps capture running and invalidates old audio")
        check(!model.commitRecognition("late recognition", for: initial[349].id), "late recognition cannot resurrect deleted records")
        check(!model.commitTranslation("late translation", for: initial[348].id), "late translation cannot resurrect deleted records")
        check(TranscriptExport.render(model.jobs).isEmpty, "cleared records excluded from export")
        let oldAudio = store.audio.appendingPathComponent("late.wav")
        try Data([0]).write(to: oldAudio)
        model.acceptCapturedAudio(url: oldAudio, date: Date(), overlap: false, epoch: oldEpoch, settings: preferences)
        check(!FileManager.default.fileExists(atPath: oldAudio.path) && model.visibleJobs.isEmpty, "queued old audio discarded and removed")
        let newAudio = store.audio.appendingPathComponent("new.wav")
        try Data([0]).write(to: newAudio)
        model.acceptCapturedAudio(url: newAudio, date: Date(), overlap: false, epoch: model.currentCaptureEpoch, settings: preferences)
        check(model.visibleJobs.count == 1, "new audio accepted after clear")
        let fresh = model.visibleJobs[0]
        check(model.commitRecognition("Fresh lesson", for: fresh.id), "new recognition accepted")
        check(TranslationHistory.context(before: model.visibleJobs[0], in: model.jobs, limit: 4).isEmpty, "new lesson cannot use deleted context")
        model.undoClear()
        check(model.visibleJobs.count == 351 && !model.canUndoClear, "undo restores all deleted records with new audio retained")
        model.removeRecords([initial[0].id])
        check(!TranscriptExport.render(model.jobs).contains("原文：Source 0\n"), "single-row deletion excluded from TXT")
        let reopened = AppModel(store: store, settings: preferences, startBackgroundWork: false)
        check(reopened.visibleJobs.count == 350 && reopened.deletedCount == 1, "deletion and undo availability persist across restart")
        reopened.undoClear()
        check(reopened.visibleJobs.count == 351, "undo after restart restores last deletion")
        let legacySettings = Data(#"{"fontSize":30,"provider":"自定义大模型","model":"saved-model"}"#.utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: legacySettings)
        check(migrated.floatingFontSize == 30 && migrated.floatingAlwaysOnTop && migrated.floatingOpacity == 1 && migrated.model == "saved-model", "new settings preserve legacy configuration")
        let legacyJob = initial[0]
        let oldJSON = try JSONEncoder().encode(legacyJob)
        check(try! JSONDecoder().decode(AudioJob.self, from: oldJSON).deletedAt == nil, "old jobs migrate without deletedAt")
        let settingsEncoder = JSONEncoder()
        settingsEncoder.outputFormatting = .sortedKeys // Dictionary ordering is not a settings change.
        let configurationBeforeTour = try settingsEncoder.encode(reopened.settings)
        let recordsBeforeTour = reopened.jobs.map(\.id)
        reopened.beginWalkthrough()
        for step in WalkthroughStep.allCases {
            check(reopened.walkthroughStep == step && reopened.section == step.section, "guide visits the matching section")
            if step != .assistant { reopened.moveWalkthrough(1) }
        }
        reopened.moveWalkthrough(-1)
        check(reopened.walkthroughStep == .phone && reopened.section == "手机字幕", "guide can go back")
        reopened.beginWalkthrough()
        check(reopened.walkthroughStep == .meeting, "guide can restart")
        check(try! settingsEncoder.encode(reopened.settings) == configurationBeforeTour && reopened.jobs.map(\.id) == recordsBeforeTour, "guide does not change settings or records")
        let missingKeyExists = try SecretStore.contains("test-missing-assistant-key-\(UUID())")
        check(!missingKeyExists, "metadata lookup safely reports an absent key")
        await model.shutdown(); await reopened.shutdown()
        print("PASS: \(checks) record behavior checks — no real records, audio or API used")
    }
}
