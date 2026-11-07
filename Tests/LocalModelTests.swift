import Foundation
import CryptoKit

@main struct LocalModelTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tingqiao-model-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        check(RecognitionEngine.allCases.count == 5, "all five engines selectable")
        check(LocalModel.all.count == 4, "four independent downloads")
        check(Set(LocalModel.all.map(\.installedFile)).count == 4, "separate model paths")
        check(LocalModel.find(.apple) == nil, "Apple assets managed by the system")
        check(LocalModel.find(.whisperTurbo)?.fileURL == WhisperEngine.modelURL, "existing Turbo path retained")
        for item in LocalModel.all {
            check(item.revision.count == 40 && item.sha256.count == 64, "pinned artifact identity")
            check(item.downloadURL.scheme == "https" && item.downloadURL.host == "huggingface.co", "HTTPS model source")
            check(item.fileURL.deletingLastPathComponent() == LocalModel.directory, "model remains inside local model directory")
            var settings = AppSettings(); settings.recognitionEngine = item.engine
            let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
            check(decoded.recognitionEngine == item.engine, "engine preference round trip")
            var job = AudioJob(id: UUID(), sessionID: UUID(), created: Date(), audioFile: "test.wav", language: "ko-KR", localRecognition: true)
            job.recognitionEngine = item.engine
            check(try JSONDecoder().decode(AudioJob.self, from: JSONEncoder().encode(job)).recognitionEngine == item.engine, "queued job preserves chosen engine")
        }
        check(!RecognitionEngine.whisperKomix.supports("en-US") && RecognitionEngine.whisperKomix.supports("ko-KR"), "Korean fine-tune language gate")
        for engine in [RecognitionEngine.qwenASR, .whisperLarge, .whisperTurbo] {
            check(MeetingLanguage.allCases.allSatisfy { engine.supports($0.rawValue) }, "multilingual engines support current selector")
        }
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{\"recognitionEngine\":\"Whisper large-v3-turbo\"}".utf8))
        check(old.recognitionEngine == .whisperTurbo, "old settings retained")
        let payload = Data("a complete synthetic model".utf8)
        let source = root.appendingPathComponent("source.bin")
        try payload.write(to: source)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try LocalModelFiles.verify(source, bytes: Int64(payload.count), sha256: hash)
        do { try LocalModelFiles.verify(source, bytes: Int64(payload.count+1), sha256: hash); preconditionFailure("truncation accepted") } catch { checks += 1 }
        do { try LocalModelFiles.verify(source, bytes: Int64(payload.count), sha256: String(repeating: "0", count: 64)); preconditionFailure("wrong hash accepted") } catch { checks += 1 }
        let first = root.appendingPathComponent("first.bin"), second = root.appendingPathComponent("second.bin")
        try LocalModelFiles.publish(source, to: first); try LocalModelFiles.publish(source, to: second)
        check(try Data(contentsOf: first) == payload, "atomic publish")
        check(fm.fileExists(atPath: source.path), "import leaves original file intact")
        try Data("receipt".utf8).write(to: LocalModelFiles.receiptURL(first))
        try LocalModelFiles.remove(LocalModel.all[0], at: first)
        check(!fm.fileExists(atPath: first.path) && !fm.fileExists(atPath: LocalModelFiles.receiptURL(first).path), "removal deletes selected model and receipt")
        check(try Data(contentsOf: second) == payload && fm.fileExists(atPath: source.path), "other models and import source preserved")
        check(!LocalModelFiles.installed(LocalModel.all[0], at: second), "wrong file size is not installed")
        let helper = root.appendingPathComponent("fake-engine")
        let script = """
        #!/usr/bin/python3
        import sys,json
        with open(sys.argv[1]+'.launches','a') as f: f.write('start\\n')
        print('{"ready":true}',flush=True)
        for line in sys.stdin:
            r=json.loads(line)
            print(json.dumps({'text': r['language']+(' retry' if r['retry'] else ' final')}),flush=True)
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let worker = WhisperEngine(executable: helper, model: source)
        for engine in LocalModel.all.map(\.engine) {
            try await worker.prepare(engine: engine)
            let text = try await worker.recognize(url: source, language: "ko-KR", engine: engine)
            check(text == "ko final", "selected engine receives language and final request")
            let retried = try await worker.recognize(url: source, language: "ko-KR", retry: true, engine: engine)
            check(retried == "ko retry", "selected engine receives bounded retry request")
        }
        worker.stop()
        let launches = try String(contentsOf: source.appendingPathExtension("launches"), encoding: .utf8).split(separator: "\n")
        check(launches.count == 4, "one resident worker per engine, replaced on selection change")
        print("PASS \(checks) local-model checks")
    }
}
