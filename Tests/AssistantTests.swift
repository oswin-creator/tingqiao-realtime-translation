import Foundation

@main struct AssistantTests {
    static func main() async throws {
        let session = UUID()
        var jobs = (1...19).map { index -> AudioJob in
            var job = AudioJob(id: UUID(), sessionID: session, created: Date(), audioFile: "unused", language: "ko-KR", localRecognition: true)
            job.stage = .done; job.original = "原文 \(index)"; job.translated = "译文 \(index)"
            return job
        }
        jobs[0].sessionID = UUID()
        jobs[18].deletedAt = Date()
        jobs[17].original = ""
        jobs[16].original = String(repeating: "데이터 ", count: 15)
        let context = AssistantContext.recent(from: jobs)
        precondition(context.count == 15 && context.first?.original == "原文 2" && context.last?.original == "原文 16")
        precondition(AssistantContext.recent(from: jobs, session: UUID()).isEmpty)
        precondition(MeetingAssistantClient.shortReply("第一句。第二句。第三句。第四句。", limit: 3) == "第一句。\n第二句。\n第三句。")
        precondition(MeetingAssistantClient.shortReply("<think>思考内容</think>\n[\"一句。两句。\",\"三句。\"]", limit: 2) == "一句。\n两句。")
        precondition(MeetingAssistantClient.shortReply("One answer. Another sentence. A third sentence. A fourth sentence.", limit: 3)?.contains("fourth") == false)
        precondition(MeetingAssistantClient.shortReply(String(repeating: "字", count: 200) + "。", limit: 1) == nil)
        precondition(MeetingAssistantClient.shortReply(#"["对方在问 H1 在哪里，说明此前一直没"#, limit: 3) == nil)
        precondition(MeetingAssistantClient.shortReply(#"["对方在问 H1 在哪里。", "目前只知道"#, limit: 3) == "对方在问 H1 在哪里。")
        precondition(MeetingAssistantClient.shortReply("对方在问 H1 在哪里。现在还没有", limit: 3, truncated: true) == "对方在问 H1 在哪里。")
        precondition(MeetingAssistantClient.shortReply("<think>还在思考", limit: 3, truncated: true) == nil)

        // Five-minute background and fifteen-turn targets are frozen separately.
        let click = Date(timeIntervalSince1970: 1000)
        let timed = (1...40).map { i -> AudioJob in
            var j = AudioJob(id: UUID(), sessionID: session, created: click.addingTimeInterval(Double(i * 10 - 400)), audioFile: "unused", language: "ko-KR", localRecognition: true)
            j.stage = .done; j.original = "片段\(i) " + (0..<140).map { "内容\($0)说明" }.joined(separator: " "); return j
        }
        var future = timed[0]; future.created = click.addingTimeInterval(1); future.original = "未来问题"
        var deleted = timed[0]; deleted.created = click; deleted.deletedAt = click
        var other = timed[0]; other.created = click; other.sessionID = UUID()
        var draft = timed[0]; draft.created = click; draft.stage = .recognize
        let frozen = AssistantContext.snapshot(from: timed + [future, deleted, other, draft], session: session, at: click)
        precondition(frozen.target.count == 15 && frozen.target.first!.original.hasPrefix("片段26 "))
        precondition(frozen.background.count == 16 && frozen.background.first!.original.hasPrefix("片段10 "))
        precondition(frozen.target[0].original.count > 450 && frozen.background[0].original.count > 450)
        precondition(!frozen.background.contains { $0.original == "未来问题" })
        let multi = #"{"answers":[{"turns":[1],"question":"为什么？","answer":["근거가 있습니다.","확인이 필요합니다."],"translation":["已有依据。","还需核对。"]},{"turns":[4,5],"question":"怎样做？","answer":["Check it first.","Then verify it."],"translation":["先检查。","再验证。"]},{"turns":[15],"question":"结果呢？","answer":["아직 확인되지 않았습니다."],"translation":["暂未确认。"]}]}"#
        let allAnswers = try MeetingAssistantClient.answersReply(multi, limit: 2, targetCount: 15)
        precondition(allAnswers.contains("3. 结果呢？") && allAnswers.contains("再验证。") && allAnswers.contains("Then verify it.") && allAnswers.contains("근거가 있습니다.") && allAnswers.contains("译文："))
        for bad in [multi.replacingOccurrences(of: "[15]", with: "[16]"), multi.replacingOccurrences(of: "\"translation\":", with: "\"missing\":"), multi.replacingOccurrences(of: "\"translation\":[\"暂未确认。\"]", with: "\"translation\":[]"), "{\"answers\":["] {
            do { _ = try MeetingAssistantClient.answersReply(bad, limit: 2, targetCount: 15); preconditionFailure("invalid target accepted") } catch {}
        }
        do { _ = try MeetingAssistantClient.answersReply(multi, limit: 2, targetCount: 15, truncated: true); preconditionFailure("partial list accepted") } catch {}

        var settings = AssistantSettings()
        settings.baseURL = "https://mock.example/v1"
        settings.model = "meeting-model"
        settings.effort = .low
        settings.sentences = 2
        settings.modernTokenLimit = true
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantMock.self]
        var client = MeetingAssistantClient(settings: settings, key: "fake-key", session: URLSession(configuration: configuration))
        let answer = try await client.respond(to: .answer, context: context, language: "ko-KR", background: [TranslationContextTurn(original: "仅背景里的旧问题", translation: nil)])
        precondition(answer.text == "1. 测试问题\n첫 번째 답변입니다.\n두 번째 답변입니다.\n译文：第一句。\n第二句。" && answer.reasoning == "独立思考内容。")
        client.settings.model = "target-french"
        let french = try await client.respond(to: .answer, context: context, language: "ko-KR", targetLanguage: .french)
        precondition(french.text.contains("Première réponse.") && french.text.contains("첫 번째 답변입니다."))
        client.settings.model = "explain-recent"
        let explained = try await client.respond(to: .explain, context: context, language: "ko-KR")
        precondition(explained.text == "刚才讨论了数据为什么缺失。")
        client.settings.model = "stream-with-reasoning"
        let progress = ReasoningProgress()
        let streamed = try await client.respond(to: .answer, context: context, language: "ko-KR") { progress.values.append($0) }
        precondition(streamed.text == "1. 测试问题\n첫 번째 답변입니다.\n두 번째 답변입니다.\n译文：第一句。\n第二句。" && streamed.reasoning == "正在分析。然后核对。")
        let progressValues = progress.values
        precondition(progressValues.first == "正在分析。" && progressValues.last == streamed.reasoning)
        client.settings.model = "length-with-sentence"
        let partial = try await client.respond(to: .explain, context: context, language: "ko-KR")
        precondition(partial.text == "第一句。")
        for scenario in ["length-without-text", "length-without-sentence"] {
            client.settings.model = scenario
            do {
                _ = try await client.respond(to: .explain, context: context, language: "ko-KR")
                preconditionFailure("Incomplete result unexpectedly displayed: \(scenario)")
            } catch let error as BridgeError {
                precondition(error.message.contains("达到生成上限"))
            }
        }

        let requestID = "0123456789ab"
        let command = BluetoothWire.assistantRequest("QA:A:\(requestID)")
        precondition(command?.action == .answer && command?.id == requestID)
        precondition(BluetoothWire.assistantRequest("QA:E:bad") == nil)
        let empty = PhoneSnapshot(status: "ready", running: false, captions: [], pending: 0)
        var latest = empty
        latest.assistant = AssistantReply(id: requestID, action: .answer, state: .ready, text: answer.text, reasoning: answer.reasoning)
        let patch = BluetoothWire.update(previous: empty, latest: latest, stream: "test", message: 1)
        precondition(patch?.assistant == latest.assistant && patch?.captions.isEmpty == true)
        precondition(BluetoothWire.update(previous: latest, latest: latest, stream: "test", message: 2) == nil)
        try await phoneTest(id: requestID)
        print("PASS: meeting context, request and output limits, Bluetooth command and reply, authenticated Wi-Fi and duplicate suppression")
    }

    static func phoneTest(id: String) async throws {
        let server = PhoneServer()
        defer { server.stop() }
        let calls = CallCounter()
        server.onAssistantRequest = { request, deliver in
            calls.increment()
            deliver(AssistantReply(id: request.id, action: request.action, state: .ready, text: "局域网测试回复。"))
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.onReady = { continuation.resume(returning: $0) }
            server.onError = { continuation.resume(throwing: BridgeError($0)) }
            do { try server.start() } catch { continuation.resume(throwing: error) }
        }
        let token = String(server.pairingURL(port: port).split(separator: "#").last!)
        let base = "http://127.0.0.1:\(port)/api/assistant/"
        var request = URLRequest(url: URL(string: base + "explain/" + id)!, timeoutInterval: 5)
        request.httpMethod = "POST"
        func status(_ response: URLResponse) -> Int { (response as! HTTPURLResponse).statusCode }
        let (_, unauthorized) = try await URLSession.shared.data(for: request)
        precondition(status(unauthorized) == 401 && calls.count == 0)
        request.setValue(token, forHTTPHeaderField: "X-Pairing-Token")
        request.setValue("http://unrelated.example", forHTTPHeaderField: "Origin")
        let (_, forbidden) = try await URLSession.shared.data(for: request)
        precondition(status(forbidden) == 403 && calls.count == 0)
        request.setValue(nil, forHTTPHeaderField: "Origin")
        let (_, accepted) = try await URLSession.shared.data(for: request)
        let (_, duplicate) = try await URLSession.shared.data(for: request)
        precondition(status(accepted) == 202 && status(duplicate) == 202 && calls.count == 1)
        request.url = URL(string: base + id)!
        request.httpMethod = "GET"
        let (body, response) = try await URLSession.shared.data(for: request)
        let reply = try JSONDecoder().decode(AssistantReply.self, from: body)
        precondition(status(response) == 200 && reply.state == .ready && reply.text == "局域网测试回复。")
    }
}

private final class ReasoningProgress {
    @MainActor var values: [String] = []
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}

private final class AssistantMock: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.path == "/v1/chat/completions" && request.httpMethod == "POST")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-key")
        let stream = request.httpBodyStream
        stream?.open(); defer { stream?.close() }
        var payload = request.httpBody ?? Data()
        if let stream {
            var bytes = [UInt8](repeating: 0, count: 2048)
            var count = stream.read(&bytes, maxLength: bytes.count)
            while count > 0 { payload.append(contentsOf: bytes.prefix(count)); count = stream.read(&bytes, maxLength: bytes.count) }
        }
        let body = try! JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        let snapshot = try! JSONDecoder().decode(AssistantContext.Snapshot.self, from: Data(messages[1]["content"]!.utf8))
        let context = snapshot.target
        if body["model"] as? String == "meeting-model" { precondition(snapshot.background.map(\.original) == ["仅背景里的旧问题"]) }
        precondition(body["reasoning_effort"] as? String == "low" && [4096, 16384].contains(body["max_completion_tokens"] as? Int ?? 0))
        precondition(body["stream"] as? Bool == true)
        let instructions = messages[0]["content"]!
        if instructions.contains("逐个回答") {
            precondition(body["max_completion_tokens"] as? Int == 16384)
            precondition(instructions.contains("所有问题") && instructions.contains("background 仅") && instructions.contains("提问原文的实际语言") && instructions.contains("translation") && instructions.contains("translation 单独最多 2") && instructions.contains("turns"))
        } else {
            precondition(body["max_completion_tokens"] as? Int == 4096)
            precondition(instructions.contains("只帮助确定指代和上下文") && instructions.contains("最多 2 个完整短句"))
        }
        if body["model"] as? String == "target-french" { precondition(instructions.contains("另附回答的法语翻译")) }
        precondition(context.count == 15 && context.last?.original == "原文 16")
        let isStream = body["model"] as? String == "stream-with-reasoning"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": isStream ? "text/event-stream" : "application/json"])!
        let translations = body["model"] as? String == "target-french" ? ["Première réponse.", "Deuxième réponse."] : ["第一句。", "第二句。"]
        let answerJSON = String(decoding: try! JSONSerialization.data(withJSONObject: ["answers": [["turns": [1], "question": "测试问题", "answer": ["첫 번째 답변입니다.", "두 번째 답변입니다."], "translation": translations]]]), as: UTF8.self)
        let payloadText: String
        switch body["model"] as? String {
        case "explain-recent": payloadText = #"{"choices":[{"finish_reason":"stop","message":{"content":"刚才讨论了数据为什么缺失。"}}]}"#
        case "length-with-sentence": payloadText = #"{"choices":[{"finish_reason":"length","message":{"content":"第一句。第二句还没"}}]}"#
        case "length-without-text": payloadText = #"{"choices":[{"finish_reason":"length","message":{"content":null}}]}"#
        case "length-without-sentence": payloadText = #"{"choices":[{"finish_reason":"length","message":{"content":"[\"还没写完"}}]}"#
        case "stream-with-reasoning":
            payloadText = [
                #"{"choices":[{"delta":{"reasoning_content":"正在分析。"}}]}"#,
                #"{"choices":[{"delta":{"reasoning_content":"然后核对。"}}]}"#,
                String(decoding: try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": answerJSON], "finish_reason": "stop"]]]), as: UTF8.self),
                "[DONE]"
            ].map { "data: " + $0 + "\n\n" }.joined()
        default: payloadText = String(decoding: try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": answerJSON, "reasoning_content": "独立思考内容。"]]]]), as: UTF8.self)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payloadText.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
