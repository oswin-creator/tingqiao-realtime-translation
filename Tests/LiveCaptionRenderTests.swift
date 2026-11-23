import AppKit
import SwiftUI

@main struct LiveCaptionRenderTests {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-live-caption-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SessionStore(root: root)
        let model = AppModel(store: store, settings: AppSettings(), startBackgroundWork: false)
        model.isRunning = true
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1150, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.orderFront(nil)

        DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
            fputs("Live caption window stopped responding.\n", stderr)
            exit(1)
        }
        func render() {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        render()
        for i in 1...18 {
            let id = UUID()
            let audio = store.audio.appendingPathComponent("\(id).wav")
            let date = Date()
            let spoken = "오늘 회의 자료의 통계 결과를 확인합니다. \(i)"
            let translated = "正在核对今天的会议资料和统计结果。\(i)"
            let draft = SpeechWindow(id: id, url: audio, date: date, overlap: false, isFinal: false, duration: 4)
            precondition(model.commitPreview(spoken, window: draft, epoch: model.currentCaptureEpoch))
            render()
            var final = draft
            final.isFinal = true
            model.acceptWindow(final, epoch: model.currentCaptureEpoch, settings: model.settings)
            precondition(model.commitRecognition(spoken, for: id))
            render()
            precondition(model.commitTranslation(translated, for: id))
            render()
            precondition(model.captions.last?.translated == translated)
            if i > 9 {
                model.spoken.reading.show(id)
                render()
                model.spoken.reading.show(nil)
                render()
            }
            if i == 9 {
                model.mainFollowsLatest = false
                window.setContentSize(NSSize(width: 1000, height: 640))
                render()
                precondition(!model.mainFollowsLatest)
                model.mainFollowsLatest = true
            }
        }
        window.orderOut(nil)
        print("PASS: Live caption window stays responsive through 18 recognition and translation updates.")
    }
}
