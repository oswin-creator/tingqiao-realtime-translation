import SwiftUI

private struct CaptionSurfaceOpacityKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var captionSurfaceOpacity: Double {
        get { self[CaptionSurfaceOpacityKey.self] }
        set { self[CaptionSurfaceOpacityKey.self] = newValue }
    }
}

struct AssistantButtons: View {
    @ObservedObject var model: AppModel
    @Environment(\.captionSurfaceOpacity) private var surfaceOpacity
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AssistantAction.allCases, id: \.self) { action in
                Button { model.askAssistant(action) } label: {
                    Label(action.title, systemImage: action.icon)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .fixedSize()
                        .padding(.horizontal, compact ? 8 : 9)
                        .padding(.vertical, compact ? 5 : 7)
                        .foregroundStyle(Palette.accent)
                        .background(Palette.accent.opacity((action == .answer ? 0.12 : 0.06) * surfaceOpacity), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).disabled(model.assistantBusy)
                    .help(action == .answer ? "参考最近五分钟，逐个回答最近十五段里的问题" : "参考最近五分钟，解释最近十五段在讨论什么")
            }
        }
    }
}

final class AssistantPresentation: ObservableObject {
    @Published var reply: AssistantReply?
}

struct AssistantReplyRegion: View {
    @ObservedObject var presentation: AssistantPresentation
    var compact = false

    var body: some View {
        if let reply = presentation.reply {
            AssistantReplyCard(reply: reply, compact: compact) { presentation.reply = nil }
                .id(reply.id)
                .padding(compact ? 8 : 0)
        }
    }
}

private final class AssistantCardState: ObservableObject {
    @Published var showsReasoning = false
}

private struct AssistantReplyCard: View {
    @Environment(\.captionSurfaceOpacity) private var surfaceOpacity
    @StateObject private var cardState = AssistantCardState()
    var reply: AssistantReply
    var compact = false
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: reply.action.icon)
                Text(reply.action.title).fontWeight(.semibold)
                if reply.state == .waiting { ProgressView().controlSize(.mini) }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted) }
                    .buttonStyle(.plain).accessibilityLabel("关闭问答")
            }.font(.system(size: 12)).foregroundStyle(Palette.accent)
            if let reasoning = reply.reasoning, !reasoning.isEmpty {
                Button {
                    cardState.showsReasoning.toggle()
                } label: {
                    Label("思考过程", systemImage: cardState.showsReasoning ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11)).foregroundStyle(Palette.accent)
                }.buttonStyle(.plain)
                if cardState.showsReasoning {
                    ScrollView {
                        Text(reasoning).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: compact ? 55 : 100)
                }
            }
            if reply.text.count > (compact ? 85 : 140) {
                ScrollView { replyText }.frame(height: compact ? 76 : 116)
            } else {
                replyText
            }
        }
        .padding(compact ? 9 : 13)
        .background(.white.opacity(surfaceOpacity), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent.opacity(0.18 * surfaceOpacity)))
    }

    private var replyText: some View {
        Text(reply.text).font(.system(size: compact ? 13 : 14))
            .lineSpacing(3).foregroundStyle(reply.state == .ready ? Palette.ink : Palette.muted)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private final class AssistantSettingsForm: ObservableObject {
    @Published var draft = AssistantSettings()
    @Published var key = ""
    @Published var feedback = ""
    @Published var saving = false
    @Published var savedAccount: String?
    @Published var checkingKey = false
    @Published var keyStatus = ""
    var keyLookup: Task<Void, Never>?
}

struct AssistantSettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var form = AssistantSettingsForm()

    var body: some View {
        ScrollView(showsIndicators: false) {
            SoftCard {
                VStack(alignment: .leading, spacing: 16) {
                    Label("会议助手接口", systemImage: "bubble.left.and.bubble.right").font(.system(size: 17, weight: .semibold))
                    Text("点击按钮时，助手参考最近五分钟的对话，回答或解释最近十五段内容。电脑和手机共用此接口。")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text("API 地址")
                            TextField("https://服务商地址/v1", text: $form.draft.baseURL).accessibilityLabel("问答 API 地址")
                        }
                        GridRow {
                            Text("模型名称")
                            TextField("输入对话模型名称", text: $form.draft.model).accessibilityLabel("问答模型名称")
                        }
                        GridRow {
                            Text("API Key")
                            VStack(alignment: .leading, spacing: 5) {
                                SecureField(form.savedAccount == nil ? "输入 API Key" : "********（已保存，输入可替换）", text: $form.key)
                                    .accessibilityLabel("问答 API Key")
                                if form.checkingKey {
                                    Text("正在检查已保存的密钥…").font(.system(size: 10)).foregroundStyle(Palette.muted)
                                } else if form.savedAccount != nil && form.key.isEmpty {
                                    Label("此接口的密钥已保存在钥匙串", systemImage: "checkmark.shield")
                                        .font(.system(size: 10)).foregroundStyle(Palette.mint)
                                } else if !form.keyStatus.isEmpty {
                                    HStack {
                                        Text(form.keyStatus)
                                        Button("重新检查") { checkSavedKey() }.buttonStyle(.plain).foregroundStyle(Palette.accent)
                                    }.font(.system(size: 10)).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                        GridRow {
                            Text("思考强度")
                            Picker("思考强度", selection: $form.draft.effort) {
                                ForEach(AssistantSettings.Effort.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.labelsHidden().accessibilityLabel("思考强度")
                        }
                        GridRow {
                            Text("回复句数")
                            Picker("最多回复", selection: $form.draft.sentences) {
                                ForEach(1...3, id: \.self) { Text("\($0) 句").tag($0) }
                            }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 240).accessibilityLabel("回复句数，回答按每题，解释按整段")
                        }
                    }.textFieldStyle(.roundedBorder)
                    Toggle("使用 max_completion_tokens 参数", isOn: $form.draft.modernTokenLimit)
                    Text("「帮我回答」用提问语言作答，并附目标语言译文，两部分各按所选句数回复。「解释刚才」整段按所选句数回复。思考内容单独折叠。")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    HStack {
                        Button("保存问答设置", action: save).buttonStyle(.borderedProminent).tint(Palette.accent).disabled(form.saving)
                        if !form.feedback.isEmpty { Text(form.feedback).font(.system(size: 12)).foregroundStyle(Palette.muted) }
                    }
                }.foregroundStyle(Palette.ink)
            }.padding(26)
        }.onAppear { form.draft = model.assistantSettings; checkSavedKey() }
            .onChange(of: form.draft.baseURL) { checkSavedKey() }
            .onDisappear { form.keyLookup?.cancel() }
    }

    private func checkSavedKey() {
        form.keyLookup?.cancel()
        form.savedAccount = nil
        form.keyStatus = ""
        guard let account = try? form.draft.keyAccountForEndpoint() else { form.checkingKey = false; return }
        form.checkingKey = true
        form.keyLookup = Task {
            let result = await Task.detached { Result { try SecretStore.contains(account) } }.value
            guard !Task.isCancelled, (try? form.draft.keyAccountForEndpoint()) == account else { return }
            form.checkingKey = false
            switch result {
            case .success(let exists):
                form.savedAccount = exists ? account : nil
                form.keyStatus = exists ? "" : "此接口尚未保存密钥，本机免密接口可留空。"
            case .failure:
                form.keyStatus = "暂未确认已保存的密钥，可重新检查。"
            }
        }
    }

    private func save() {
        var configuration = form.draft
        configuration.baseURL = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.configured else { form.feedback = "请填写 API 地址和模型名称。"; return }
        let newKey = form.key.trimmingCharacters(in: .whitespacesAndNewlines)
        form.saving = true
        Task {
            defer { form.saving = false }
            do {
                let account = try configuration.keyAccountForEndpoint()
                if !newKey.isEmpty { try await Task.detached { try SecretStore.write(newKey, account: account) }.value }
                try configuration.save()
                model.assistantSettings = configuration
                form.draft = configuration
                form.key = ""
                form.feedback = "已保存。"
                checkSavedKey()
            } catch { form.feedback = error.localizedDescription }
        }
    }
}
