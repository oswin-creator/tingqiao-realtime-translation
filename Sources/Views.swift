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

struct WorkspaceLayout {
    var size = CGSize(width: 1260, height: 860)
    var density: CGFloat { min(1, max(0, (size.height - 640) / 220)) }
    var width: CGFloat { min(1, max(0, (size.width - 1000) / 260)) }
    var padding: CGFloat { 16 + 10 * density }
    var gap: CGFloat { 10 + 8 * density }
    var sidebarWidth: CGFloat { 176 + 29 * width }
    var railWidth: CGFloat { 236 + 10 * width }
}

private struct WorkspaceLayoutKey: EnvironmentKey {
    static let defaultValue = WorkspaceLayout()
}

extension EnvironmentValues {
    var workspaceLayout: WorkspaceLayout {
        get { self[WorkspaceLayoutKey.self] }
        set { self[WorkspaceLayoutKey.self] = newValue }
    }
}

struct MainView: View {
    let model: AppModel
    var body: some View {
        DeferredWindowLayout(background: NSColor(Palette.canvas)) {
            WorkspaceView(model: model)
        }.frame(minWidth: 1000, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
            .preferredColorScheme(.light)
    }
}

private struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            let layout = WorkspaceLayout(size: geometry.size)
            HStack(spacing: 0) {
            Sidebar(model: model)
            VStack(spacing: 0) {
                header(layout)
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
                footer(layout)
            }.background(Palette.canvas)
            }.environment(\.workspaceLayout, layout)
        }
        .foregroundStyle(Palette.ink)
        .font(.system(size: 13))
        .frame(minWidth: 1000, minHeight: 640)
        .preferredColorScheme(.light)
        .sheet(isPresented: $model.choosingMeetingDomains) {
            MeetingDomainSelectionView(model: model)
        }
        .onAppear { model.loadSecrets(); model.offerWalkthrough() }
    }
    private func header(_ layout: WorkspaceLayout) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.section).font(.system(size: 20 + 3 * layout.density, weight: .semibold))
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
        }.padding(.horizontal, layout.padding + 4).padding(.top, 18 + 10 * layout.density).padding(.bottom, 12 + 10 * layout.density)
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
    private func footer(_ layout: WorkspaceLayout) -> some View {
        HStack(spacing: 8) {
            Circle().fill(model.isReconnecting ? .orange : model.isRunning ? Palette.mint : Palette.muted.opacity(0.5)).frame(width: 6, height: 6)
            Text(model.status).font(.system(size: 11)).lineLimit(1)
            Spacer()
            if model.pendingCount > 0 { Text("\(model.pendingCount) 段待处理").font(.system(size: 11)).foregroundStyle(Palette.accent) }
            AppUpdateButton(model: model, updates: model.appUpdates)
            Text("听桥 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.foregroundStyle(Palette.muted).padding(.horizontal, layout.padding + 4).padding(.vertical, 8 + 5 * layout.density).background(.white.opacity(0.65))
    }
}

struct MeetingDomainGrid: View {
    var domains: [String]
    @Binding var selection: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
            ForEach(domains, id: \.self) { domain in
                Toggle(MeetingDomain(rawValue: domain)?.title ?? domain, isOn: Binding(get: { selection.contains(domain) }, set: { selected in
                    if selected { selection = Array(Set(selection + [domain])).sorted() }
                    else { selection.removeAll { $0 == domain } }
                }))
                .toggleStyle(.checkbox).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading).padding(13)
                .background(selection.contains(domain) ? Palette.accent.opacity(0.06) : Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selection.contains(domain) ? Palette.accent.opacity(0.3) : Palette.line, lineWidth: 1))
            }
        }.tint(Palette.accent)
    }
}

struct MeetingDomainSelectionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical").font(.system(size: 23)).foregroundStyle(Palette.accent)
                    .frame(width: 48, height: 48).background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text("本次会议的专业领域").font(.system(size: 20, weight: .semibold))
                    Text("选择词库分区，可多选。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
            ScrollView {
                MeetingDomainGrid(domains: model.terminologyDomainIDs, selection: $model.meetingDomainSelection)
            }.frame(maxHeight: 260)
            HStack {
                Text(model.meetingDomainSelection.isEmpty ? "普通翻译" : "已选 \(model.meetingDomainSelection.count) 个领域")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("取消") { model.choosingMeetingDomains = false }.keyboardShortcut(.cancelAction)
                Button("开始收音") { model.confirmMeetingDomains() }.buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 520).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(Palette.ink).background(.white).preferredColorScheme(.light)
    }
}

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @Environment(\.workspaceLayout) private var layout
    let items = [("会议翻译", "waveform"), ("手机字幕", "iphone"), ("会议记录", "text.book.closed"), ("翻译设置", "slider.horizontal.3"), ("问答大模型设置", "bubble.left.and.bubble.right")]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [Palette.accent, Color(red: 0.52, green: 0.46, blue: 0.94)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 36 + 7 * layout.density, height: 36 + 7 * layout.density)
                    Image(systemName: "waveform").font(.system(size: 20 + 3 * layout.density, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) { Text("听桥").font(.system(size: 23, weight: .bold)); Text("TINGQIAO").font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(Palette.muted) }
            }.padding(.top, 32 + 20 * layout.density).padding(.bottom, 20 + 18 * layout.density).padding(.horizontal, 20)
            Text("工作空间").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted).padding(.leading, 26).padding(.bottom, 12)
            ForEach(items, id: \.0) { title, icon in
                Button { model.section = title } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon).font(.system(size: 15)).frame(width: 22)
                        Text(title == "问答大模型设置" ? "会议助手" : title).font(.system(size: 12 + layout.density, weight: model.section == title ? .semibold : .regular)).lineLimit(1)
                        Spacer()
                        if title == "手机字幕", model.phoneEnabled { Circle().fill(Palette.mint).frame(width: 5, height: 5) }
                    }.foregroundStyle(model.section == title ? Palette.accent : Palette.muted)
                        .padding(.horizontal, 13).padding(.vertical, 10 + 3 * layout.density)
                        .background(model.section == title ? .white : .clear, in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain).padding(.horizontal, 13).padding(.bottom, 6)
            }
            Spacer()
            HStack {
                Image(systemName: "sparkle").foregroundStyle(Palette.accent)
                Text("让每一句，都听得懂").font(.system(size: 11, weight: .medium))
            }.padding(12 + 5 * layout.density).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 14)).padding(12)
            HStack(spacing: 7) { Image(systemName: "lock.shield"); Text("记录保存在这台 Mac") }.font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.leading, 23).padding(.bottom, 23)
        }.frame(width: layout.sidebarWidth).background(Palette.sidebar)
    }
}

struct MeetingView: View {
    @ObservedObject var model: AppModel
    @Environment(\.workspaceLayout) private var layout
    var body: some View {
        VStack(spacing: layout.gap) {
            sourceCard
            HStack(alignment: .top, spacing: layout.gap + 2) {
                VStack(spacing: 10) {
                    if !model.notice.isEmpty { NoticeBar(text: model.notice) { model.notice = "" } }
                    captionsArea.frame(maxWidth: .infinity, maxHeight: .infinity)
                    AssistantReplyRegion(presentation: model.assistantPresentation, compact: layout.density < 0.4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                rail.frame(width: layout.railWidth)
            }.frame(maxHeight: .infinity)
            controlBar
        }.padding(layout.padding)
    }
    private var sourceCard: some View {
        SoftCard(padding: 12 + 6 * layout.density) {
            HStack(spacing: 14 + 8 * layout.density) {
                HStack(spacing: 4) {
                    ForEach(MeetingMode.allCases, id: \.self) { mode in
                        Button { model.settings.mode = mode; model.settings.save() } label: {
                            Label(mode.rawValue, systemImage: mode.icon).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12 + 3 * layout.density).padding(.vertical, 8 + 3 * layout.density)
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
        VStack(alignment: .leading, spacing: 10 + 6 * layout.density) {
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
            if model.captions.isEmpty && !model.stylePreview {
                emptyView(icon: "captions.bubble", title: "准备好，听懂下一句话", detail: "选好声音来源和语言，点击下方“开始翻译”。\n对方的原文和译文会出现在这里。")
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
        GeometryReader { geometry in
            let room = min(1, max(0, (geometry.size.height - 110) / 180))
            VStack(spacing: 8 + 9 * room) {
                Spacer(minLength: 0)
                Image(systemName: icon).font(.system(size: 24 + 14 * room, weight: .light))
                    .foregroundStyle(Palette.accent.opacity(0.75))
                    .frame(width: 48 + 40 * room, height: 88 * room)
                    .background(Palette.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18 + 9 * room))
                    .opacity(room)
                Text(title).font(.system(size: 16 + 4 * room, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                Text(detail).font(.system(size: 11 + room)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center).lineSpacing(4)
                    .frame(height: 40 * room).clipped().opacity(room)
                Button("预览字幕样式") { model.stylePreview = true }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.accent)
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).frame(width: geometry.size.width, height: geometry.size.height)
        }.background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line, style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
    }
    private var rail: some View {
        VStack(spacing: 10 + 6 * layout.density) {
            SoftCard(padding: 13 + 5 * layout.density) {
                VStack(alignment: .leading, spacing: 9 + 3 * layout.density) {
                    Button {
                        model.terminologySetupRequested = true; model.section = "翻译设置"
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("专业领域", systemImage: "text.book.closed").font(.system(size: 11, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.muted)
                            }
                            Text(MeetingDomain.summary(model.settings.terminologyDomains)).font(.system(size: 10))
                                .foregroundStyle(Palette.muted).lineLimit(2)
                        }
                    }.buttonStyle(.plain).disabled(model.languageSelectionLocked)
                    HStack(alignment: .bottom, spacing: 6) {
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
                        Text("仅生成原文字幕").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }
                    Rectangle().fill(Palette.line).frame(height: 1)
                    HStack(spacing: 9) {
                        Image(systemName: model.settings.provider == .custom ? "sparkles" : "globe.asia.australia")
                            .foregroundStyle(Palette.accent).frame(width: 30, height: 30)
                            .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.settings.provider.rawValue).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(model.settings.recognitionEngine.isLocalModel ? "\(model.settings.recognitionEngine.shortTitle) · 本机识别" : model.settings.localRecognition ? "Apple · 本机识别" : "Apple 在线识别")
                                .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                    }
                    HStack(spacing: 10) {
                        Button { model.section = "翻译设置" } label: { Label("翻译设置", systemImage: "slider.horizontal.3") }
                        Spacer(minLength: 0)
                        Button { model.section = "问答大模型设置" } label: { Label("助手设置", systemImage: "bubble.left.and.bubble.right") }
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    AssistantButtons(model: model)
                }
            }
            Button { model.section = "手机字幕" } label: {
                SoftCard(padding: 12 + 3 * layout.density) {
                    HStack(spacing: 10) {
                        Image(systemName: "iphone").font(.system(size: 21)).foregroundStyle(Palette.accent)
                            .frame(width: 32, height: 34)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("随身字幕").font(.system(size: 12, weight: .semibold))
                            Text(model.phoneEnabled || model.bluetoothEnabled ? "查看手机连接" : "连接手机阅读字幕")
                                .font(.system(size: 10)).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                        if model.phoneEnabled || model.bluetoothConnections > 0 { Circle().fill(Palette.mint).frame(width: 5, height: 5) }
                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Palette.accent)
                    }
                }
            }.buttonStyle(.plain)
            if model.stylePreview {
                Button("退出样式预览") { model.stylePreview = false }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }
    private var controlBar: some View {
        HStack(spacing: 12 + 3 * layout.density) {
            AudioLevelMeter(presentation: model.audioLevel, running: model.isRunning, density: layout.density)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.isReconnecting ? "正在恢复声音连接" : model.isRunning ? "正在聆听" : "准备开始会议")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(model.settings.mode == .online ? "系统声音" : "麦克风收音").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            Toggle("字幕悬浮窗", isOn: Binding(get: { model.floatingVisible }, set: { model.setFloating($0) }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize().padding(.trailing, 6)
            if model.pendingCount > 0 {
                Button { model.retryPending() } label: { Image(systemName: "arrow.clockwise") }
                    .help("重试待处理内容").buttonStyle(.plain).foregroundStyle(Palette.accent)
            }
            Button { if model.isRunning { model.stop() } else { model.stylePreview = false; model.start() } } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                    Text(model.isStarting ? "正在准备…" : model.isStopping ? "正在停止…" : model.isRunning ? "结束收音" : "开始翻译")
                }.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 20 + 4 * layout.density).padding(.vertical, 10 + 4 * layout.density)
                    .background(model.isRunning ? Palette.ink : Palette.accent, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).disabled(model.isStarting || model.isStopping || model.installingAppleLanguage || model.downloadingWhisper).keyboardShortcut(.return, modifiers: .command)
        }.padding(12 + 6 * layout.density).background(.white, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(Palette.line, lineWidth: 1))
    }
    private var sampleCaptions: [Caption] {
        [Caption(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, date: Date(), original: "Let's start with a quick overview of the project.", translated: "我们先来快速了解一下项目的整体情况。"), Caption(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, date: Date(), original: "이번 주에는 사용자 피드백을 중심으로 논의하겠습니다.", translated: "这周我们将围绕用户反馈展开讨论。"), Caption(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, date: Date(), original: "We want to make the experience simpler for everyone.", translated: "我们希望让每个人都能更轻松地使用。")]
    }
}

struct AudioLevelMeter: View {
    @ObservedObject var presentation: AudioLevelPresentation
    var running: Bool
    var density: CGFloat
    private let heights = [9,14,21,14,25,33,18,26,15,22,31,20,14,24,16,10,17,8]
    var body: some View {
        HStack(spacing: 2+density) {
            ForEach(heights.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(running ? Palette.accent.opacity(Double(index) < presentation.value*18+1 ? 0.8 : 0.12) : Palette.line)
                    .frame(width: 2+density, height: CGFloat(heights[index])*(0.7+0.3*density))
            }
        }.frame(height: 24+10*density)
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
            Text(text).font(.system(size: 11)).lineSpacing(4).lineLimit(3).help(text)
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
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
    @Published var showingAppleInstall = false
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
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if model.secretsLoading {
                        hint("请在 macOS 提示中允许读取已保存的密钥。")
                    } else if model.keychainNeedsAccess {
                        HStack {
                            hint("尚未读取密钥，请允许访问钥匙串后重试。")
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
        .onAppear {
            if model.terminologySetupRequested { form.tab = .terminology; model.terminologySetupRequested = false }
            followWalkthrough()
        }
        .onChange(of: model.walkthroughStep) { followWalkthrough() }
        .onAppear { model.refreshLocalModels() }
        .sheet(item: $model.modelInstallPrompt) { item in
            ModelInstallSheet(model: model, item: item)
        }
        .sheet(isPresented: $form.showingAppleInstall) {
            AppleModelInstallSheet(language: MeetingLanguage.sourceName(model.settings.language), cancel: { form.showingAppleInstall = false }, install: {
                form.showingAppleInstall = false; model.installAppleLanguage()
            })
        }
        .alert("移除本地模型？", isPresented: Binding(get: { model.modelRemovalPrompt != nil }, set: { if !$0 { model.modelRemovalPrompt = nil } }), presenting: model.modelRemovalPrompt) { item in
            Button("取消", role: .cancel) { model.modelRemovalPrompt = nil }
            Button("移除模型", role: .destructive) { model.removeLocalModel(item) }
        } message: { item in
            Text("将移除 \(item.title)，释放 \(item.installedSize) 空间。需要时可重新下载。")
        }

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
        SettingsPanel(title: "把声音识别成原文", subtitle: "选择适合会议语言的识别模型，在本机生成字幕。") {
            SettingsRow(title: "识别引擎") {
                Picker("识别引擎", selection: $model.settings.recognitionEngine) {
                    ForEach(RecognitionEngine.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize().frame(maxWidth: 330, alignment: .leading).disabled(model.languageSelectionLocked)
                    .onChange(of: model.settings.recognitionEngine) { model.recognitionInfo = ""; model.refreshLocalModels() }
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
            if let localModel = LocalModel.find(model.settings.recognitionEngine) {
                SettingsRow(title: "本地模型") {
                    LocalModelControls(model: model, item: localModel)
                }
            } else {
                SettingsRow(title: "隐私与语言") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("只在本机识别语音", isOn: $model.settings.localRecognition).toggleStyle(.switch).disabled(model.languageSelectionLocked)
                        hint("在「系统设置 → 键盘 → 听写」中管理语言。在线识别时，声音会发送给 Apple。")
                        HStack(spacing: 10) {
                            Button("打开系统语言设置 ↗") { model.openAppleLanguageSettings() }
                            if #available(macOS 26.0, *), model.settings.localRecognition {
                                Button(model.installingAppleLanguage ? "正在准备…" : "下载当前语言资源") { form.showingAppleInstall = true }.disabled(model.languageSelectionLocked)
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
                                hint("Silero 检测讲话和停顿，结合句尾确定分段时机。")
                                hint("临时原文用于预览；整段确认后再翻译，正式片段优先处理。")
                                hint("连续讲话强切时，下一段附带前面 1.5 秒声音。")
                                hint("1～10 个词或字组成的内容连续重复 10 次，会复核这一段；未通过时保留音频。")
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
                        hint("将前文的原文与已有译文一并发送给翻译服务，帮助理解指代和术语。")
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
                hint("无需密钥，适合体验；长时间会议推荐官方接口或自定义模型。")
            }
        case .googleCloud:
            SettingsRow(title: "API Key") { SecureField("Google Cloud API Key", text: $model.googleKey).textFieldStyle(.roundedBorder) }
            SettingsRow(title: "计费说明") { hint("需自行开通 Cloud Translation；免费额度与实际费用以 Google 控制台为准。") }
        case .indexTranslate:
            SettingsRow(title: "Index 翻译") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Index-Translate-35B-A3B").font(.system(size: 13, weight: .medium))
                    hint("B 站提供的免费翻译接口，无需 API Key。")
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
        SettingsPanel(title: "专业词汇，结合上下文理解", subtitle: "内置多语言专业词库，也支持导入自己的词条。") {
            SettingsRow(title: "常用领域", detail: "开始收音时默认勾选") {
                MeetingDomainGrid(domains: model.terminologyDomainIDs, selection: Binding(get: { model.settings.terminologyDomains }, set: model.rememberMeetingDomains))
                    .disabled(model.languageSelectionLocked)
            }
            separator
            SettingsRow(title: "专业术语") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("启用本地术语检索", isOn: $model.settings.useTerminology).toggleStyle(.switch)
                    hint("提供相关专业词汇，帮助统一译法。")
                }
            }
            SettingsRow(title: "会议语境") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("参考最近 60 秒的术语语境", isOn: $model.settings.useTerminologyMemory).toggleStyle(.switch).disabled(!model.settings.useTerminology)
                    hint("结合前文，理解术语和指代。")
                }
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
                    if !model.terminologyInfo.isEmpty { hint(model.terminologyInfo) }
                }
            }
            separator
            SettingsRow(title: "使用范围") {
                hint("专业词库适用于 Index 和自定义翻译接口。")
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
        ScrollView(showsIndicators: false) {
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
                        Text("在安卓 App 中选择「蓝牙连接」，首次输入配对码；之后可在已配对设备中直接连接，无需 Wi-Fi。").font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5)
                        if model.bluetoothEnabled {
                            HStack(spacing: 20) {
                                Text(model.bluetoothCode).font(.system(size: 32, weight: .semibold, design: .monospaced)).tracking(7).textSelection(.enabled)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.bluetoothStatus).font(.system(size: 12))
                                    Text("已连接 \(model.bluetoothConnections) 台手机").font(.system(size: 11)).foregroundStyle(Palette.muted)
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
                        Label("安卓 App 也可以粘贴配对链接连接", systemImage: "apps.iphone").font(.system(size: 13, weight: .medium))
                        Text("连接遇到问题时，可尝试手机热点或蓝牙；系统询问本地网络访问时，请允许连接。").font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(6)
                        Text("请在可信 Wi-Fi 下使用，配对链接仅分享给自己的设备。").font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(5)
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
            Text("显示最近 300 段；导出包含全部未清除的记录。").font(.system(size: 10)).foregroundStyle(Palette.muted)
        }.padding(28)
    }
}
