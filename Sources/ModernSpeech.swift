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
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { return "" }
        return try await recognize(language: language) { analyzer, _ in
            try await analyzer.analyzeSequence(from: file)
        }
    }

    static func recognize(buffer: AVAudioPCMBuffer, language: String) async throws -> String {
        try await recognize(language: language) { analyzer, transcriber in
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: buffer.format) else {
                throw BridgeError("无法为系统语音识别准备音频格式。")
            }
            let input = try convert(buffer, to: format)
            let sequence = AsyncStream<AnalyzerInput> { continuation in
                continuation.yield(AnalyzerInput(buffer: input))
                continuation.finish()
            }
            return try await analyzer.analyzeSequence(sequence)
        }
    }

    private static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if input.format == format { return input }
        let frames = ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)
        guard let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames) + 256) else {
            throw BridgeError("无法转换系统语音识别音频。")
        }
        var sent = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if sent { state.pointee = .endOfStream; return nil }
            sent = true; state.pointee = .haveData; return input
        }
        guard status != .error, output.frameLength > 0 else {
            if let error { throw error }
            throw BridgeError("系统语音识别没有收到有效音频。")
        }
        return output
    }

    private static func recognize(language: String, analyze: @escaping @Sendable (SpeechAnalyzer, SpeechTranscriber) async throws -> CMTime?) async throws -> String {
        guard let locale = await locale(language) else { throw BridgeError("系统新识别引擎不支持所选语言。", retryable: false) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let sequence = transcriber.results
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
                        if let last = try await analyze(analyzer, transcriber) {
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
