import Foundation
@main struct WhisperSmoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = WhisperEngine(executable: root.appendingPathComponent("build/whisper-engine/TingQiaoWhisper"), model: CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : WhisperEngine.modelURL)
        let began = Date()
        try await engine.prepare()
        print("Swift pipe ready in \(Date().timeIntervalSince(began)) seconds")
        let text = try await engine.recognize(url: root.appendingPathComponent("build/vendor/whisper.cpp/samples/jfk.wav"), language: "en-US")
        precondition(text.contains("country"), "actual public fixture transcript")
        engine.stop()
        try await engine.prepare()
        let afterReset = try await engine.recognize(url: root.appendingPathComponent("build/vendor/whisper.cpp/samples/jfk.wav"), language: "en-US", retry: true)
        precondition(afterReset.contains("country"), "transcript with retry decoding after engine restart")
        engine.stop()
        print("PASS: resident Whisper transcription, engine restart, clean shutdown")
    }
}
