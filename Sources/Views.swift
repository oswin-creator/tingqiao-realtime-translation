import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

enum Palette {
    static let canvas = Color(red: 0.965, green: 0.970, blue: 0.985)
    static let sidebar = Color(red: 0.945, green: 0.950, blue: 0.975)
    static let ink = Color(red: 0.14, green: 0.17, blue: 0.26)
    static let muted = Color(red: 0.52, green: 0.55, blue: 0.64)
    static let accent = Color(red: 0.39, green: 0.37, blue: 0.88)
    static let line = Color(red: 0.90, green: 0.91, blue: 0.95)
    static let mint = Color(red: 0.16, green: 0.65, blue: 0.51)
}

struct SoftCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line.opacity(0.75), lineWidth: 1))
            .shadow(color: Palette.ink.opacity(0.025), radius: 18, y: 5)
    }
}

struct SmallLabel: View {
    var title: String
    var body: some View { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted) }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
            VStack(spacing: 0) {
                header
                Divider().overlay(Palette.line)
                Group {
                    switch model.section {
                    case "手机字幕": PhoneSettingsView(model: model)
                    case "翻译设置": TranslationSettingsView(model: model)
                    case "问答大模型设置": AssistantSettingsView(model: model)
                    case "会议记录": HistoryView(model: model)
                    default: MeetingView(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottomLeading) {
                        if let step = model.walkthroughStep {
                            WalkthroughCard(model: model, step: step).padding(20)
                        }
                    }
                footer
            }.background(Palette.canvas)
        }
        .foregroundStyle(Palette.ink)
        .font(.system(size: 13))
        .frame(minWidth: 1120, minHeight: 730)
        .preferredColorScheme(.light)
        .onAppear { model.loadSecrets(); model.offerWalkthrough() }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.section).font(.system(size: 23, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button { model.beginWalkthrough() } label: {
                Label("使用引导", systemImage: "questionmark.circle")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }.buttonStyle(.plain).padding(.trailing, 10)
            if model.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(model.startedAt ?? context.date))
                    Label(String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60), systemImage: "clock").monospacedDigit().foregroundStyle(Palette.muted)
                }.padding(.trailing, 14)
            }
            Label(model.isRunning ? "收音进行中" : "准备就绪", systemImage: model.isRunning ? "waveform" : "checkmark.circle")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.mint)
                .padding(.horizontal, 13).padding(.vertical, 9).background(Palette.mint.opacity(0.08), in: Capsule())
        }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 22)
    }
    private var subtitle: String {
        switch model.section {
        case "手机字幕": return "把字幕带到手边，专注眼前的交流。"
        case "翻译设置": return "选择适合你的语言和翻译服务。"
        case "问答大模型设置": return "设置会议助手的接口与回复长度。"
        case "会议记录": return "原文与译文，随时回看。"
        default: return "跨过语言，跟上每一段对话。"
        }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(model.isReconnecting ? .orange : model.isRunning ? Palette.mint : Palette.muted.opacity(0.5)).frame(width: 6, height: 6)
            Text(model.status).font(.system(size: 11))
            Spacer()
            if model.pendingCount > 0 { Text("\(model.pendingCount) 段待处理").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            Text("听桥 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.foregroundStyle(Palette.muted).padding(.horizontal, 30).padding(.vertical, 13).background(.white.opacity(0.65))
    }
}

struct Sidebar: View {
    @ObservedObject var model: AppModel
    let items = [("会议翻译", "waveform"), ("手机字幕", "iphone"), ("会议记录", "text.book.closed"), ("翻译设置", "slider.horizontal.3"), ("问答大模型设置", "bubble.left.and.bubble.right")]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [Palette.accent, Color(red: 0.52, green: 0.46, blue: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 43, height: 43)
                    Image(systemName: "waveform").font(.system(size: 23, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) { Text("听桥").font(.system(size: 23, weight: .bold)); Text("TINGQIAO").font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(Palette.muted) }
            }.padding(.top, 52).padding(.bottom, 38).padding(.horizontal, 24)
            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).padding(.leading, 26).padding(.bottom, 12)
            ForEach(items, id: \.0) { title, icon in
                Button { model.section = title } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon).font(.system(size: 15)).frame(width: 22)
                        Text(title).font(.system(size: 13, weight: model.section == title ? .semibold : .regular))
                        Spacer()
                        if title == "手机字幕", model.phoneEnabled { Circle().fill(Palette.mint).frame(width: 5, height: 5) }
                    }.foregroundStyle(model.section == title ? Palette.accent : Palette.muted)
                        .padding(.horizontal, 15).padding(.vertical, 13)
                        .background(model.section == title ? .white : .clear, in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain).padding(.horizontal, 13).padding(.bottom, 6)
            }
            Spacer()
            HStack {
                Image(systemName: "sparkle").foregroundStyle(Palette.accent)
                Text("让每一句，都听得懂").font(.system(size: 11, weight: .medium))
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 14)).padding(14)
            HStack(spacing: 7) { Image(systemName: "lock.shield"); Text("记录保存在这台 Mac") }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.leading, 23).padding(.bottom, 23)
        }.frame(width: 205).background(Palette.sidebar)
    }
}

struct MeetingView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            sourceCard
            if !model.notice.isEmpty { NoticeBar(text: model.notice) { model.notice = "" } }
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    captionsArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                    AssistantReplyRegion(presentation: model.assistantPresentation)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                rail.frame(width: 246)
            }.frame(maxHeight: .infinity)
            controlBar
        }.padding(26)
    }
    private var sourceCard: some View {
        SoftCard(padding: 18) {
            HStack(spacing: 22) {
                HStack(spacing: 4) {
                    ForEach(MeetingMode.allCases, id: \.self) { mode in
                        Button { model.settings.mode = mode; model.settings.save() } label: {
                            Label(mode.rawValue, systemImage: mode.icon).font(.system(size: 12, weight: .medium)).padding(.horizontal, 15).padding(.vertical, 11)
                                .foregroundStyle(model.settings.mode == mode ? Palette.accent : Palette.muted)
                                .background(model.settings.mode == mode ? .white : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }.padding(4).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12)).disabled(model.isRunning || model.isStarting || model.isStopping)
                Rectangle().fill(Palette.line).frame(width: 1, height: 32)
                VStack(alignment: .leading, spacing: 5) {
                    SmallLabel(title: model.settings.mode == .online ? "声音来源" : "麦克风")
                    if model.settings.mode == .online {
                        Picker("", selection: $model.settings.applicationID) {
                            Text("全部系统声音").tag("")
                            ForEach(model.applications) { Text($0.name).tag($0.id) }
                        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Picker("", selection: $model.settings.microphoneID) {
                            Text("系统默认麦克风").tag("")
                            ForEach(model.devices) { Text($0.name).tag($0.id) }
                        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.disabled(model.isRunning || model.isStarting || model.isStopping)
                Button { if model.settings.mode == .online { model.refreshApplications() } else { model.refreshDevices() } } label: { Image(systemName: "arrow.clockwise").foregroundStyle(Palette.muted) }.buttonStyle(.plain).help("刷新声音来源").disabled(model.isRunning || model.isStarting)
            }
        }
    }
    private var captionsArea: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("实时字幕", systemImage: "captions.bubble").font(.system(size: 13, weight: .semibold))
                if model.stylePreview { Text("样式预览").font(.system(size: 10)).foregroundStyle(Palette.accent).padding(.horizontal, 7).padding(.vertical, 3).background(Palette.accent.opacity(0.08), in: Capsule()) }
                Spacer()
                if !model.mainFollowsLatest {
                    Button("回到最新") { model.mainFollowsLatest = true }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Palette.accent)
                }
                RecordActions(model: model)
                Button { model.settings.showOriginal.toggle(); model.settings.save() } label: { Label(model.settings.showOriginal ? "双语" : "只看译文", systemImage: "character.bubble").font(.system(size: 11)).foregroundStyle(Palette.muted) }.buttonStyle(.plain)
            }
            if model.hideDesktopCaptions {
                emptyView(icon: "eye.slash", title: "电脑字幕已隐藏", detail: "收音和翻译继续进行。\n你可以在手机上安静地看字幕。")
            } else if model.captions.isEmpty && !model.stylePreview {
                emptyView(icon: "waveform.bubble", title: "准备好，听懂下一句话", detail: "选好声音来源和语言，点击下方“开始翻译”。\n对方的原文和译文会出现在这里。")
            } else {
                CaptionScroll(followsLatest: $model.mainFollowsLatest, captions: model.captions) {
                    LazyVStack(alignment: .leading, spacing: 15) {
                        ForEach(model.stylePreview && model.captions.isEmpty ? sampleCaptions : model.captions) { caption in
                            CaptionCard(caption: caption, showOriginal: model.settings.showOriginal, fontSize: model.settings.fontSize)
                                .contextMenu { Button("删除这条记录") { model.removeRecords([caption.id]) } }
                        }
                    }
                }
            }
            HStack(spacing: 7) { Image(systemName: "info.circle"); Text(model.settings.mode == .online ? "只读取播放声音，麦克风交给会议软件。" : "请将麦克风靠近发言者，识别更准确。") }.font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
    }
    private func emptyView(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 17) {
            Spacer()
            Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(Palette.accent.opacity(0.75)).frame(width: 88, height: 88).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 27))
            Text(title).font(.system(size: 20, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).lineSpacing(7)
            if !model.hideDesktopCaptions { Button("预览字幕样式") { model.stylePreview = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent).padding(.top, 8) }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
    }
    private var rail: some View {
        VStack(spacing: 16) {
            SoftCard(padding: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    SmallLabel(title: "语言与翻译")
                    HStack(alignment: .bottom, spacing: 8) {
                        VStack(alignment: .leading, spacing: 5) {
                            SmallLabel(title: "原文")
                            SourceLanguagePicker(model: model).labelsHidden()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.bottom, 5)
                        VStack(alignment: .leading, spacing: 5) {
                            SmallLabel(title: "译文")
                            Picker("目标语言", selection: Binding(get: { model.settings.targetLanguage }, set: model.selectTargetLanguage)) {
                                ForEach(MeetingLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.labelsHidden()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.disabled(model.languageSelectionLocked)
                    if model.settings.language == model.settings.targetLanguage.rawValue {
                        Text("两种语言相同，仅生成原文字幕。").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    Rectangle().fill(Palette.line).frame(height: 1)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: model.settings.provider == .custom ? "sparkles" : "globe.asia.australia").foregroundStyle(Palette.accent).frame(width: 31, height: 31).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 5) { Text(model.settings.provider.rawValue).font(.system(size: 12, weight: .medium)); Text(model.settings.recognitionEngine == .whisperTurbo ? "Whisper Turbo · 本机识别" : model.settings.localRecognition ? "Apple · 本机识别" : "语音由 Apple 识别").font(.system(size: 10)).foregroundStyle(Palette.muted) }
                    }
                    Button { model.section = "翻译设置" } label: { HStack { Text("调整翻译设置"); Spacer(); Image(systemName: "chevron.right") }.font(.system(size: 11)).foregroundStyle(Palette.muted) }.buttonStyle(.plain)
                    Button { model.section = "问答大模型设置" } label: { HStack { Text("问答大模型设置"); Spacer(); Image(systemName: "chevron.right") }.font(.system(size: 11)).foregroundStyle(Palette.muted) }.buttonStyle(.plain)
                    AssistantButtons(model: model)
                }
            }
            SoftCard(padding: 18) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack { Image(systemName: "iphone").foregroundStyle(Palette.accent); Text("随身字幕").font(.system(size: 13, weight: .semibold)); Spacer(); Circle().fill(model.phoneEnabled ? Palette.mint : Palette.line).frame(width: 6, height: 6) }
                    Text("字幕放在手机上，\n电脑留给会议。") .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(6)
                    Button { model.section = "手机字幕" } label: { HStack { Text(model.phoneEnabled ? "查看配对二维码" : "连接我的手机"); Spacer(); Image(systemName: "arrow.up.right") }.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent).padding(11).background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                Toggle("隐藏电脑字幕", isOn: $model.hideDesktopCaptions).toggleStyle(.switch).controlSize(.mini)
                Toggle("字幕悬浮窗", isOn: Binding(get: { model.floatingVisible }, set: { model.setFloating($0) })).toggleStyle(.switch).controlSize(.mini).disabled(model.hideDesktopCaptions)
            }.font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 7)
            if model.stylePreview { Button("退出样式预览") { model.stylePreview = false }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted) }
        }
    }
    private var controlBar: some View {
        HStack(spacing: 15) {
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<18) { index in
                    RoundedRectangle(cornerRadius: 2).fill(model.isRunning ? Palette.accent.opacity(Double(index) < model.level * 18 + 1 ? 0.8 : 0.12) : Palette.line)
                        .frame(width: 3, height: CGFloat([9, 14, 21, 14, 25, 33, 18, 26, 15, 22, 31, 20, 14, 24, 16, 10, 17, 8][index]))
                }
            }.frame(height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isReconnecting ? "正在恢复声音连接" : model.isRunning ? "正在聆听" : "开始一场没有语言距离的会议").font(.system(size: 12, weight: .medium))
                Text(model.isRunning ? "声音片段会持续保存并翻译" : "首次使用需要允许系统收音权限").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer()
            if model.pendingCount > 0 { Button { model.retryPending() } label: { Image(systemName: "arrow.clockwise") }.help("重试待处理内容").buttonStyle(.plain).foregroundStyle(Palette.accent) }
            Button { if model.isRunning { model.stop() } else { model.stylePreview = false; model.start() } } label: {
                HStack(spacing: 9) { Image(systemName: model.isRunning ? "stop.fill" : "play.fill"); Text(model.isStarting ? "正在准备…" : model.isStopping ? "正在停止…" : model.isRunning ? "结束收音" : "开始翻译") }.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 24).padding(.vertical, 14).background(model.isRunning ? Palette.ink : Palette.accent, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).disabled(model.isStarting || model.isStopping || model.installingAppleLanguage).keyboardShortcut(.return, modifiers: .command)
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(Palette.line, lineWidth: 1))
    }
    private var sampleCaptions: [Caption] {
        [Caption(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, date: Date(), original: "Let's start with a quick overview of the project.", translated: "我们先来快速了解一下项目的整体情况。"), Caption(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, date: Date(), original: "이번 주에는 사용자 피드백을 중심으로 논의하겠습니다.", translated: "这周我们将围绕用户反馈展开讨论。"), Caption(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, date: Date(), original: "We want to make the experience simpler for everyone.", translated: "我们希望让每个人都能更轻松地使用。")]
    }
}

struct CaptionCard: View {
    var caption: Caption
    var showOriginal: Bool
    var fontSize: Double
    var body: some View {
        SoftCard(padding: 20) {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 7) { Circle().fill(Palette.accent.opacity(0.45)).frame(width: 5, height: 5); Text(caption.date.formatted(date: .omitted, time: .standard)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted) }
                if !caption.original.isEmpty && (showOriginal || caption.isDraft == true || caption.translated.isEmpty) { Text(caption.original).font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5).textSelection(.enabled) }
                Text(caption.displayText).font(.system(size: fontSize, weight: .medium)).foregroundStyle(caption.translated.isEmpty ? Palette.muted : Palette.ink).lineSpacing(7).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct NoticeBar: View {
    var text: String
    var dismiss: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Palette.accent)
            Text(text).font(.system(size: 11)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(Palette.muted) }.buttonStyle(.plain)
        }.padding(13).background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct SourceLanguagePicker: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Picker("原文语言", selection: Binding(get: { model.settings.language }, set: model.selectSourceLanguage)) {
            ForEach(MeetingLanguage.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
        }.disabled(model.languageSelectionLocked)
    }
}

private enum TranslationSettingsTab: String, CaseIterable {
    case recognition = "语音识别", translation = "翻译接口", terminology = "术语与语境", display = "字幕显示"
    var icon: String {
        switch self {
        case .recognition: return "waveform"
        case .translation: return "character.bubble"
        case .terminology: return "text.book.closed"
        case .display: return "textformat.size"
        }
    }
}

private struct SettingsPanel<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            }
            content
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line, lineWidth: 1))
    }
}

private struct SettingsRow<Content: View>: View {
    var title: String
    var detail: String = ""
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium))
                if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(3) }
            }.frame(width: 116, alignment: .leading).padding(.top, 6)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private final class TranslationSettingsState: ObservableObject {
    @Published var tab: TranslationSettingsTab = .recognition
    @Published var showingRules = false
}

struct TranslationSettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var form = TranslationSettingsState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(TranslationSettingsTab.allCases, id: \.self) { item in
                    Button { form.tab = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.system(size: 12, weight: form.tab == item ? .semibold : .medium))
                            .foregroundStyle(form.tab == item ? Palette.accent : Palette.muted)
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(form.tab == item ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(form.tab == item ? Palette.line : .clear))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }.padding(5).background(Palette.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: 13))
                .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.secretsLoading {
                        hint("正在等待 macOS 允许读取已保存的密钥，其他功能可以继续使用。")
                    } else if model.keychainNeedsAccess {
                        HStack {
                            hint("密钥尚未读取；空白输入框不会删除已保存的密钥。")
                            Button("重新读取") { model.loadSecrets() }
                        }
                    }
                    if !model.notice.isEmpty { NoticeBar(text: model.notice) { model.notice = "" } }
                    switch form.tab {
                    case .recognition: recognitionPanel
                    case .translation: translationPanel
                    case .terminology: terminologyPanel
                    case .display: displayPanel
                    }
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
            HStack(spacing: 12) {
                Image(systemName: "lock.shield").foregroundStyle(Palette.muted)
                Text("密钥保存在本机钥匙串；更改后请保存。")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                if form.tab == .translation {
                    Button(model.checkingAPI ? "正在测试…" : "测试翻译连接") { model.testAPI() }
                        .disabled(model.checkingAPI)
                }
                Button("保存设置") { model.saveSettings() }.buttonStyle(.borderedProminent).tint(Palette.accent)
            }.controlSize(.large).padding(.horizontal, 28).padding(.vertical, 15)
                .background(.white).overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
        .tint(Palette.accent)
        .onAppear { followWalkthrough() }
        .onChange(of: model.walkthroughStep) { followWalkthrough() }
    }

    private func followWalkthrough() {
        if model.walkthroughStep == .recognition { form.tab = .recognition }
        if model.walkthroughStep == .translation { form.tab = .translation }
    }
    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted)
            .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }
    private var separator: some View { Rectangle().fill(Palette.line.opacity(0.8)).frame(height: 1) }

    private var recognitionPanel: some View {
        SettingsPanel(title: "把声音识别成原文", subtitle: "先听写，再翻译。Whisper 适合本地多语言识别，所有支持的语言共用一份模型。") {
            SettingsRow(title: "识别引擎") {
                Picker("识别引擎", selection: $model.settings.recognitionEngine) {
                    ForEach(RecognitionEngine.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize().frame(maxWidth: 330, alignment: .leading).disabled(model.languageSelectionLocked)
                    .onChange(of: model.settings.recognitionEngine) { model.recognitionInfo = "" }
            }
            SettingsRow(title: "语言方向", detail: "与主页面保持同步") {
                HStack(spacing: 12) {
                    SourceLanguagePicker(model: model).labelsHidden().fixedSize()
                    Image(systemName: "arrow.right").foregroundStyle(Palette.muted)
                    Picker("目标语言", selection: Binding(get: { model.settings.targetLanguage }, set: model.selectTargetLanguage)) {
                        ForEach(MeetingLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().fixedSize().disabled(model.languageSelectionLocked)
                }.frame(maxWidth: 430)
            }
            separator
            if model.settings.recognitionEngine == .whisperTurbo {
                SettingsRow(title: "本地模型") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(model.whisperInstalled ? "已安装 · 声音仅在本机处理" : "首次使用需下载约 1.6 GB", systemImage: model.whisperInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 12)).foregroundStyle(model.whisperInstalled ? Palette.mint : Palette.muted)
                        HStack(spacing: 10) {
                            Button(model.downloadingWhisper ? "正在下载…" : model.whisperInstalled ? "已安装" : "下载模型") { model.downloadWhisper() }
                                .disabled(model.whisperInstalled || model.downloadingWhisper || model.languageSelectionLocked)
                            Button("导入已有模型…") { model.importWhisper() }.disabled(model.downloadingWhisper || model.languageSelectionLocked)
                        }
                        hint("无需为每种语言重复下载。模型在本机运行，会增加一些用电和内存占用。")
                    }
                }
            } else {
                SettingsRow(title: "隐私与语言") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("只在本机识别语音", isOn: $model.settings.localRecognition).toggleStyle(.switch).disabled(model.languageSelectionLocked)
                        hint("在系统设置「键盘 → 听写」中管理语言。关闭本机模式后，声音可能发送给 Apple 在线识别；语言资源不会自动下载。")
                        HStack(spacing: 10) {
                            Button("打开系统语言设置 ↗") { model.openAppleLanguageSettings() }
                            if #available(macOS 26.0, *), model.settings.localRecognition {
                                Button(model.installingAppleLanguage ? "正在准备…" : "下载当前语言资源") { model.installAppleLanguage() }.disabled(model.languageSelectionLocked)
                            }
                        }
                    }
                }
            }
            SettingsRow(title: "语言支持") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("检查本机语言支持") { model.checkRecognitionSupport() }.disabled(model.installingAppleLanguage)
                    if !model.recognitionInfo.isEmpty { hint(model.recognitionInfo) }
                }
            }
            separator
            SettingsRow(title: "实时字幕", detail: "持续收音，按段翻译") {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(spacing: 8) {
                        Text("Silero 人声检测").font(.system(size: 12, weight: .medium))
                        Text("本机运行").font(.system(size: 10)).foregroundStyle(Palette.mint)
                    }
                    hint("临时原文每 4 秒尝试更新；句尾明确停顿约 0.7 秒提交，其他约 1.5 秒。连续发言约 7 秒起寻找停顿，最长约 10 秒切段。")
                    Button { form.showingRules.toggle() } label: { Label("查看识别与音频保护说明", systemImage: "info.circle") }
                        .buttonStyle(.plain).foregroundStyle(Palette.accent).font(.system(size: 11))
                        .popover(isPresented: $form.showingRules) {
                            VStack(alignment: .leading, spacing: 13) {
                                Text("识别与音频保护").font(.system(size: 15, weight: .semibold))
                                hint("当前检测状态：\(model.vadStatus)")
                                hint("Silero 辅助判断人声与停顿，再结合文字句尾判断提交时机。它不负责降噪，也不能保证识别所有轻声。")
                                hint("4 秒是预览触发间隔，识别繁忙时可能延后，正式片段优先；临时原文不发送给翻译服务。")
                                hint("保留前后音频缓冲，硬切时保留重叠。检测失败或持续过慢时回退到音量检测，继续收音；未确认的人声候选最迟在安全窗口或停止时处理。")
                            }.padding(22).frame(width: 370)
                        }
                }
            }
        }.controlSize(.large)
    }

    private var translationPanel: some View {
        SettingsPanel(title: "选择文字翻译服务", subtitle: "只发送确认后的原文。语音识别与翻译接口分别设置，会议助手使用独立接口。") {
            SettingsRow(title: "翻译服务") {
                Picker("翻译服务", selection: $model.settings.provider) {
                    ForEach(TranslationProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize().frame(maxWidth: 350, alignment: .leading)
            }
            separator
            providerFields
            if model.settings.provider == .custom || model.settings.provider == .indexTranslate {
                separator
                SettingsRow(title: "上文参考", detail: "仅输出当前段译文") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("参考同一会议的前文", isOn: $model.settings.useTranslationContext).toggleStyle(.switch)
                        if model.settings.useTranslationContext {
                            Stepper("参考前 \(model.settings.translationContextCount) 段", value: $model.settings.translationContextCount, in: 1...6).frame(maxWidth: 235)
                        }
                        hint("默认前 4 段原文与已有译文，按收音片段计算。开启后，相关前文也会发送给翻译服务，增加少量输入用量；不会等待前文翻译而阻塞收音。")
                    }
                }
            }
            if !model.apiResult.isEmpty {
                Text(model.apiResult).font(.system(size: 12)).foregroundStyle(Palette.accent).textSelection(.enabled)
            }
        }.controlSize(.large)
    }

    @ViewBuilder private var providerFields: some View {
        switch model.settings.provider {
        case .googleFree:
            SettingsRow(title: "免 Key 试用") {
                hint("无需填写密钥。此接口没有官方免费服务保证，可能限流或失效。重要的长时间会议建议使用官方接口或自定义模型。")
            }
        case .googleCloud:
            SettingsRow(title: "API Key") { SecureField("Google Cloud API Key", text: $model.googleKey).textFieldStyle(.roundedBorder) }
            SettingsRow(title: "计费说明") { hint("需自行开通 Cloud Translation；免费额度与实际费用以 Google 控制台为准。") }
        case .indexTranslate:
            SettingsRow(title: "Index 翻译") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Index-Translate-35B-A3B").font(.system(size: 13, weight: .medium))
                    hint("B 站官方免费公网接口，无需 API Key。服务可用性以提供方为准。")
                }
            }
        case .custom:
            SettingsRow(title: "推荐搭配", detail: "成本与效果的平衡") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("模力方舟 · \(TranslationRecommendation.model)").font(.system(size: 12, weight: .medium))
                    hint(TranslationRecommendation.cost)
                    Link("查看模型与价格 ↗", destination: TranslationRecommendation.url).font(.system(size: 11)).foregroundStyle(Palette.accent)
                }
            }
            SettingsRow(title: "API 地址") { TextField("https://你的服务商/v1", text: $model.settings.baseURL).textFieldStyle(.roundedBorder) }
            SettingsRow(title: "模型名称") { TextField("服务商提供的模型名称", text: $model.settings.model).textFieldStyle(.roundedBorder) }
            SettingsRow(title: "API Key") { SecureField("输入密钥；本机服务可留空", text: $model.customKey).textFieldStyle(.roundedBorder) }
            SettingsRow(title: "接口格式") { hint("支持 Chat Completions 格式，自动补上 /chat/completions，也可以填写完整地址。此处模型只用于文字翻译。") }
        }
    }

    private var terminologyPanel: some View {
        SettingsPanel(title: "专业词汇，结合上下文理解", subtitle: "已随软件附带 Wikidata 多语言专业词库，离线检索，无需另行下载。") {
            SettingsRow(title: "专业术语") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启用本地术语检索", isOn: $model.settings.useTerminology).toggleStyle(.switch)
                    hint("仅向翻译模型提供少量相关术语，帮助统一译法；不替换识别原文。")
                }
            }
            SettingsRow(title: "会议语境") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("参考最近 60 秒的术语语境", isOn: $model.settings.useTerminologyMemory).toggleStyle(.switch).disabled(!model.settings.useTerminology)
                    hint("帮助区分多义词；新会议、清空记录后不沿用旧语境。无需额外调用 AI。")
                }
            }
            SettingsRow(title: "会议话题", detail: "可选，最多 120 字") {
                TextField("例如：统计分析、医学研究、软件开发", text: $model.settings.terminologyTopic).textFieldStyle(.roundedBorder)
                    .onChange(of: model.settings.terminologyTopic) { model.settings.terminologyTopic = String(model.settings.terminologyTopic.prefix(120)) }
            }
            separator
            SettingsRow(title: "本地词库", detail: "用户自定义优先") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.mint)
                        Text(model.terminologyLoading ? "正在加载…" : "当前可用 \(model.terminologyCount.formatted()) 条").font(.system(size: 12, weight: .medium))
                    }
                    hint(model.terminologySourceInfo)
                    HStack(spacing: 10) {
                        Button("导入词库…") { model.importTerminology() }
                        Button("导出词库…") { model.exportTerminology() }
                        Button { model.reloadTerminology() } label: { Label("重新加载", systemImage: "arrow.clockwise") }
                    }.disabled(model.terminologyLoading)
                    hint("内置 10,018 个 Wikidata 概念与人工校订词，去重后默认 10,041 条。导入的自定义词优先；本机更新包可替代内置快照。各语言覆盖不同，缺少译名时不编造。")
                    if !model.terminologyInfo.isEmpty { hint(model.terminologyInfo) }
                }
            }
            separator
            SettingsRow(title: "使用范围") {
                hint("Index 与自定义翻译接口支持术语提示；当前 Google 接口保持原请求。每段只发送相关的少量词条与必要含义，不发送整本词库，提示预算约 300 Token（估算）。")
            }
        }.controlSize(.large)
    }

    private var displayPanel: some View {
        SettingsPanel(title: "让字幕更容易阅读", subtitle: "调整主页面与桌面悬浮字幕的阅读体验。手机字幕可在「手机字幕」中连接。") {
            SettingsRow(title: "字幕字号") {
                HStack(spacing: 14) {
                    Text("小").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Slider(value: $model.settings.fontSize, in: 18...34, step: 1)
                    Text("\(Int(model.settings.fontSize))").monospacedDigit().frame(width: 28)
                }.frame(maxWidth: 420)
            }
            SettingsRow(title: "双语显示") {
                Toggle("同时显示原文", isOn: $model.settings.showOriginal).toggleStyle(.switch)
            }
            separator
            VStack(alignment: .leading, spacing: 10) {
                Text("字幕预览").font(.system(size: 11)).foregroundStyle(Palette.muted)
                if model.settings.showOriginal { Text("Let’s understand every conversation.").font(.system(size: 13)).foregroundStyle(Palette.muted) }
                Text("让每一句，都听得懂。").font(.system(size: model.settings.fontSize, weight: .medium))
            }.padding(.vertical, 8)
        }
    }
}

struct PhoneSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SoftCard(padding: 28) {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 18) {
                            Label("Wi-Fi 随身字幕", systemImage: "wifi").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                            Text("把字幕，放到手机上").font(.system(size: 24, weight: .semibold))
                            Text("手机和电脑连接同一个 Wi-Fi，任选一种方式开始阅读。")
                                .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5)
                            VStack(alignment: .leading, spacing: 15) {
                                connectionOption(icon: "safari", title: "浏览器直接看", detail: "无需下载 App，用手机相机扫码，在浏览器打开即可。")
                                Divider().overlay(Palette.line)
                                connectionOption(icon: "apps.iphone", title: "安卓 App 里看", detail: "在「听桥字幕」中扫码，或粘贴电脑上的配对链接。")
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 13))
                            HStack(spacing: 12) {
                                HStack(spacing: 6) {
                                    Circle().fill(model.phoneEnabled ? Palette.mint : Palette.muted).frame(width: 6, height: 6)
                                    Text(model.phoneEnabled ? "Wi-Fi 字幕已开启" : "Wi-Fi 字幕未开启").font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 4)
                                Button(model.phoneEnabled ? "关闭 Wi-Fi 字幕" : "开启 Wi-Fi 字幕") { model.togglePhone() }
                                    .buttonStyle(.borderedProminent).tint(Palette.accent)
                            }
                            if model.phoneEnabled {
                                Button { model.copyPhoneURL() } label: { Label("复制配对链接", systemImage: "link") }
                                    .disabled(model.phoneURL.isEmpty).buttonStyle(.plain).foregroundStyle(Palette.accent)
                                Text(model.phoneURL.isEmpty ? "正在启动…" : model.phoneURL)
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(spacing: 13) {
                            if let image = qrImage(model.phoneURL), !model.phoneURL.isEmpty { Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 175, height: 175) }
                            else { Image(systemName: "qrcode").font(.system(size: 110, weight: .ultraLight)).foregroundStyle(Palette.line).frame(width: 175, height: 175) }
                            Text(model.phoneEnabled ? "扫码后用浏览器打开" : "开启后生成二维码")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Text("浏览器 · 安卓 App")
                                .font(.system(size: 10)).foregroundStyle(Palette.accent)
                        }.padding(20).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 17))
                    }
                }
                SoftCard(padding: 28) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("蓝牙字幕", systemImage: "antenna.radiowaves.left.and.right").font(.system(size: 20, weight: .semibold))
                            Spacer()
                            Button(model.bluetoothEnabled ? "关闭蓝牙字幕" : "开启蓝牙字幕") { model.toggleBluetooth() }.buttonStyle(.borderedProminent).tint(Palette.accent)
                        }
                        Text("无需 Wi-Fi。在安卓 App 中点击“蓝牙连接”，首次输入下方配对码，之后在“已配对的电脑”直接连接；支持记住多台设备。首次连接请按系统提示完成蓝牙配对。").font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5)
                        if model.bluetoothEnabled {
                            HStack(spacing: 20) {
                                Text(model.bluetoothCode).font(.system(size: 32, weight: .semibold, design: .monospaced)).tracking(7).textSelection(.enabled)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.bluetoothStatus).font(.system(size: 12))
                                    Text("已连接 \(model.bluetoothConnections) 台手机 · 已配对设备无需重复输码").font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                if !model.pairedPhones.isEmpty {
                    SoftCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("已记住的手机").font(.system(size: 14, weight: .semibold))
                            ForEach(model.pairedPhones) { peer in
                                HStack { Text(peer.name); Spacer(); Button("取消配对") { model.forgetPhone(peer.id) } }
                            }
                        }
                    }
                }
                SoftCard {
                    VStack(alignment: .leading, spacing: 17) {
                        Toggle("隐藏电脑上的字幕", isOn: $model.hideDesktopCaptions).toggleStyle(.switch)
                        Text("开启后，电脑主窗口与悬浮窗都不显示字幕，手机仍正常更新。隐藏不会停止收音。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Divider()
                        Label("安卓 App 也可以粘贴配对链接连接", systemImage: "apps.iphone").font(.system(size: 13, weight: .medium))
                        Text("同一 Wi-Fi 无法互通时，可试试手机热点。若出现系统防火墙提示，请允许听桥接收本地连接。也可改用上方的蓝牙字幕，无需共同网络。").font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(6)
                        Text("字幕通过局域网 HTTP 发送，配对链接相当于访问凭证，请仅在可信网络使用。关闭再开启连接会更换配对码。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
                    }
                }
                if !model.notice.isEmpty { NoticeBar(text: model.notice) { model.notice = "" } }
            }.padding(28).frame(maxWidth: 950)
        }
    }
    private func connectionOption(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Palette.accent).frame(width: 23)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func qrImage(_ value: String) -> NSImage? {
        guard !value.isEmpty else { return nil }
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(value.utf8)
        guard let output = generator.outputImage?.transformed(by: CGAffineTransform(scaleX: 7, y: 7)), let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("共 \(model.visibleJobs.filter { !$0.original.isEmpty }.count) 段对话 · \(model.pendingCount) 段待处理").foregroundStyle(Palette.muted)
                Spacer()
                Button("重试待处理") { model.retryPending() }.disabled(model.pendingCount == 0)
                RecordActions(model: model)
                Button { model.openDataFolder() } label: { Image(systemName: "folder") }.help("打开本机数据文件夹")
            }
            if !model.notice.isEmpty { NoticeBar(text: model.notice) { model.notice = "" } }
            ScrollView {
                LazyVStack(spacing: 13) {
                    ForEach(model.visibleJobs.suffix(300).reversed()) { job in
                        SoftCard(padding: 18) {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack { Text(job.created.formatted(date: .abbreviated, time: .standard)); Spacer(); Text(job.stage == .done ? "已完成" : job.stage == .blocked ? "需检查设置" : job.stage == .recognize ? "待识别" : "待翻译") }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                                if !job.original.isEmpty { Text(job.original).foregroundStyle(Palette.muted).textSelection(.enabled) }
                                if !job.translated.isEmpty { Text(job.translated).font(.system(size: 16)).textSelection(.enabled) }
                                if !job.error.isEmpty { Text(job.error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
                            }
                        }.contextMenu { Button("删除这条记录") { model.removeRecords([job.id]) } }
                    }
                    if model.visibleJobs.isEmpty { Text("还没有会议记录，开始一场会议后会自动保存。").foregroundStyle(Palette.muted).padding(80) }
                }
            }
            Text("界面显示最近 300 段，导出包含全部未清除的原文和译文。清除后可撤销，也可在菜单中永久删除。").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(28)
    }
}
