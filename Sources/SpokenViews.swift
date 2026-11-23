import SwiftUI
import Combine

struct SpokenMeetingToggle: View {
    @ObservedObject var playback: SpokenPlayback
    let change: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { playback.enabled }, set: change)) {
            Label("耳机播报", systemImage: "headphones")
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .font(.system(size: 11))
        .foregroundStyle(playback.enabled ? Palette.accent : Palette.muted)
        .fixedSize()
    }
}

struct SpokenMeetingStatus<Idle: View>: View {
    @ObservedObject var playback: SpokenPlayback
    @ViewBuilder var idle: Idle
    let openSettings: () -> Void

    var body: some View {
        if playback.enabled {
            HStack(spacing: 9) {
                Label(playback.status, systemImage: "headphones").lineLimit(1)
                Spacer(minLength: 4)
                SpokenVolumeControl(playback: playback)
                if playback.lag >= 4 {
                    Text("落后约 \(playback.lag) 秒").monospacedDigit().lineLimit(1)
                }
                if playback.canSkip && playback.lag >= 4 {
                    Button("跳到最新") { playback.jumpToLatest() }.foregroundStyle(Palette.accent)
                }
                if playback.canRetry {
                    Button("重试") { playback.retry() }.foregroundStyle(Palette.accent)
                }
                Button("播报设置", action: openSettings).foregroundStyle(Palette.accent)
            }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
        } else {
            HStack { idle; Spacer(minLength: 0) }
        }
    }
}

struct SpokenVolumeControl: View {
    @ObservedObject var playback: SpokenPlayback

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: playback.settings.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                .foregroundStyle(Palette.accent).frame(width: 15)
            Slider(value: Binding(get: { playback.settings.volume }, set: {
                var settings = playback.settings
                settings.volume = $0
                playback.update(settings)
            }), in: 0...1).frame(width: 68).controlSize(.mini).tint(Palette.accent)
                .accessibilityLabel("播报音量")
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Palette.accent.opacity(0.06), in: Capsule())
        .help("播报音量 \(Int(playback.settings.volume * 100))%")
    }
}

struct SpokenCaptionCard: View {
    let caption: Caption
    let showOriginal: Bool
    let fontSize: Double
    @ObservedObject var reading: SpokenReadingState

    var body: some View {
        CaptionCard(caption: caption, showOriginal: showOriginal, fontSize: fontSize,
                    spokenRange: reading.id == caption.id ? reading.range : nil)
            .overlay(alignment: .topTrailing) {
                if reading.id == caption.id {
                    RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.accent.opacity(0.60), lineWidth: 1.5)
                }
            }
    }
}

private final class SpokenSettingsForm: ObservableObject {
    @Published var installPrompt: SpokenEngine?
    @Published var removing: SpokenEngine?
}

struct SpokenSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: SpokenPlayback
    @ObservedObject var downloads: SpokenModelDownloads
    @StateObject private var form = SpokenSettingsForm()
    @Environment(\.workspaceLayout) private var layout
    private var selected: SpokenEngine { playback.settings.engine }
    private var installed: Bool { downloads.installed.contains(selected.model(for: model.settings.targetLanguage)) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                modelPanel
                outputPanel
            }
            .frame(maxWidth: 760)
            .padding(layout.padding)
            .frame(maxWidth: .infinity)
        }
        .onAppear { playback.refreshOutputs() }
        .sheet(item: $form.installPrompt) { engine in installSheet(engine) }
        .confirmationDialog("移除\(form.removing?.componentTitle ?? "模型")？", isPresented: Binding(
            get: { form.removing != nil }, set: { if !$0 { form.removing = nil } }), titleVisibility: .visible) {
            if let engine = form.removing {
                Button("移除下载", role: .destructive) { downloads.remove(engine); form.removing = nil }
            }
        }
    }

    private var modelPanel: some View {
        SettingsPanel(title: "播报模型", subtitle: "选择声音，在耳机里听译文。") {
            SettingsRow(title: "模型") {
                Picker("播报模型", selection: setting(\.engine)) {
                    ForEach(SpokenEngine.allCases) { engine in Text(engine.title).tag(engine) }
                }.labelsHidden().frame(maxWidth: 250)
            }
            VStack(alignment: .leading, spacing: 10) {
                Label(selected.detail, systemImage: "waveform").font(.system(size: 12, weight: .medium))
                if !selected.supportedSystem {
                    Text("此模型需要 \(selected.minimumSystem) 或更新版本。").font(.system(size: 11)).foregroundStyle(Palette.muted)
                } else {
                    ForEach(selected.components) { engine in
                        modelDownload(engine)
                    }
                }
                if !downloads.message.isEmpty { Text(downloads.message).font(.system(size: 11)).foregroundStyle(Palette.muted) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
            SettingsRow(title: "音色") {
                let voices = selected.voices(for: model.settings.targetLanguage)
                Picker("音色", selection: Binding(get: {
                    voices.first { $0.id == playback.settings.voices[selected] }?.id ?? ""
                }, set: { choice in
                    var settings = playback.settings
                    settings.voices[selected] = choice.isEmpty ? nil : choice
                    playback.update(settings)
                })) {
                    Text("随目标语言").tag("")
                    ForEach(voices) { voice in Text(voice.title).tag(voice.id) }
                }.labelsHidden().frame(maxWidth: 250)
            }
            if !selected.supports(model.settings.targetLanguage) {
                Text("此模型暂不支持播报\(model.settings.targetLanguage.title)。").font(.system(size: 11)).foregroundStyle(Palette.accent)
            }
        }
    }

    private var outputPanel: some View {
        SettingsPanel(title: "耳机与语速", subtitle: "耳机断开时自动暂停。") {
            SettingsRow(title: "播报耳机") {
                HStack {
                    Picker("播报耳机", selection: setting(\.outputUID)) {
                        Text("当前系统耳机").tag("")
                        if !playback.settings.outputUID.isEmpty && !playback.outputs.contains(where: { $0.uid == playback.settings.outputUID }) {
                            Text("已选耳机未连接").tag(playback.settings.outputUID)
                        }
                        ForEach(playback.outputs) { output in Text(output.name).tag(output.uid) }
                    }.labelsHidden().frame(maxWidth: 300)
                    Button { playback.refreshOutputs() } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新耳机列表")
                }
            }
            SettingsRow(title: "播放语速") {
                HStack {
                    Slider(value: setting(\.rate), in: 0.75...1.35, step: 0.05).frame(maxWidth: 245)
                    Text(String(format: "%.2f×", playback.settings.rate)).monospacedDigit().frame(width: 52)
                }
            }
            SettingsRow(title: "自动语速", detail: "译文积压时适度加快") {
                Toggle("自动跟随翻译进度", isOn: setting(\.automaticRate)).toggleStyle(.switch)
            }
            HStack(spacing: 12) {
                Button(playback.previewing ? "停止试听" : "用耳机试听") { playback.preview(language: model.settings.targetLanguage) }
                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                    .disabled(!installed || !selected.supports(model.settings.targetLanguage) || model.isRunning || model.isStarting || model.isStopping)
                if !playback.status.isEmpty {
                    Text(playback.status).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func modelDownload(_ engine: SpokenEngine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.componentTitle).font(.system(size: 12, weight: .medium))
                    Text(downloads.installed.contains(engine) ? "已安装" : engine.downloadSize)
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if downloads.downloading == engine {
                    Button("取消下载") { downloads.cancel() }
                } else if downloads.installed.contains(engine) {
                    Button("移除", role: .destructive) { form.removing = engine }
                        .disabled(playback.enabled || playback.previewing)
                } else {
                    Button("下载") { form.installPrompt = engine }
                        .buttonStyle(.borderedProminent).tint(Palette.accent).disabled(downloads.downloading != nil)
                }
            }
            if downloads.downloading == engine {
                if let progress = downloads.progress {
                    ProgressView(value: progress).tint(Palette.accent)
                    Text("正在下载 · \(Int(progress * 100))%").font(.system(size: 11)).foregroundStyle(Palette.muted)
                } else { ProgressView("正在安装…").controlSize(.small) }
            }
        }.padding(.vertical, 5)
    }

    private func setting<T>(_ key: WritableKeyPath<SpokenSettings, T>) -> Binding<T> {
        Binding(get: { playback.settings[keyPath: key] }, set: {
            var settings = playback.settings
            settings[keyPath: key] = $0
            playback.update(settings)
        })
    }

    private func installSheet(_ engine: SpokenEngine) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("下载 \(engine.componentTitle)", systemImage: "arrow.down.circle")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.accent)
            Text(engine.detail).font(.system(size: 13))
            Text("下载大小约 \(engine.downloadSize)。安装后可在本机播报。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Link("查看模型与来源 ↗", destination: engine.source).font(.system(size: 12))
            HStack {
                Spacer()
                Button("取消") { form.installPrompt = nil }.keyboardShortcut(.cancelAction)
                Button("下载并安装") { form.installPrompt = nil; downloads.install(engine) }
                    .buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440).foregroundStyle(Palette.ink).background(.white)
    }
}
