import SwiftUI

enum WalkthroughStep: Int, CaseIterable {
    case meeting, recognition, translation, phone, assistant

    var section: String {
        switch self {
        case .meeting: return "会议翻译"
        case .recognition, .translation: return "翻译设置"
        case .phone: return "手机字幕"
        case .assistant: return "问答大模型设置"
        }
    }

    var title: String {
        switch self {
        case .meeting: return "先选声音来源与语言"
        case .recognition: return "把声音识别成原文"
        case .translation: return "把原文翻成目标语言"
        case .phone: return "把字幕带到手机上"
        case .assistant: return "需要时，再请 AI 帮忙"
        }
    }

    var detail: String {
        switch self {
        case .meeting:
            return "线上会议读取会议播放声音，线下会议使用你选的麦克风。右侧选择原文和译文语言，也可以打开字幕悬浮窗。"
        case .recognition:
            return "推荐 Whisper large-v3-turbo，在本机识别多种语言。想省电可选 Apple 本机识别，并在系统设置中准备对应语言。"
        case .translation:
            return "翻译 API 接收识别后的文字。推荐自定义接入模力方舟 Hy-MT2-30B-A3B，兼顾成本与效果，可参考前 4 段上文。选择「自定义大模型」查看推荐与费用。"
        case .phone:
            return "同一 Wi-Fi 下，用手机相机扫码即可在浏览器看字幕。安卓 App 也支持 Wi-Fi 扫码和蓝牙连接，并记住已配对的电脑。"
        case .assistant:
            return "「帮我回答」逐个回答最近十五段里的问题；「解释刚才」说明这十五段在讨论什么。点击时，两者都会参考同场会议最近五分钟对话。这里单独设置对话模型，建议低思考、每题或每次解释 1～3 句。"
        }
    }
}

enum TranslationRecommendation {
    static let url = URL(string: "https://ai.gitee.com/serverless-api?model=Hy-MT2-30B-A3B")!
    static let model = "Hy-MT2-30B-A3B"
    static let cost = "个人用量参考：约 2 小时 0.1 元。按 Token 计费，实际费用受发言量、上文长度和平台价格影响。"
}

struct WalkthroughCard: View {
    @ObservedObject var model: AppModel
    let step: WalkthroughStep

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("快速上手 · \(step.rawValue + 1) / \(WalkthroughStep.allCases.count)", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.accent)
                Spacer()
                Button { model.finishWalkthrough() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("退出使用引导")
            }
            Text(step.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(step.detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            if step == .translation {
                Link("模力方舟模型与价格 ↗", destination: TranslationRecommendation.url)
                    .font(.system(size: 11))
            }
            HStack(spacing: 5) {
                ForEach(WalkthroughStep.allCases, id: \.rawValue) { item in
                    Capsule().fill(item.rawValue <= step.rawValue ? Palette.accent : Palette.line)
                        .frame(width: 21, height: 3)
                }
                Spacer()
                Button("跳过") { model.finishWalkthrough() }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                if step != .meeting {
                    Button("上一步") { model.moveWalkthrough(-1) }.buttonStyle(.bordered)
                }
                Button(step == .assistant ? "开始使用" : "下一步") {
                    model.moveWalkthrough(1)
                }.buttonStyle(.borderedProminent).tint(Palette.accent)
            }.font(.system(size: 11))
        }
        .padding(18).frame(width: 390)
        .background(.white, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Palette.accent.opacity(0.2)))
        .shadow(color: Palette.ink.opacity(0.12), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
    }
}
