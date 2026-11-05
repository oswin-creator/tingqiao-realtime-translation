import Foundation
import AVFoundation
import CoreMedia

final class MockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, value) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(value.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main
struct CoreTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fatalError("FAIL: \(message)") }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("core-\(UUID())")
        let store = try SessionStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let job = AudioJob(id: UUID(), sessionID: UUID(), created: Date(), audioFile: "pending.wav", language: "ko-KR", localRecognition: true)
        try Data([1, 2, 3]).write(to: store.audio.appendingPathComponent(job.audioFile))
        try store.save([job])
        let restored = try store.load()
        check(restored.count == 1 && restored[0].id == job.id && restored[0].language == "ko-KR", "persist and restore pending job")
        try Data([4]).write(to: store.audio.appendingPathComponent("orphan.wav"))
        let orphans = try store.recoverOrphanAudio(known: restored)
        check(orphans.count == 1 && orphans[0].lastPathComponent == "orphan.wav", "recover audio created before metadata journal")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: root.appendingPathComponent("jobs.json"))
        do { _ = try store.load(); fatalError("corrupt journal must throw") } catch { checks += 1 }
        check(try! Data(contentsOf: root.appendingPathComponent("jobs.json")) == corrupt, "corrupt journal is not overwritten on read")

        check(try! TranslationClient.endpoint("https://example.com/v1/").absoluteString == "https://example.com/v1/chat/completions", "base endpoint")
        check(try! TranslationClient.endpoint("https://example.com/chat/completions").path == "/chat/completions", "complete endpoint")
        check(try! TranslationClient.endpoint("http://localhost:1234/v1").port == 1234, "local model endpoint")
        for invalid in ["http://remote.example.com", "https://user:secret@example.com", "https://example.com?key=secret", "not a url"] {
            do { _ = try TranslationClient.endpoint(invalid); fatalError("unsafe endpoint") } catch { checks += 1 }
        }
        check(CaptionText.removingOverlap(previous: "We will review the project schedule", current: "project schedule tomorrow.") == "tomorrow.", "adjacent audio overlap")
        check(CaptionText.removingOverlap(previous: "Yes.", current: "Yes.") == "Yes.", "preserve intentional short repetition")
        check(CaptionText.removingOverlap(previous: "Please review this sentence.", current: "Please review this sentence.") == "Please review this sentence.", "preserve a complete repeated sentence")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockProtocol.self]
        let session = URLSession(configuration: config)
        var settings = AppSettings()
        MockProtocol.handler = { request in
            check(request.url?.host == "translate.googleapis.com", "free translation host")
            return (200, "[[[\"会议九点开始。\",\"The meeting starts at nine.\",null,null,1]],null,\"en\"]")
        }
        var client = TranslationClient(settings: settings, key: "", session: session)
        let free = try await client.translate("The meeting starts at nine.", language: "en-US")
        check(free == "会议九点开始。", "free Google parse")
        settings.provider = .custom; settings.baseURL = "https://example.com/v1"; settings.model = "my-model"
        MockProtocol.handler = { request in
            check(request.url!.path == "/v1/chat/completions", "custom endpoint path")
            check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-test-key", "authorization header")
            return (200, "{\"choices\":[{\"message\":{\"content\":\"项目下周开始。\"}}]}")
        }
        client = TranslationClient(settings: settings, key: "fake-test-key", session: session)
        let translated = try await client.translate("The project starts next week.", language: "en-US")
        check(translated == "项目下周开始。", "custom model parse")
        for (code, retryable) in [(401, false), (429, true), (503, true)] {
            MockProtocol.handler = { _ in (code, "{\"error\":\"fake-test-key\"}") }
            do { _ = try await client.translate("hello", language: "en-US"); fatalError("HTTP error must throw") }
            catch let error as BridgeError { check(error.retryable == retryable && !error.message.contains("fake-test-key"), "HTTP retry policy and secret redaction \(code)") }
        }
        settings.provider = .googleCloud
        settings.targetLanguage = .german
        MockProtocol.handler = { request in
            check(request.value(forHTTPHeaderField: "X-Goog-Api-Key") == "fake-google-key", "Google key header")
            check(!(request.url?.absoluteString.contains("fake-google-key") ?? true), "Google key excluded from URL")
            let body = try requestBody(request)
            check(body["source"] as? String == "zh-TW" && body["target"] as? String == "de", "Google Cloud preserves Chinese variant and selected target")
            return (200, "{\"data\":{\"translations\":[{\"translatedText\":\"Guten Morgen\"}]}}")
        }
        client = TranslationClient(settings: settings, key: "fake-google-key", session: session)
        let cloud = try await client.translate("早安", language: "zh-TW")
        check(cloud == "Guten Morgen", "official Google parse")

        try await contextTests(session: session)
        try audioTests(store: store)
        try await phoneTests()
        print("PASS: \(checks) checks — settings migration, translation context, persistence, audio segmentation, phone pairing")
    }

    @MainActor static func contextTests(session: URLSession) async throws {
        var settings = AppSettings()
        settings.provider = .custom
        settings.baseURL = "https://example.com/v1"
        settings.model = "existing-model"
        settings.language = "ko-KR"
        settings.microphoneID = "existing-microphone"
        settings.localRecognition = false
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        legacy.removeValue(forKey: "useTranslationContext")
        legacy.removeValue(forKey: "translationContextCount")
        legacy.removeValue(forKey: "targetLanguage")
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(migrated.provider == .custom && migrated.model == "existing-model" && migrated.baseURL == settings.baseURL, "preserve existing API preferences on upgrade")
        check(migrated.microphoneID == settings.microphoneID && migrated.language == "ko-KR" && !migrated.localRecognition, "preserve audio and language preferences on upgrade")
        check(migrated.targetLanguage == .simplifiedChinese, "old preferences preserve Simplified Chinese")
        check(migrated.useTranslationContext && migrated.effectiveTranslationContextCount == 4, "enable four preceding segments for legacy preferences")
        settings.translationContextCount = 3
        settings.useTranslationContext = false
        settings.targetLanguage = .french
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        check(!restored.useTranslationContext && restored.translationContextCount == 3 && restored.effectiveTranslationContextCount == 0, "persist context switch and count")
        check(restored.targetLanguage == .french, "persist selected translation language")

        let meeting = UUID(), otherMeeting = UUID()
        var jobs: [AudioJob] = []
        for index in 0..<7 {
            var earlier = AudioJob(id: UUID(), sessionID: meeting, created: Date(timeIntervalSince1970: Double(index)), audioFile: "\(index).wav", language: "en-US", localRecognition: true)
            earlier.original = "Earlier sentence \(index)."
            earlier.translated = index == 6 ? "" : "此前译文 \(index)。"
            earlier.stage = index == 6 ? .translate : .done
            jobs.append(earlier)
        }
        var other = AudioJob(id: UUID(), sessionID: otherMeeting, created: Date(), audioFile: "other.wav", language: "en-US", localRecognition: true)
        other.original = "Secret from another meeting."
        jobs.insert(other, at: 6)
        let silent = AudioJob(id: UUID(), sessionID: meeting, created: Date(), audioFile: "silent.wav", language: "en-US", localRecognition: true)
        jobs.append(silent)
        var current = AudioJob(id: UUID(), sessionID: meeting, created: Date(), audioFile: "current.wav", language: "en-US", localRecognition: true)
        current.original = "Please send it tomorrow."
        jobs.append(current)
        var future = current
        future.id = UUID(); future.original = "Future sentence."
        future.created = .distantPast // completion time and timestamps must not leak later array entries
        future.translated = "未来译文。"
        jobs.append(future)

        let history = TranslationHistory.context(before: current, in: jobs, limit: 4)
        check(history.map(\.original) == (3...6).map { "Earlier sentence \($0)." }, "only the last four earlier segments, in speaking order")
        check(history.last?.translation == nil && history.first?.translation == "此前译文 3。", "use pending original without waiting for its translation")
        check(TranslationHistory.context(before: current, in: jobs, limit: 3).count == 3, "configurable context window")
        check(TranslationHistory.context(before: current, in: jobs, limit: 0).isEmpty, "disabled context")
        check(TranslationHistory.context(before: jobs[0], in: jobs, limit: 4).isEmpty, "first segment has no context")
        check(TranslationHistory.context(before: other, in: jobs, limit: 4).isEmpty, "a new meeting starts with empty context")
        check(TranslationHistory.context(before: current, in: jobs, limit: 99).count == 6, "bounded context window")
        var missing = current; missing.id = UUID()
        check(TranslationHistory.context(before: missing, in: jobs, limit: 4).isEmpty, "unknown job cannot use arbitrary history")

        settings.useTranslationContext = true
        settings.translationContextCount = 4
        MockProtocol.handler = { request in
            let body = try requestBody(request)
            let messages = body["messages"] as! [[String: String]]
            check(messages.count == 2 && messages[0]["role"] == "system" && messages[1]["role"] == "user", "meeting content is data, never extra message roles")
            let payload = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
            let sentHistory = payload["history"] as! [[String: Any]]
            check(sentHistory.compactMap { $0["original"] as? String } == history.map(\.original), "request carries the four correct earlier originals")
            check(sentHistory[0]["translation"] as? String == "此前译文 3。" && sentHistory.last?["translation"] == nil, "request includes only existing earlier translations")
            check(payload["current"] as? String == current.original, "current sentence remains separate from context")
            check(messages[0]["content"]!.contains("只输出 current 对应的译文"), "instruct model to output current translation only")
            check(messages[0]["content"]!.contains("英语翻译为自然、准确的法语"), "custom prompt requests the selected language pair")
            check(!messages[1]["content"]!.contains("Secret from another meeting") && !messages[1]["content"]!.contains("Future sentence"), "no other meeting or later speech in the request")
            return (200, "{\"choices\":[{\"message\":{\"content\":\"Veuillez l’envoyer demain.\"}}]}")
        }
        var client = TranslationClient(settings: settings, key: "test-only", session: session)
        let output = try await client.translate(current.original, language: "en-US", context: history)
        check(output == "Veuillez l’envoyer demain.", "do not append earlier translations to the current caption")

        settings.useTranslationContext = false
        MockProtocol.handler = { request in
            let messages = try requestBody(request)["messages"] as! [[String: String]]
            let payload = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
            check((payload["history"] as! [Any]).isEmpty, "client enforces disabled context even if history is supplied")
            return (200, "{\"choices\":[{\"message\":{\"content\":\"请明天发送它。\"}}]}")
        }
        client = TranslationClient(settings: settings, key: "test-only", session: session)
        _ = try await client.translate(current.original, language: "en-US", context: history)

        settings.provider = .googleFree
        settings.useTranslationContext = true
        MockProtocol.handler = { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            check(items.first(where: { $0.name == "q" })?.value == "明日送ってください。", "Google still receives only the current source text")
            check(items.first(where: { $0.name == "sl" })?.value == "ja" && items.first(where: { $0.name == "tl" })?.value == "es",
                  "pending segment keeps its original target when the user changes settings")
            return (200, "[[[\"Envíelo mañana.\",\"明日送ってください。\"]]]")
        }
        client = TranslationClient(settings: settings, key: "", session: session)
        _ = try await client.translate("明日送ってください。", language: "ja-JP", targetLanguage: .spanish, context: history)
    }

    static func requestBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var output = Data(), bytes = [UInt8](repeating: 0, count: 2048)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count >= 0 else { throw BridgeError("test request stream failed") }
                if count == 0 { break }
                output.append(contentsOf: bytes.prefix(count))
            }
            data = output
        } else { throw BridgeError("missing test request body") }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func makeSample(rate: Double, channels: AVAudioChannelCount, silent: Bool) throws -> CMSampleBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 10))!
        pcm.frameLength = pcm.frameCapacity
        for c in 0..<Int(channels) { for i in 0..<Int(pcm.frameLength) { pcm.floatChannelData![c][i] = silent ? 0 : Float(sin(Double(i) * 0.15) * 0.1) } }
        var sample: CMSampleBuffer?
        let description = format.formatDescription
        var status = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: Int(pcm.frameLength), presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample)
        check(status == noErr && sample != nil, "construct CMSampleBuffer")
        status = CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
        check(status == noErr, "copy PCM to sample")
        CMSampleBufferSetDataReady(sample!)
        return sample!
    }
    static func audioTests(store: SessionStore) throws {
        let segmenter = AudioSegmenter(directory: store.audio, meetingRules: false)
        var emitted: [(URL, Bool)] = []
        segmenter.onSegment = { url, _, overlap in emitted.append((url, overlap)) }
        segmenter.onFailure = { fatalError($0) }
        let silent = try makeSample(rate: 48000, channels: 2, silent: true)
        for _ in 0..<100 { segmenter.append(silent) }; segmenter.flush()
        check(emitted.isEmpty, "silence does not create translation jobs")
        let voiced = try makeSample(rate: 48000, channels: 2, silent: false)
        for _ in 0..<8 { segmenter.append(voiced) }
        segmenter.discard(); segmenter.flush()
        check(emitted.isEmpty, "clear discards partial audio without emitting it")
        // Exercise the actual CMSampleBuffer -> converter -> WAV path with 20 minutes of synthetic PCM.
        for _ in 0..<12000 { segmenter.append(voiced) }; segmenter.flush()
        check(emitted.count >= 240 && emitted.count <= 270, "continuous audio is segmented with bounded buffers")
        check(!emitted[0].1 && emitted[1].1, "forced chunk cuts carry overlap metadata")
        let first = try AVAudioFile(forReading: emitted[0].0)
        check(first.processingFormat.sampleRate == 16000 && first.processingFormat.channelCount == 1, "normalize stereo 48k audio to mono 16k")
        check(first.length >= 79000 && first.length <= 82000, "WAV frames and closed header")
        emitted.forEach { try? FileManager.default.removeItem(at: $0.0) }
        emitted = []
        let mono = try makeSample(rate: 16000, channels: 1, silent: false)
        for _ in 0..<8 { segmenter.append(mono) }; segmenter.flush()
        check(emitted.count == 1, "flush the final short utterance on stop")
    }
    @MainActor static func phoneTests() async throws {
        let server = PhoneServer()
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.onReady = { continuation.resume(returning: $0) }
            server.onError = { continuation.resume(throwing: BridgeError($0)) }
            do { try server.start() } catch { continuation.resume(throwing: error) }
        }
        let pairing = server.pairingURL(port: port)
        let token = String(pairing.split(separator: "#").last!)
        server.publish(PhoneSnapshot(status: "正在收音", running: true, captions: [Caption(id: UUID(), date: Date(), original: "hello", translated: "你好")], pending: 0))
        let url = URL(string: "http://127.0.0.1:\(port)/api/state")!
        var request = URLRequest(url: url); request.timeoutInterval = 5
        let (_, unauthorized) = try await URLSession.shared.data(for: request)
        check((unauthorized as? HTTPURLResponse)?.statusCode == 401, "unauthenticated requests cannot read subtitles")
        request.setValue(token, forHTTPHeaderField: "X-Pairing-Token")
        let (body, authorized) = try await URLSession.shared.data(for: request)
        check((authorized as? HTTPURLResponse)?.statusCode == 200, "paired phone can read subtitles")
        let data = try JSONDecoder().decode(PhoneSnapshot.self, from: body)
        check(data.captions.first?.translated == "你好", "phone receives Chinese subtitles")
        server.publish(PhoneSnapshot(status: "准备就绪", running: false, captions: [], pending: 0))
        let (emptyBody, _) = try await URLSession.shared.data(for: request)
        let empty = try JSONDecoder().decode(PhoneSnapshot.self, from: emptyBody)
        check(empty.captions.isEmpty && empty.pending == 0, "phone snapshot clears previous captions")
        request.setValue("http://attacker.example", forHTTPHeaderField: "Origin")
        let (_, crossOrigin) = try await URLSession.shared.data(for: request)
        check((crossOrigin as? HTTPURLResponse)?.statusCode == 403, "reject cross-origin requests")
        server.stop()
        let newPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.onReady = { continuation.resume(returning: $0) }
            do { try server.start() } catch { continuation.resume(throwing: error) }
        }
        let nextPairing = server.pairingURL(port: newPort)
        check(String(nextPairing.split(separator: "#").last!) != token, "rotate pairing token on restart")
        server.stop()
    }
}
