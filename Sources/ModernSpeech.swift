import Foundation
import Speech
import AVFoundation

// SpeechAnalyzer uses locally installed, system-managed speech assets.
@available(macOS 26.0, *)
enum ModernSpeech {
    static func locale(_ language: String) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language))
    }
    static func assetStatus(_ language: String) async -> AssetInventory.Status? {
        guard let locale = await locale(language) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        return await AssetInventory.status(forModules: [transcriber])
    }
    // Called only from the manual download button (or the standalone test tool).
    static func installLanguage(_ language: String) async throws -> Bool {
        guard let locale = await locale(language) else { return false }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }
    static func recognize(url: URL, language: String) async throws -> String {
        guard let locale = await locale(language) else { throw BridgeError("系统新识别引擎不支持所选语言。", retryable: false) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let sequence = transcriber.results
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return "" }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let resultTask = Task<String, Error> {
            var text = ""
            for try await result in sequence {
                if result.isFinal { text += String(result.text.characters) }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    do {
                        if let last = try await analyzer.analyzeSequence(from: file) {
                            try await analyzer.finalizeAndFinish(through: last)
                        } else { try await analyzer.finalizeAndFinishThroughEndOfInput() }
                        return try await resultTask.value
                    } catch { resultTask.cancel(); await analyzer.cancelAndFinishNow(); throw error }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 25_000_000_000)
                    resultTask.cancel()
                    await analyzer.cancelAndFinishNow()
                    throw BridgeError("本机语音识别超时，片段已保留，将自动重试。")
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw BridgeError("本机识别没有返回结果。") }
                return result
            }
        } onCancel: { resultTask.cancel(); Task { await analyzer.cancelAndFinishNow() } }
    }
}
