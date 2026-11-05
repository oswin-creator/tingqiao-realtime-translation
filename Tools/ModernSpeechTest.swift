import Foundation
import Speech

@main struct ModernSpeechTest {
    static func main() {
        Task {
            do { try await run(); exit(0) }
            catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
        }
        RunLoop.main.run()
    }
    static func run() async throws {
        if #available(macOS 26.0, *) {
            let language = CommandLine.arguments[1]
            FileHandle.standardError.write(Data("checking locale\n".utf8))
            if let locale = await ModernSpeech.locale(language) {
                FileHandle.standardError.write(Data("locale: \(locale.identifier)\n".utf8))
                let module = SpeechTranscriber(locale: locale, preset: .transcription)
                FileHandle.standardError.write(Data("status: \(await AssetInventory.status(forModules: [module]))\n".utf8))
            }
            FileHandle.standardError.write(Data("preparing assets\n".utf8))
            guard try await ModernSpeech.installLanguage(language) else { throw BridgeError("unsupported") }
            FileHandle.standardError.write(Data("transcribing\n".utf8))
            let text = try await ModernSpeech.recognize(url: URL(fileURLWithPath: CommandLine.arguments[2]), language: language)
            print(text)
        }
    }
}
