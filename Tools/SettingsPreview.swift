import SwiftUI
import AppKit

// An isolated UI preview. No real settings, secrets, recordings or API calls.
@main struct SettingsPreview: App {
    @StateObject private var model: AppModel
    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-settings-preview-\(UUID())")
        var settings = AppSettings()
        settings.recognitionEngine = .whisperTurbo
        settings.provider = .custom
        settings.baseURL = "https://api.example.com/v1"
        settings.model = "Hy-MT2-30B-A3B"
        settings.language = "ko-KR"
        let preview = AppModel(store: try! SessionStore(root: root), settings: settings, startBackgroundWork: false)
        preview.whisperInstalled = true
        preview.terminologyCount = 10_041
        preview.terminologySourceInfo = "随软件内置 · Wikidata 10018 条 · 2026-11-05 · CC0"
        _model = StateObject(wrappedValue: preview)
    }
    var body: some Scene {
        WindowGroup("听桥 · 设置预览") {
            TranslationSettingsView(model: model).frame(minWidth: 820, minHeight: 690)
                .background(Palette.canvas).foregroundStyle(Palette.ink)
                .preferredColorScheme(.light)
        }.defaultSize(width: 920, height: 760)
    }
}
