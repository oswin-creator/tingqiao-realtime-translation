import Foundation
import Darwin

/// A single resident model, private pipes, no localhost port or Python runtime.
final class WhisperEngine: @unchecked Sendable {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        func check() throws { lock.lock(); let cancelled = value; lock.unlock(); if cancelled { throw CancellationError() } }
    }
    static let shared = WhisperEngine()
    static var modelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TingQiao/Models/ggml-large-v3-turbo.bin")
    }
    static var installed: Bool { FileManager.default.fileExists(atPath: modelURL.path) }
    private let queue = DispatchQueue(label: "cn.tingqiao.whisper", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffered = Data()
    private var loadedEngine: RecognitionEngine?
    private let executableOverride: URL?
    private let modelOverride: URL?
    init(executable: URL? = nil, model: URL? = nil) { executableOverride = executable; modelOverride = model }

    func prepare(engine: RecognitionEngine = .whisperTurbo) async throws { _ = try await perform(nil, engine: engine) }
    func recognize(url: URL, language: String, retry: Bool = false, engine: RecognitionEngine = .whisperTurbo) async throws -> String {
        try await recognizeResult(url: url, language: language, retry: retry, engine: engine).text
    }
    func recognizeResult(url: URL, language: String, retry: Bool = false, engine: RecognitionEngine = .whisperTurbo,
                         skipSamples: Int = 0, withTimestamps: Bool = false) async throws -> RecognitionResult {
        guard let source = MeetingLanguage(rawValue: language) else { throw BridgeError("识别引擎不支持所选的原文语言。", retryable: false) }
        let request: [String: Any] = ["file": url.path, "language": source.speechCode, "retry": retry,
                                    "skip_samples": max(0, skipSamples), "with_timestamps": withTimestamps]
        return try await perform(JSONSerialization.data(withJSONObject: request), engine: engine)
    }
    func stop() {
        lock.lock(); let old = process; process = nil; lock.unlock()
        if old?.isRunning == true { old?.terminate() }
    }
    private func perform(_ request: Data?, engine: RecognitionEngine) async throws -> RecognitionResult {
        try Task.checkCancellation()
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: RecognitionResult.self) { group in
                group.addTask { try await withCheckedThrowingContinuation { continuation in
                    self.queue.async {
                        do {
                            try cancellation.check()
                            try self.ensureStarted(engine: engine)
                            try cancellation.check()
                            guard let request else { continuation.resume(returning: RecognitionResult(text: "")); return }
                            try self.input?.write(contentsOf: request + Data([10]))
                            let result = try self.readJSON()
                            guard let text = result["text"] as? String else { throw BridgeError("\(engine.shortTitle) 本机识别失败，音频已保留。") }
                            let spans = (result["words"] as? [[String: Any]] ?? []).compactMap { word -> RecognitionSpan? in
                                guard let text = word["text"] as? String, let start = word["start"] as? Double, let end = word["end"] as? Double else { return nil }
                                return RecognitionSpan(text: text, start: start, end: end)
                            }
                            continuation.resume(returning: RecognitionResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), spans: spans))
                        } catch { self.stop(); continuation.resume(throwing: error) }
                    }
                } }
                group.addTask {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    cancellation.cancel()
                    self.stop()
                    throw BridgeError("\(engine.shortTitle) 识别超时，音频已保留。")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } onCancel: { cancellation.cancel(); self.stop() }
    }
    private func ensureStarted(engine: RecognitionEngine) throws {
        lock.lock(); let running = process?.isRunning == true; lock.unlock()
        if running && loadedEngine == engine { return }
        if running { stop() }
        guard let descriptor = LocalModel.find(engine) else { throw BridgeError("请选择本机识别模型。", retryable: false) }
        let model = modelOverride ?? descriptor.fileURL
        if modelOverride == nil, engine == .whisperKomix {
            guard let template = Bundle.main.url(forResource: "whisper-medium-vocab", withExtension: "bin") else {
                throw BridgeError("当前安装缺少 KomixV2 编码表，请使用完整安装包。", retryable: false)
            }
            try LocalModelFiles.repairKomixVocabulary(descriptor, template: template)
        }
        guard modelOverride != nil ? FileManager.default.fileExists(atPath: model.path) : LocalModelFiles.installed(descriptor) else {
            throw BridgeError("请先在语音识别设置中下载或导入 \(engine.rawValue)。", retryable: false)
        }
        let helper = engine == .qwenASR ? "TingQiaoQwen" : "TingQiaoWhisper"
        guard let executable = executableOverride ?? Bundle.main.url(forAuxiliaryExecutable: helper) else { throw BridgeError("当前安装缺少本机识别引擎，请使用完整安装包。", retryable: false) }
        let p = Process(), toEngine = Pipe(), fromEngine = Pipe()
        p.executableURL = executable; p.arguments = [model.path]
        if engine.isWhisper, let detectorModel = Bundle.main.url(forResource: "ggml-silero-v5.1.2", withExtension: "bin") {
            p.arguments?.append(detectorModel.path)
        }
        p.standardInput = toEngine; p.standardOutput = fromEngine; p.standardError = FileHandle.nullDevice
        input = toEngine.fileHandleForWriting; output = fromEngine.fileHandleForReading; buffered.removeAll()
        // Launch and registration are atomic with respect to cancellation.
        lock.lock()
        do { try p.run(); process = p; loadedEngine = engine; lock.unlock() }
        catch { lock.unlock(); throw error }
        toEngine.fileHandleForReading.closeFile(); fromEngine.fileHandleForWriting.closeFile()
        guard try readJSON()["ready"] as? Bool == true else { throw BridgeError("\(engine.shortTitle) 模型无法加载，请重新导入完整模型。", retryable: false) }
    }
    private func readJSON() throws -> [String: Any] {
        while true {
            if let end = buffered.firstIndex(of: 10) {
                let line = buffered.prefix(upTo: end); buffered.removeSubrange(...end)
                guard let result = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw BridgeError("Whisper 返回格式错误。") }
                return result
            }
            guard let output else { throw BridgeError("本机识别通信管道未打开。") }
            // FileHandle.read(upToCount:) can wait for a full buffer on pipes.
            // POSIX read returns the available JSON line immediately.
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            guard count > 0 else { throw BridgeError("本机识别引擎已退出，音频已保留，可重试。") }
            buffered.append(contentsOf: bytes.prefix(count))
            guard buffered.count < 1_048_576 else { throw BridgeError("本机识别返回内容过长。") }
        }
    }
}
