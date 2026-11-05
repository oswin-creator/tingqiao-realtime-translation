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
                footer
            }.background(Palette.canvas)
        }
        .foregroundStyle(Palette.ink)
        .font(.system(size: 13))
        .frame(minWidth: 1120, minHeight: 730)
        .preferredColorScheme(.light)
        .onAppear { model.loadSecrets() }
    }
    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.section).font(.system(size: 23, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
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
            Text("听桥 0.2.14").font(.system(size: 11)).foregroundStyle(Palette.muted)
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

struct TranslationSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if model.secretsLoading {
                    Label("正在等待 macOS 允许读取已保存的翻译密钥，其他功能可以继续使用。", systemImage: "key").font(.system(size: 12)).foregroundStyle(Palette.muted)
                } else if model.keychainNeedsAccess {
                    HStack {
                        Text("已保存的密钥尚未读取；空白输入框不会删除它。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                        Button("重新读取密钥") { model.loadSecrets() }
                    }
                }
                if !model.notice.isEmpty { NoticeBar(text: model.notice) { model.notice = "" } }
                SoftCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("语音识别", systemImage: "waveform").font(.system(size: 16, weight: .semibold))
                        Text("先识别所选语言，再把原文交给下方的服务翻译。").foregroundStyle(Palette.muted)
                        Picker("识别引擎", selection: $model.settings.recognitionEngine) {
                            ForEach(RecognitionEngine.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.disabled(model.languageSelectionLocked)
                            .onChange(of: model.settings.recognitionEngine) { model.recognitionInfo = "" }
                        if model.settings.recognitionEngine == .apple {
                            SourceLanguagePicker(model: model)
                            Toggle("只在本机识别语音", isOn: $model.settings.localRecognition).toggleStyle(.switch).disabled(model.languageSelectionLocked)
                            Text("在系统设置的「键盘 → 听写」中管理听写语言。macOS 26 新识别引擎可在这里手动下载当前语言资源。关闭本机模式后，音频可能交给 Apple 在线处理。")
                                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
                            HStack(spacing: 12) {
                                Button { model.openAppleLanguageSettings() } label: { Label("打开系统语言设置", systemImage: "arrow.up.right") }
                                if #available(macOS 26.0, *), model.settings.localRecognition {
                                    Button(model.installingAppleLanguage ? "正在准备语言…" : "下载当前语言资源") { model.installAppleLanguage() }
                                        .disabled(model.languageSelectionLocked)
                                }
                                Button("检查本机语言支持") { model.checkRecognitionSupport() }.disabled(model.installingAppleLanguage)
                            }
                        } else {
                            Label(model.whisperInstalled ? "large-v3-turbo 已安装 · 声音仅在本机处理" : "首次使用需下载约 1.6 GB 的模型", systemImage: model.whisperInstalled ? "checkmark.circle" : "arrow.down.circle").foregroundStyle(Palette.muted)
                            HStack {
                                Button(model.downloadingWhisper ? "正在下载模型…" : model.whisperInstalled ? "已安装" : "下载模型") { model.downloadWhisper() }.disabled(model.whisperInstalled || model.downloadingWhisper || model.isRunning || model.isStarting || model.isStopping)
                                Button("导入已有模型") { model.importWhisper() }.disabled(model.downloadingWhisper || model.isRunning)
                                Button("检查本机语言支持") { model.checkRecognitionSupport() }
                            }
                            Text("所选语言共用这一份模型。临时原文约每 5 秒更新，低电量模式约 8 秒；识别繁忙时优先处理正式句子。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
                        }
                        if !model.recognitionInfo.isEmpty { Text(model.recognitionInfo).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                        Text("短暂停顿继续拼接。句尾明确时停顿约 0.7 秒提交，句尾不明确时等约 1.5 秒。连续发言约 7 秒时优先在自然停顿处切分，最长约 10 秒。临时原文不发送给翻译服务。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
                    }
                }
                SoftCard {
                    VStack(alignment: .leading, spacing: 18) {
                        Label("翻译服务", systemImage: "character.book.closed").font(.system(size: 16, weight: .semibold))
                        Picker("服务", selection: $model.settings.provider) { ForEach(TranslationProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                        providerFields
                        HStack {
                            Button("保存设置") { model.saveSettings() }.buttonStyle(.borderedProminent).tint(Palette.accent)
                            Button(model.checkingAPI ? "正在测试…" : "测试翻译连接") { model.testAPI() }.disabled(model.checkingAPI)
                            Spacer()
                        }
                        if !model.apiResult.isEmpty { Text(model.apiResult).font(.system(size: 12)).foregroundStyle(Palette.accent).textSelection(.enabled) }
                    }
                }
                SoftCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("字幕显示", systemImage: "textformat.size").font(.system(size: 16, weight: .semibold))
                        HStack { Text("字体大小"); Slider(value: $model.settings.fontSize, in: 18...34, step: 1); Text("\(Int(model.settings.fontSize))").monospacedDigit().frame(width: 30) }
                        Toggle("同时显示原文", isOn: $model.settings.showOriginal)
                        Text("翻译时，识别出的文字会发送给你选择的翻译服务。设置在点击“保存设置”后保存到下次启动；密钥放在 macOS 钥匙串，不会同步到手机。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
                    }
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading)
        }
    }
    @ViewBuilder private var providerFields: some View {
        switch model.settings.provider {
        case .googleFree:
            Text("无需填 Key 的谷歌试用接口。它不是官方承诺的免费 API，可能限流、失效或被网络拦截；适合先试用。长时间重要会议建议使用官方接口或你自己的模型。").foregroundStyle(Palette.muted).lineSpacing(6)
        case .googleCloud:
            SecureField("Google Cloud API Key", text: $model.googleKey).textFieldStyle(.roundedBorder)
            Text("需自行开通 Cloud Translation。官方 NMT 有每月免费额度，超出后按用量收费；实际费用以谷歌控制台为准。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
        case .indexTranslate:
            Text("Index-Translate-35B-A3B · B 站官方免费公网接口，无需 API Key。只发送正式确认的原文；免费服务的可用性以提供方为准。").foregroundStyle(Palette.muted).lineSpacing(5)
            Toggle("翻译时参考上文", isOn: $model.settings.useTranslationContext).toggleStyle(.switch)
            if model.settings.useTranslationContext { Stepper("参考前 \(model.settings.translationContextCount) 段", value: $model.settings.translationContextCount, in: 1...6) }
            Text("上文仅帮助理解，只输出当前段的译文。启用后，上文也会发给 B 站翻译服务。").font(.system(size: 11)).foregroundStyle(Palette.muted)
        case .custom:
            TextField("API 基础地址，例如 https://你的服务商/v1", text: $model.settings.baseURL).textFieldStyle(.roundedBorder)
            TextField("模型名称（填写服务商提供的名称）", text: $model.settings.model).textFieldStyle(.roundedBorder)
            SecureField("API Key（本机服务可留空）", text: $model.customKey).textFieldStyle(.roundedBorder)
            Text("支持 Chat Completions 格式的接口，自动补上 /chat/completions，也可以填完整地址。此处模型用于文字翻译；只支持 Claude 原生 Messages 等其他格式的接口需要适配。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
            Divider()
            Toggle("翻译时参考上文", isOn: $model.settings.useTranslationContext).toggleStyle(.switch)
            if model.settings.useTranslationContext {
                Stepper("参考前 \(model.settings.translationContextCount) 段", value: $model.settings.translationContextCount, in: 1...6)
                    .font(.system(size: 12))
            }
            Text("默认参考同一场会议前 4 段已识别原文；已有译文也会一并提供。上文只帮助理解，字幕只输出当前段的译文。条数按收音识别片段计算，不一定是一整句话。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
            Text("开启后，上文也会发送给你填写的模型服务，增加一些输入用量。尚未完成的前文翻译不会阻塞收音或当前段处理。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
        }
    }
}

struct PhoneSettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SoftCard(padding: 28) {
                    HStack(alignment: .top, spacing: 35) {
                        VStack(alignment: .leading, spacing: 18) {
                            Text("把字幕，放到手机上").font(.system(size: 24, weight: .semibold))
                            Text("电脑和手机连接同一个 Wi-Fi，\n扫描二维码，即可打开随身字幕。") .font(.system(size: 14)).foregroundStyle(Palette.muted).lineSpacing(8)
                            HStack { Circle().fill(model.phoneEnabled ? Palette.mint : Palette.muted).frame(width: 7, height: 7); Text(model.phoneEnabled ? "Wi-Fi 字幕已开启" : "Wi-Fi 字幕未开启").font(.system(size: 12)) }
                            Button(model.phoneEnabled ? "关闭手机连接" : "开启 Wi-Fi 字幕") { model.togglePhone() }.buttonStyle(.borderedProminent).tint(Palette.accent)
                            if model.phoneEnabled {
                                Text(model.phoneURL.isEmpty ? "正在启动…" : model.phoneURL).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Button("复制配对链接") { model.copyPhoneURL() }.disabled(model.phoneURL.isEmpty)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(spacing: 13) {
                            if let image = qrImage(model.phoneURL), !model.phoneURL.isEmpty { Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 175, height: 175) }
                            else { Image(systemName: "qrcode").font(.system(size: 110, weight: .ultraLight)).foregroundStyle(Palette.line).frame(width: 175, height: 175) }
                            Text(model.phoneEnabled ? "手机相机扫一扫" : "开启后生成配对码").font(.system(size: 11)).foregroundStyle(Palette.muted)
                        }.padding(22).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 20))
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

