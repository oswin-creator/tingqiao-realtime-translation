import Foundation
import Speech

@main struct SpeechSupport {
    static func main() async {
        if #available(macOS 26.0, *) {
            print("SpeechTranscriber available: \(SpeechTranscriber.isAvailable)")
            print("supported: \(await SpeechTranscriber.supportedLocales.map(\.identifier).sorted())")
            print("installed: \(await SpeechTranscriber.installedLocales.map(\.identifier).sorted())")
        }
    }
}
