import Foundation
import AVFoundation
import CoreMedia

@main struct MeetingTests {
    static var checks = 0
    static func check(_ result: @autoclosure () -> Bool, _ reason: String) { checks += 1; precondition(result(), reason) }
    @MainActor static func main() async throws {
        check(!MeetingRules.shouldEnd(duration: 8, silence: 0.69, complete: true), "short teacher pauses continue")
        check(MeetingRules.shouldEnd(duration: 8, silence: 0.7, complete: true), "complete sentence submits after 0.7 seconds")
        check(!MeetingRules.shouldEnd(duration: 8, silence: 1.49, complete: false), "unfinished sentence waits for more audio")
        check(MeetingRules.shouldEnd(duration: 8, silence: 1.5, complete: false), "unfinished sentence submits after 1.5 seconds")
        let koreanEndings: [(String, Bool)] = [
            ("감사합니다.", true), ("다음 시간에 만나요", true), ("다음으로 넘어갈까요", true),
            ("결과가 좋네요", true), ("이미 아시잖아요", true), ("이게 중요하거든요", true),
            ("맞습니까", true), ("지금 갑니까", true), ("다 같이 봅시다", true),
            ("‘결과가 좋습니다.’", true), ("지금 뭐라고요?", true), ("어떤 문제가 있는데요？", true),
            ("시간이 부족하지만.", false), ("이게 맞으면.", false), ("확인하고 나서.", false),
            ("질문이 있는데요.", false), ("시간이 없으니까.", false), ("이걸 한다고요.", false),
            ("자료를 읽고요.", false), ("이건 좋네요…", false), ("다음에 해요,", false),
            ("바다", false), ("요", false)
        ]
        for (sample, complete) in koreanEndings {
            check(MeetingRules.looksComplete(sample, language: "ko-KR") == complete, "Korean sentence ending: \(sample)")
        }
        check(!MeetingRules.looksComplete("This happens because.", language: "en-US"), "punctuation on unfinished English link")
        var stability = DraftStability()
        _ = stability.update("The report is due")
        _ = stability.update("The report is due tomorrow")
        _ = stability.update("The report is due tomorrow.")
        check(stability.stable == "The report is ", "only complete repeated words stabilize")

        check(stability.update("A report is due tomorrow.").hasPrefix("The report is "), "stable preview prefix does not flicker on later guesses")

        let suite = "cn.tingqiao.tests.trust.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let trust = BluetoothTrust(defaults: defaults)
        let first = try trust.pair(centralID: "phone-A"), second = try trust.pair(centralID: "phone-B")
        check(first.token.count == 16 && first.token != second.token, "distinct strong credentials fit 20-byte BLE write")
        let repeated = try trust.pair(centralID: "phone-A")
        check(repeated.id == first.id, "AUTH retry does not create duplicate phone")
        let restored = BluetoothTrust(defaults: defaults)
        check(restored.peers.count == 2 && restored.computerID == trust.computerID, "multiple paired devices survive Mac restart")
        restored.remove(first.id)
        check(restored.find(first.token) == nil && restored.find(second.token) != nil, "revoke only the selected phone")
        check(restored.find("invalid") == nil, "unknown token rejected")

        let old = Data("{\"localRecognition\":false,\"language\":\"ko-KR\"}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        check(settings.recognitionEngine == .apple && !settings.localRecognition, "legacy engine preferences preserved")
        let oldJob = AudioJob(id: UUID(), sessionID: UUID(), created: Date(), audioFile: "old.wav", language: "ko-KR", localRecognition: false)
        var jobJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(oldJob)) as! [String: Any]
        jobJSON.removeValue(forKey: "recognitionEngine")
        let migrated = try JSONDecoder().decode(AudioJob.self, from: JSONSerialization.data(withJSONObject: jobJSON))
        check(migrated.recognitionEngine == nil, "old queued recordings remain Apple jobs")

        try segmentationTests()
        try await indexTests()
        print("PASS: \(checks) meeting checks — sentence timing, continuous PCM, drafts, trust persistence, provider isolation")
    }
    static func segmentationTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-meeting-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let segmenter = AudioSegmenter(directory: root.appendingPathComponent("Audio"))
        var windows: [SpeechWindow] = []
        segmenter.onWindow = { windows.append($0) }
        func append(seconds: Double, silent: Bool) throws {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
            pcm.frameLength = 1600
            for i in 0..<1600 { pcm.floatChannelData![0][i] = silent ? 0 : Float(sin(Double(i)*0.15)*0.1) }
            var buffer: CMSampleBuffer?
            let result = CMAudioSampleBufferCreateWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription, sampleCount: 1600, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &buffer)
            precondition(result == noErr)
            _ = CMSampleBufferSetDataBufferFromAudioBufferList(buffer!, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
            for _ in 0..<Int((seconds * 10).rounded()) { segmenter.append(buffer!) }
        }
        try append(seconds: 6, silent: false)
        check(windows.contains { !$0.isFinal } && !windows.contains { $0.isFinal }, "temporary subtitle before sentence commit")
        let firstID = windows[0].id
        segmenter.setComplete(MeetingRules.looksComplete("다음으로 넘어갈까요", language: "ko-KR"), id: firstID)
        try append(seconds: 0.6, silent: true)
        check(!windows.contains { $0.isFinal }, "short pause creates no final translation")
        try append(seconds: 0.2, silent: true)
        check(windows.filter { $0.isFinal }.count == 1 && windows.last?.id == firstID, "final window replaces its draft identity")
        try append(seconds: 120, silent: true)
        check(windows.filter { $0.isFinal }.count == 1, "silence creates no new final jobs")
        try append(seconds: 40, silent: false); segmenter.flush()
        let final = windows.filter(\.isFinal)
        check(final.count == 6, "unbroken speech forced into bounded windows plus final tail")
        check(final.allSatisfy { $0.duration <= 10.11 }, "never accumulates more than a 10-second window")
        check(final.dropFirst(2).contains { $0.overlap }, "hard cuts carry audio overlap")
        try append(seconds: 1200, silent: false); segmenter.flush()
        check(windows.filter(\.isFinal).count > 120 && windows.filter(\.isFinal).allSatisfy { $0.duration < 10.11 }, "20-minute continuous input stays bounded without dropping the stream")
        for w in final { let file = try AVAudioFile(forReading: w.url); check(file.length > 0, "final WAV fully written before journal") }

        windows.removeAll()
        try append(seconds: 6.8, silent: false)
        try append(seconds: 0.1, silent: true)
        check(!windows.contains { $0.isFinal }, "a short pause alone does not cut before the long-speech target")
        try append(seconds: 0.2, silent: true)
        let naturalCut = windows.first { $0.isFinal }
        check(naturalCut != nil && abs((naturalCut?.duration ?? 0) - 7.0) < 0.11, "at seven seconds prefer the recent natural pause")
        try append(seconds: 1.4, silent: false)
        segmenter.flush()
        let finalDuration = windows.filter(\.isFinal).map(\.duration).reduce(0, +)
        check(abs(finalDuration - 8.5) < 0.11, "natural cut preserves audio after the pause")

        let cadence = AudioSegmenter(directory: root.appendingPathComponent("Cadence"))
        var previews: [SpeechWindow] = []
        cadence.onWindow = { if !$0.isFinal { previews.append($0) } }
        let block = [Float](repeating: 0.1, count: 1600)
        check(MeetingRules.previewInterval == 4, "preview cadence is four seconds independent of system power mode")
        for _ in 0..<39 { cadence.appendPCM(block) }
        check(previews.isEmpty, "no preview before four seconds")
        cadence.appendPCM(block)
        check(previews.count == 1 && abs(previews[0].duration - 4) < 0.001, "first preview triggers at four seconds")
        for _ in 0..<39 { cadence.appendPCM(block) }
        check(previews.count == 1, "next preview waits another four seconds")
        cadence.appendPCM(block)
        check(previews.count == 2 && abs(previews[1].duration - 8) < 0.001, "second preview triggers at eight seconds")
        cadence.flush()
    }
    @MainActor static func indexTests() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [IndexMock.self]
        var settings = AppSettings(); settings.provider = .indexTranslate
        settings.targetLanguage = .japanese
        settings.baseURL = "https://original-private-provider.invalid/v1"; settings.model = "keep-me"
        let client = TranslationClient(settings: settings, key: "DO-NOT-LEAK", session: URLSession(configuration: config))
        let text = try await client.translate("The meeting starts at nine.", language: "en-US")
        check(text == "会議は9時に始まります。", "Index translation parse")
        check(settings.baseURL.contains("original-private") && settings.model == "keep-me", "preset does not overwrite custom model")
    }
}
final class IndexMock: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.absoluteString == "https://index-translate.bilibili.com/v1/chat/completions")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil, "existing private key must never reach Index")
        let body: Data
        if let data = request.httpBody { body = data }
        else { let s = request.httpBodyStream!; s.open(); defer { s.close() }; var bytes = [UInt8](repeating: 0, count: 32768); let n = s.read(&bytes, maxLength: bytes.count); body = Data(bytes.prefix(max(0,n))) }
        let value = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        precondition(value["model"] as? String == "Index-Translate-35B-A3B")
        precondition((value["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
        let messages = value["messages"] as? [[String: String]]
        precondition(messages?.first?["content"]?.contains("将以下英语文本翻译为日语") == true)
        let data = Data("{\"choices\":[{\"message\":{\"content\":\"会議は9時に始まります。\"}}]}".utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
