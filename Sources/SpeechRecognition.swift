import Foundation
import Speech

@MainActor
final class SpeechRecognition {
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var pending: CheckedContinuation<String, Error>?
    private var recognitionID = UUID()

    func reset() {
        finish(.failure(CancellationError()), id: recognitionID)
        task?.cancel(); task = nil; timeout?.cancel(); timeout = nil
        WhisperEngine.shared.stop()
    }

    func authorize(language: String, localOnly: Bool, engine: RecognitionEngine = .apple) async throws {
        if engine == .whisperTurbo { try await WhisperEngine.shared.prepare(); return }
        if try await usesModernSpeech(language: language, localOnly: localOnly) { return }
        let status = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        guard status == .authorized else { throw BridgeError("请在系统设置 → 隐私与安全性 → 语音识别中允许“听桥”。", retryable: false) }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else { throw BridgeError("系统不支持这个语言的语音识别。", retryable: false) }
        if localOnly && !recognizer.supportsOnDeviceRecognition {
            throw BridgeError("这台 Mac 暂未提供所选语言的本机识别模型。可在设置中关闭“只在本机识别”，使用 Apple 在线识别；在线识别可能有限流。", retryable: false)
        }
    }

    private func usesModernSpeech(language: String, localOnly: Bool) async throws -> Bool {
        guard localOnly, #available(macOS 26.0, *),
              let status = await ModernSpeech.assetStatus(language), status != .unsupported else { return false }
        guard status == .installed else {
            let name = MeetingLanguage.sourceName(language)
            throw BridgeError("Apple 本机\(name)资源尚未就绪。请到「翻译设置 → 语音识别」手动准备语言。", retryable: false)
        }
        return true
    }

    func recognize(url: URL, language: String, localOnly: Bool, engine: RecognitionEngine = .apple, retry: Bool = false) async throws -> String {
        if engine == .whisperTurbo { return try await WhisperEngine.shared.recognize(url: url, language: language, retry: retry) }
        if #available(macOS 26.0, *), try await usesModernSpeech(language: language, localOnly: localOnly) {
            return try await ModernSpeech.recognize(url: url, language: language)
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else { throw BridgeError("语音识别语言不可用。", retryable: false) }
        guard recognizer.isAvailable else { throw BridgeError("系统语音识别暂不可用，稍后自动重试。") }
        if localOnly && !recognizer.supportsOnDeviceRecognition { throw BridgeError("请下载系统识别语言，或在设置中关闭“只在本机识别”。", retryable: false) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = localOnly
        request.taskHint = .dictation
        let id = UUID()
        recognitionID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                timeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(BridgeError("语音识别超时，原始音频已保留，将自动重试。")), id: id)
                }
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        if let result, result.isFinal { self?.finish(.success(result.bestTranscription.formattedString), id: id) }
                        else if let error {
                            let ns = error as NSError
                            // No speech is a completed silent segment, not an indefinitely retried failure.
                            if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110 { self?.finish(.success(""), id: id) }
                            else { self?.finish(.failure(BridgeError("识别暂时失败（\(ns.domain) \(ns.code)），已保留音频。")), id: id) }
                        }
                    }
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError()), id: id) } }
    }
    private func finish(_ result: Result<String, Error>, id: UUID) {
        guard recognitionID == id, let continuation = pending else { return }
        pending = nil; timeout?.cancel(); timeout = nil
        task?.cancel(); task = nil
        continuation.resume(with: result)
    }
}
