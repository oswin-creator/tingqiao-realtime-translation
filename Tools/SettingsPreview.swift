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
        settings.terminologyDomains = ["business", "statistics"]
        let preview = AppModel(store: try! SessionStore(root: root), settings: settings, startBackgroundWork: false)
        preview.whisperInstalled = true
        preview.installedLocalModels = [.whisperTurbo]
        preview.terminologyCount = 14_251
        preview.terminologySourceInfo = "随软件内置 · Wikidata 14160 条 · 2026-11-06 · CC0"
        _model = StateObject(wrappedValue: preview)
    }
    var body: some Scene {
        WindowGroup("听桥 · 设置预览") {
            Group {
                if CommandLine.arguments.contains("--meeting-setup") {
                    MainView(model: model)
                } else {
                    TranslationSettingsView(model: model).frame(minWidth: 820, minHeight: 690)
                }
            }.background(Palette.canvas).foregroundStyle(Palette.ink).preferredColorScheme(.light)
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1260, height: 860)
            .commands {
                CommandMenu("布局预览") {
                    ForEach([CGSize(width: 1000, height: 640), CGSize(width: 1120, height: 730), CGSize(width: 1260, height: 860), CGSize(width: 1440, height: 900)], id: \.width) { size in
                        Button("\(Int(size.width)) × \(Int(size.height))") {
                            if let window = NSApplication.shared.windows.first(where: { $0.title == "听桥 · 设置预览" }) {
                                window.setContentSize(size); window.center()
                            }
                        }
                    }
                    Divider()
                    Button("空白与提示") {
                        model.stylePreview = false; model.jobs = []; model.assistantReply = nil
                        model.notice = "设置已保存，选择声音来源即可开始。"
                    }
                    Button("字幕与助手") {
                        model.notice = ""; model.stylePreview = false
                        let session = UUID()
                        model.jobs = (0..<6).map { index in
                            var job = AudioJob(id: UUID(), sessionID: session, created: Date(), audioFile: "preview", language: "ko-KR", localRecognition: true)
                            job.original = "평행추세 가정을 확인하고 분석 결과를 비교하겠습니다."
                            job.translated = "我们将检验平行趋势假设，并比较分析结果。第 \(index + 1) 段。"; job.stage = .done
                            return job
                        }
                        model.assistantReply = AssistantReply(id: "layout-preview", action: .answer, state: .ready,
                            text: "1. 如何检验平行趋势？\n사건연구를 통해 처치 전 추세를 비교할 수 있습니다.\n译文：可以通过事件研究比较处理前趋势。\n\n2. 如何选择标准误？\n처치 배정 단위에서 군집 표준오차를 사용할 수 있습니다.\n译文：可以在处理分配层级使用聚类标准误。", reasoning: "结合最新问题和讨论背景，整理可以直接回应的内容。")
                    }
                    Button("预览悬浮字幕") { model.setFloating(true) }
                }
            }
    }
}
