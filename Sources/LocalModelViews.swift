import SwiftUI

struct LocalModelControls: View {
    @ObservedObject var model: AppModel
    let item: LocalModel
    private var installed: Bool { model.installedLocalModels.contains(item.engine) }
    private var busy: Bool { model.downloadingModel == item.engine }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: installed ? "checkmark.circle.fill" : "shippingbox")
                    .foregroundStyle(installed ? Palette.mint : Palette.accent)
                Text(installed ? "已安装 · \(item.installedSize)" : busy ? (model.modelDownloadCanCancel ? "正在下载" : "正在准备") : "待下载 · \(item.downloadSize)")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Text(item.engine == .whisperKomix ? "韩语专用" : "多语言")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Palette.accent.opacity(0.07), in: Capsule())
            }
            Text(item.summary).font(.system(size: 12)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            if busy {
                VStack(alignment: .leading, spacing: 7) {
                    if let value = model.modelDownloadProgress {
                        ProgressView(value: value).tint(Palette.accent)
                        Text("已下载 \(ByteCountFormatter.string(fromByteCount: model.modelDownloadedBytes, countStyle: .file)) / \(item.downloadSize) · \(Int(value * 100))%").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    } else {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在校验并准备模型…").font(.system(size: 11)).foregroundStyle(Palette.muted) }
                    }
                    if model.modelDownloadCanCancel { Button("取消下载") { model.cancelModelDownload() }.controlSize(.small) }
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { buttons }
                    VStack(alignment: .leading, spacing: 10) { buttons }
                }
            }
            if !item.engine.supports(model.settings.language) {
                Text("此模型用于韩语识别，请将原文语言选为韩语。")
                    .font(.system(size: 11)).foregroundStyle(Palette.accent).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(17).background(Palette.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line.opacity(0.7)))
    }
    @ViewBuilder private var buttons: some View {
        if !installed {
            Button { model.requestModelDownload() } label: { Label("下载模型", systemImage: "arrow.down.circle") }
                .buttonStyle(.borderedProminent).tint(Palette.accent).disabled(model.modelManagementLocked)
        }
        Button("导入模型…") { model.importWhisper() }.disabled(model.modelManagementLocked || installed)
        if installed {
            Button(role: .destructive) { model.requestModelRemoval() } label: { Label("移除模型", systemImage: "trash") }
                .disabled(model.modelManagementLocked)
        }
    }
}

struct ModelInstallSheet: View {
    @ObservedObject var model: AppModel
    let item: LocalModel
    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.to.line.compact").font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Palette.accent).frame(width: 52, height: 52)
                    .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text("安装识别模型").font(.system(size: 20, weight: .semibold))
                    Text(item.title).font(.system(size: 13)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { model.modelInstallPrompt = nil } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(Palette.muted).keyboardShortcut(.cancelAction).accessibilityLabel("关闭安装提示")
            }
            Text(item.summary).font(.system(size: 13)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 0) {
                metric("下载大小", item.downloadSize)
                Rectangle().fill(Palette.line).frame(width: 1, height: 28)
                metric("安装后占用", item.installedSize)
                Rectangle().fill(Palette.line).frame(width: 1, height: 28)
                metric("识别方式", "本机运行")
            }.padding(.vertical, 16).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 10) {
                Label("下载来源", systemImage: "shippingbox").font(.system(size: 12, weight: .semibold))
                Text(item.repository).font(.system(size: 12)).foregroundStyle(Palette.muted).textSelection(.enabled)
                Text("模型由第三方提供，不包含在软件安装包中。点击下载后，从 Hugging Face 获取模型文件。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if item.needsConversion {
                    Text("下载原作者文件后，自动转换为本机格式；完成后清理下载的临时文件。")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
                if item.engine == .qwenASR {
                    Link("原始模型：Qwen / Qwen3-ASR-1.7B ↗", destination: URL(string: "https://huggingface.co/Qwen/Qwen3-ASR-1.7B")!).font(.system(size: 12))
                }
                Link("查看模型页面与授权信息 ↗", destination: item.pageURL).font(.system(size: 12, weight: .medium))
                Text(item.license).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            HStack {
                Label("声音仅在本机处理", systemImage: "lock.shield").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Button("取消") { model.modelInstallPrompt = nil }.keyboardShortcut(.cancelAction)
                Button("下载并安装") { model.confirmModelDownload(item) }.buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction)
            }.controlSize(.large)
        }.padding(28).frame(width: 540).background(.white).foregroundStyle(Palette.ink).tint(Palette.accent)
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 10)).foregroundStyle(Palette.muted)
            Text(value).font(.system(size: 13, weight: .semibold))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 17)
    }
}

struct AppleModelInstallSheet: View {
    let language: String
    let cancel: () -> Void
    let install: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("准备 Apple 识别语言", systemImage: "arrow.down.circle")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.accent)
            Text("Apple 系统识别 · \(language)").font(.system(size: 14, weight: .medium))
            Text("所需语言资源由 macOS 从 Apple 下载并管理，不包含在听桥安装包中。下载大小由系统确定，准备完成后可在本机识别。")
                .font(.system(size: 13)).foregroundStyle(Palette.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            Link("查看 Apple 听写说明 ↗", destination: URL(string: "https://support.apple.com/guide/mac-help/mh40584/mac")!).font(.system(size: 12))
            HStack { Spacer(); Button("取消", action: cancel).keyboardShortcut(.cancelAction); Button("下载语言资源", action: install).buttonStyle(.borderedProminent).tint(Palette.accent).keyboardShortcut(.defaultAction) }.controlSize(.large)
        }.padding(28).frame(width: 500).background(.white).foregroundStyle(Palette.ink)
    }
}
