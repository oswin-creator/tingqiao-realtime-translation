import SwiftUI
import AppKit

@main struct CaptionTransitionPreview: App {
    @StateObject private var model: AppModel
    private let window: SpeechWindow
    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-caption-ui-check")
        let store = try! SessionStore(root: root)
        let file = store.audio.appendingPathComponent("ui-check.wav")
        try! Data([0]).write(to: file)
        var preferences = AppSettings(); preferences.provider = .googleFree
        let m = AppModel(store: store, settings: preferences, startBackgroundWork: false)
        m.jobs = []; m.stylePreview = false
        _model = StateObject(wrappedValue: m)
        window = SpeechWindow(id: UUID(), url: file, date: Date(), overlap: false, isFinal: false, duration: 10)
    }
    var body: some Scene {
        WindowGroup("字幕连续显示检查") {
            VStack(spacing: 0) {
                HStack {
                    Text("合成字幕检查 · 不收音、不调用接口").font(.system(size: 12))
                    Button("1 临时原文") { _ = model.commitPreview("The meeting starts at nine.", window: window, epoch: model.currentCaptureEpoch) }
                    Button("2 提交整段") { var final = window; final.isFinal = true; model.acceptWindow(final, epoch: model.currentCaptureEpoch, settings: model.settings) }
                    Button("3 确认原文") { _ = model.commitRecognition("The meeting starts at nine.", for: window.id) }
                    Button("4 补上译文") { _ = model.commitTranslation("会议九点开始。", for: window.id) }
                }.padding(12)
                MainView(model: model)
            }
        }.defaultSize(width: 1260, height: 900)
    }
}
