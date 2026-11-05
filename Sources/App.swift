import SwiftUI
import AppKit

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var closing = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if closing { return .terminateNow }
        closing = true
        Task { @MainActor in
            await model?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApplication.shared.activate(ignoringOtherApps: true) }
}

@main
struct TingQiaoApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("听桥") {
            MainView(model: model).onAppear { delegate.model = model }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1260, height: 860)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .appInfo) { Button("翻译设置…") { model.section = "翻译设置" }.keyboardShortcut(",", modifiers: .command) }
                CommandGroup(replacing: .help) {
                    Button("听桥使用引导") { model.beginWalkthrough() }
                }
            }
        MenuBarExtra("听桥", systemImage: model.isRunning ? "waveform.circle.fill" : "waveform.circle") {
            Text(model.status)
            Button(model.isRunning ? "结束收音" : "开始翻译") { if model.isRunning { model.stop() } else { model.start() } }.disabled(model.isStarting || model.isStopping)
            Toggle("隐藏电脑字幕", isOn: $model.hideDesktopCaptions)
            Button("显示主窗口") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                NSApplication.shared.windows.first { $0.title == "听桥" }?.makeKeyAndOrderFront(nil)
            }
            Divider()
            Button("退出听桥") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
