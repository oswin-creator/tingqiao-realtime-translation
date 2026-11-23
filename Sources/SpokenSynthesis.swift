import Foundation
import Darwin
import AVFoundation

struct SpokenClip: Sendable {
    let pcm: Data
    let sampleRate: Int
    var textRange: NSRange? = nil
    var duration: Double { Double(pcm.count / 2) / Double(sampleRate) }
}

enum SpokenTempo {
    static func expectedDuration(_ text: String) -> Double {
        var syllables = 0.0
        var western = ""
        var pauses = 0.0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x9FFF, 0x20000...0x323AF: syllables += 1; western += " "
            case 0xAC00...0xD7A3: syllables += 0.85; western += " "
            case 0x3040...0x30FF: syllables += 0.7; western += " "
            default:
                western.unicodeScalars.append(scalar)
                if "，。！？；,.!?;".unicodeScalars.contains(scalar) { pauses += 0.12 }
            }
        }
        let pattern = #"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*|[0-9]+"#
        let expression = try! NSRegularExpression(pattern: pattern)
        let words = expression.matches(in: western, range: NSRange(western.startIndex..., in: western))
        var seconds = syllables / 4.2
        for match in words {
            guard let range = Range(match.range, in: western) else { continue }
            let word = western[range]
            if word.allSatisfy(\.isNumber) { seconds += max(0.4, Double(word.count) * 0.2) }
            else if word.count > 1 && word == word.uppercased() { seconds += Double(word.count) * 0.22 }
            else { seconds += max(0.38, Double(word.count) / 15) }
        }
        return max(0.6, seconds + min(1.2, pauses))
    }

    static func correction(text: String, duration: Double) -> Double {
        let upper = expectedDuration(text) * 1.2
        let ratio = duration / upper
        return ratio > 1.15 ? min(1.8, ratio) : 1
    }

    static func compress(_ clip: SpokenClip, rate: Double) throws -> SpokenClip {
        guard rate > 1.01 else { return clip }
        let engine = AVAudioEngine(), node = AVAudioPlayerNode(), tempo = AVAudioUnitTimePitch()
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(clip.sampleRate), channels: 1)!
        engine.attach(node)
        engine.attach(tempo)
        engine.connect(node, to: tempo, format: format)
        engine.connect(tempo, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        tempo.rate = Float(min(1.8, rate))
        tempo.pitch = 0
        let frames = clip.pcm.count / 2
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = input.floatChannelData?[0],
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw BridgeError("无法准备变速音频。")
        }
        input.frameLength = AVAudioFrameCount(frames)
        clip.pcm.withUnsafeBytes { bytes in
            for index in 0..<frames {
                samples[index] = Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
            }
        }
        node.scheduleBuffer(input)
        engine.prepare()
        try engine.start()
        defer { node.stop(); engine.stop() }
        node.play()
        let limit = Int(ceil(Double(frames) / Double(tempo.rate))) + clip.sampleRate / 3
        var rendered = [Int16]()
        rendered.reserveCapacity(limit)
        var stalls = 0
        while rendered.count < limit {
            let count = AVAudioFrameCount(min(4096, limit - rendered.count))
            let status = try engine.renderOffline(count, to: output)
            guard status == .success, let values = output.floatChannelData?[0], output.frameLength > 0 else {
                stalls += 1
                guard stalls < 10 else { throw BridgeError("音频变速未能完成。") }
                continue
            }
            stalls = 0
            for index in 0..<Int(output.frameLength) {
                let value = values[index]
                rendered.append(value.isFinite ? Int16((min(1, max(-1, value)) * 32767).rounded()) : 0)
            }
        }
        if let last = rendered.lastIndex(where: { $0 != 0 }) {
            rendered.removeSubrange(min(rendered.count, last + 1 + clip.sampleRate / 50)..<rendered.count)
        }
        return SpokenClip(pcm: rendered.withUnsafeBytes { Data($0) }, sampleRate: clip.sampleRate, textRange: clip.textRange)
    }
}

enum SpokenSynthesisFailure: LocalizedError {
    case incomplete(String)
    case invalidAudio

    var diagnosticCode: Int {
        switch self {
        case .incomplete("max_seconds"): return 2
        case .incomplete: return 3
        case .invalidAudio: return 4
        }
    }

    var errorDescription: String? {
        switch self {
        case .incomplete: return "这段译文没有合成完整。"
        case .invalidAudio: return "播报引擎未能生成有效音频。"
        }
    }
}

struct SpokenGenerationError: LocalizedError {
    let remainingText: String
    let cause: Error
    var errorDescription: String? { cause.localizedDescription }
}

protocol SpokenSynthesizing: AnyObject, Sendable {
    func stream(_ text: String, voice: String, language: MeetingLanguage, id: UUID?) -> AsyncThrowingStream<SpokenClip, Error>
    func stop()
}

struct SpokenPauseTrimmer {
    private let frameBytes: Int
    private var remainder = Data()
    private var quiet = Data()
    private var heardSpeech = false

    init(sampleRate: Int) {
        frameBytes = (sampleRate / 100) * 2
    }

    mutating func consume(_ pcm: Data) -> Data {
        let input = remainder + pcm
        var result = Data()
        let wholeBytes = input.count - input.count % frameBytes
        for start in stride(from: 0, to: wholeBytes, by: frameBytes) {
            append(input.subdata(in: start..<(start + frameBytes)), to: &result)
        }
        remainder = Data(input.dropFirst(wholeBytes))
        return result
    }

    mutating func finish() -> Data {
        var result = Data()
        if !remainder.isEmpty { append(remainder, to: &result) }
        result.append(quiet.prefix(frameBytes * 18))
        return result
    }

    private mutating func append(_ frame: Data, to output: inout Data) {
        if Self.isQuiet(frame) {
            quiet.append(frame)
            let head = heardSpeech ? frameBytes * 18 : 0
            let limit = head + frameBytes * 10
            if quiet.count > limit {
                quiet.removeSubrange(head..<(head + quiet.count - limit))
            }
        } else {
            output.append(quiet)
            quiet.removeAll(keepingCapacity: true)
            output.append(frame)
            heardSpeech = true
        }
    }

    private static func isQuiet(_ frame: Data) -> Bool {
        frame.withUnsafeBytes { bytes in
            var power: Int64 = 0
            let count = bytes.count / 2
            for index in 0..<count {
                let value = Int64(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                if abs(value) > 260 { return false }
                power += value * value
            }
            return power <= Int64(count) * 130 * 130
        }
    }
}

final class SpokenSynthesis: SpokenSynthesizing, @unchecked Sendable {
    private final class ProgressClock: @unchecked Sendable {
        private let lock = NSLock()
        private var last = ProcessInfo.processInfo.systemUptime
        private var pending = ""
        func touch() { lock.lock(); last = ProcessInfo.processInfo.systemUptime; lock.unlock() }
        var idle: Double { lock.lock(); defer { lock.unlock() }; return ProcessInfo.processInfo.systemUptime - last }
        func setRemaining(_ text: String) { lock.lock(); pending = text; lock.unlock() }
        var remaining: String { lock.lock(); defer { lock.unlock() }; return pending }
    }
    private let engine: SpokenEngine
    private let executable: URL?
    private let directory: URL
    private let diagnostics: Diagnostics?
    private var lineID: UUID?
    private let queue = DispatchQueue(label: "cn.tingqiao.spoken-synthesis", qos: .utility)
    private let lock = NSLock()
    private var process: Process?
    private var closed = false
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffered = Data()
    private var sampleRate = 0
    private var progressClock: ProgressClock?

    init(engine: SpokenEngine, executable: URL? = nil, directory: URL? = nil,
         diagnostics: Diagnostics? = nil) {
        self.engine = engine
        self.executable = executable ?? Bundle.main.url(forAuxiliaryExecutable: engine.isQwen ? "TingQiaoQwenTTS" : "TingQiaoSherpaTTS")
        self.directory = directory ?? SpokenModelFiles.directory(engine)
        self.diagnostics = diagnostics
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        closed = true
        let child = process
        process = nil
        lock.unlock()
        if let child, child.isRunning { child.terminate() }
    }

    func synthesize(_ text: String, voice: String, language: MeetingLanguage) async throws -> SpokenClip {
        var pcm = Data()
        var rate = 0
        for try await chunk in stream(text, voice: voice, language: language) {
            rate = chunk.sampleRate
            pcm.append(chunk.pcm)
        }
        guard rate > 0, !pcm.isEmpty else { throw BridgeError("这段译文没有可播报的音频。") }
        return SpokenClip(pcm: pcm, sampleRate: rate)
    }

    func stream(_ text: String, voice: String, language: MeetingLanguage, id: UUID? = nil) -> AsyncThrowingStream<SpokenClip, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(text, voice: voice, language: language, id: id) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { state in
                if case .cancelled = state { task.cancel() }
            }
        }
    }

    private func run(_ text: String, voice: String, language: MeetingLanguage, id: UUID?,
                     emit: @escaping @Sendable (SpokenClip) -> Void) async throws {
        let progress = ProgressClock()
        progress.setRemaining(text)
        do { try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        self.queue.async {
                            self.progressClock = progress
                            self.lineID = id
                            defer { self.progressClock = nil }
                            do {
                                try self.generate(text, voice: voice, language: language, emit: emit)
                                continuation.resume()
                            }
                            catch { self.stop(); continuation.resume(throwing: error) }
                        }
                    }
                }
                group.addTask {
                    let started = ProcessInfo.processInfo.systemUptime
                    while true {
                        try await Task.sleep(for: .seconds(1))
                        if progress.idle > 30 || ProcessInfo.processInfo.systemUptime - started > 180 {
                            self.stop()
                            throw BridgeError("播报生成中断，可以重试或跳到最新译文。")
                        }
                    }
                }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } onCancel: { self.stop() }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SpokenGenerationError(remainingText: progress.remaining, cause: error)
        }
    }

    private func start() throws {
        try ensureOpen()
        if sampleRate > 0 { return }
        guard engine.supportedSystem, let executable else { throw BridgeError("当前系统或安装包缺少此播报引擎。") }
        let child = Process(), requests = Pipe(), replies = Pipe()
        child.executableURL = executable
        if engine.isQwen {
            child.arguments = ["worker", directory.appendingPathComponent(engine.modelName).path, "--no-warmup", "--threads", "2"]
        } else {
            child.arguments = [engine.rawValue, directory.path, engine.isMelo ? "4" : "2"]
        }
        child.standardInput = requests
        child.standardOutput = replies
        child.standardError = FileHandle.nullDevice
        lock.lock()
        do {
            guard !closed else { throw CancellationError() }
            try child.run()
            process = child
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        requests.fileHandleForReading.closeFile()
        replies.fileHandleForWriting.closeFile()
        input = requests.fileHandleForWriting
        _ = fcntl(requests.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output = replies.fileHandleForReading
        let ready = try readMessage()
        guard ready["type"] as? String == "ready", let model = ready["model"] as? [String: Any],
              let rate = model["sample_rate"] as? Int, (8_000...48_000).contains(rate) else {
            throw BridgeError("播报模型无法加载，请检查模型文件。")
        }
        sampleRate = rate
    }

    private func generate(_ text: String, voice: String, language: MeetingLanguage, emit: (SpokenClip) -> Void) throws {
        let mandarin = engine.isQwen && language.speechCode == "zh"
        let sentences = Self.speechParts(text, melo: engine.isMelo)
        var offset = 0
        for (index, sentence) in sentences.enumerated() {
            progressClock?.setRemaining(sentences[index...].joined())
            let chineseText = language == .traditionalChinese
                ? sentence.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? sentence
                : sentence
            let spokenText = mandarin ? Self.mandarinSpeechText(chineseText) : chineseText
            var clip: SpokenClip
            do {
                clip = try generatePart(spokenText, voice: voice, language: language, retry: false)
            } catch {
                try ensureOpen()
                guard engine.isQwen else { throw error }
                diagnostics?.record(.spokenRetry, id: lineID, value: sentence.count,
                                    code: (error as? SpokenSynthesisFailure)?.diagnosticCode ?? 0)
                resetWorker()
                var pcm = Data()
                var rate = 0
                for fragment in Self.parts(spokenText, limit: 24) {
                    let recovered = try generatePart(fragment, voice: voice, language: language, retry: true)
                    rate = recovered.sampleRate
                    pcm.append(recovered.pcm)
                }
                clip = SpokenClip(pcm: pcm, sampleRate: rate)
            }
            clip.textRange = NSRange(location: offset, length: sentence.utf16.count)
            offset += sentence.utf16.count
            emit(clip)
            progressClock?.setRemaining(sentences.dropFirst(index + 1).joined())
        }
    }

    private func ensureOpen() throws {
        lock.lock()
        defer { lock.unlock() }
        if closed { throw CancellationError() }
    }

    private func resetWorker() {
        lock.lock()
        let child = process
        process = nil
        lock.unlock()
        if let child, child.isRunning { child.terminate() }
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        sampleRate = 0
        buffered.removeAll()
    }

    private func generatePart(_ sentence: String, voice: String, language: MeetingLanguage, retry: Bool) throws -> SpokenClip {
            try start()
            let id = UUID().uuidString
            var pauses = engine.isQwen && language.speechCode == "zh" ? SpokenPauseTrimmer(sampleRate: sampleRate) : nil
            let request = Self.request(engine: engine, id: id, text: sentence, voice: voice, language: language, retry: retry)
            try input?.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
            var pcm = Data()
            var received = 0
            var sequence = 0
            while true {
                let message = try readMessage()
                guard message["id"] as? String == id else { throw BridgeError("播报引擎返回了无效内容。") }
                let type = message["type"] as? String
                if type == "end" {
                    let stop = message["stop"] as? String ?? "unknown"
                    diagnostics?.record(.spokenPart, id: lineID, value: received / 2 * 1000 / sampleRate,
                                        code: stop == "complete" ? 0 : stop == "max_seconds" ? 2 : 3)
                    guard stop == "complete" else { throw SpokenSynthesisFailure.incomplete(stop) }
                    guard message["samples"] as? Int == received / 2, received > 0 else {
                        throw SpokenSynthesisFailure.invalidAudio
                    }
                    break
                }
                if type == "progress" { continue }
                guard type == "chunk", message["seq"] as? Int == sequence,
                      let encoded = message["pcm"] as? String, let samples = Data(base64Encoded: encoded),
                      !samples.isEmpty, samples.count.isMultiple(of: 2),
                      received + samples.count <= sampleRate * 2 * 90 else {
                    throw SpokenSynthesisFailure.invalidAudio
                }
                pcm.append(pauses?.consume(samples) ?? samples)
                received += samples.count
                sequence += 1
            }
            if let tail = pauses?.finish() { pcm.append(tail) }
            guard !pcm.isEmpty else { throw SpokenSynthesisFailure.invalidAudio }
            let clip = SpokenClip(pcm: pcm, sampleRate: sampleRate)
            if engine.isQwen {
                let factor = SpokenTempo.correction(text: sentence, duration: clip.duration)
                if factor > 1 {
                    let adjusted = try SpokenTempo.compress(clip, rate: factor)
                    diagnostics?.record(.spokenTempo, id: lineID, value: Int(factor * 1000))
                    return adjusted
                }
            }
            return clip
    }

    static func request(engine: SpokenEngine, id: String, text: String, voice: String, language: MeetingLanguage, retry: Bool = false) -> [String: Any] {
        var request: [String: Any] = ["type": "synthesize", "id": id, "text": text, "voice": voice]
        if engine.isQwen {
            request["language"] = language.speechCode
            request["seed"] = retry ? 43 : 42
            request["temperature"] = retry ? 0.9 : engine == .qwen17 ? 0.7 : 0.4
            request["top_k"] = retry ? 50 : engine == .qwen17 ? 30 : 8
            request["code_predictor_temperature"] = retry ? 0.9 : engine == .qwen17 ? 0.7 : 0.5
            request["code_predictor_top_k"] = retry ? 50 : engine == .qwen17 ? 30 : 12
        }
        if engine == .qwen17 {
            request["instructions"] = language.speechCode == "zh"
                ? "用平静自然的标准普通话说话，语气平稳，简短停顿。"
                : "Speak calmly and naturally with a neutral expression and brief pauses."
        }
        if engine.isQwen { request["max_seconds"] = min(60, max(20, Double(text.count) * 0.8)) }
        return request
    }

    static func mandarinSpeechText(_ text: String) -> String {
        text.replacingOccurrences(of: #"[！!]*[？?][？！!?]+|[！!]+[？?]"#, with: "？", options: .regularExpression)
            .replacingOccurrences(of: #"[！!]{2,}|！"#, with: "。", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\p{Han})…+(?=\s*[。？！!?])"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\p{Han})…+(?=\s*$)"#, with: "。", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\p{Han})…+"#, with: "，", options: .regularExpression)
    }

    static func parts(_ text: String, limit: Int = 180) -> [String] {
        var remaining = text[...]
        var pieces: [String] = []
        while remaining.count > limit {
            let prefix = remaining.prefix(limit)
            let boundary = prefix.dropFirst(limit / 2).lastIndex { $0.isWhitespace || "，。！？；、,.!?;".contains($0) }
            let end = boundary.map { remaining.index(after: $0) } ?? prefix.endIndex
            pieces.append(String(remaining[..<end]))
            remaining = remaining[end...]
        }
        if !remaining.isEmpty { pieces.append(String(remaining)) }
        return pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func meloParts(_ text: String) -> [String] {
        let compact = text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7A3).contains($0.value) }
        let firstLimit = compact ? 32 : 96
        guard text.count > firstLimit else { return [text] }
        let first = parts(text, limit: firstLimit)[0]
        return [first] + parts(String(text.dropFirst(first.count)), limit: compact ? 64 : 160)
    }

    static func speechParts(_ text: String, melo: Bool) -> [String] {
        var sentences: [String] = []
        var start = text.startIndex
        var index = start
        while index < text.endIndex {
            var next = text.index(after: index)
            let character = text[index]
            let boundary = "。！？!?\n".contains(character)
                || (character == "." && (next == text.endIndex || text[next].isWhitespace))
            if boundary {
                while next < text.endIndex, "。！？!?\n”’\"')）】」』".contains(text[next]) {
                    next = text.index(after: next)
                }
                sentences.append(String(text[start..<next]))
                start = next
            }
            index = next
        }
        if start < text.endIndex { sentences.append(String(text[start...])) }
        let chunks = sentences.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [$0] : melo ? meloParts($0) : parts($0, limit: 48)
        }
        var result: [String] = []
        var whitespace = ""
        for chunk in chunks {
            if chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { whitespace += chunk }
            else { result.append(whitespace + chunk); whitespace = "" }
        }
        if !whitespace.isEmpty, !result.isEmpty { result[result.count - 1] += whitespace }
        return result
    }

    private func readMessage() throws -> [String: Any] {
        while true {
            if let end = buffered.firstIndex(of: 10) {
                let line = buffered.prefix(upTo: end)
                buffered.removeSubrange(...end)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw BridgeError("播报引擎返回了无效内容。")
                }
                if message["type"] as? String == "chunk" || message["type"] as? String == "ready" { progressClock?.touch() }
                return message
            }
            guard let output else { throw BridgeError("播报引擎未启动。") }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BridgeError("播报引擎已退出。") }
            buffered.append(contentsOf: bytes.prefix(count))
            guard buffered.count <= 1_048_576 else { throw BridgeError("播报引擎返回的内容过长。") }
        }
    }
}
