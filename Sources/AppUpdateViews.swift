import SwiftUI

private final class AppUpdatePresentation: ObservableObject {
    @Published var showing = false
}

struct AppUpdateButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: AppUpdateController
    @StateObject private var presentation = AppUpdatePresentation()
    var body: some View {
        Button {
            presentation.showing = true; updates.check()
        } label: {
            Label("检查更新", systemImage: "arrow.down.circle")
                .font(.system(size: 10)).foregroundStyle(Palette.accent)
        }.buttonStyle(.plain)
            .sheet(isPresented: $presentation.showing) {
                AppUpdateView(model: model, updates: updates) { presentation.showing = false }
            }
    }
}

private struct AppUpdateView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: AppUpdateController
    var dismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 30)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("听桥更新").font(.system(size: 20, weight: .semibold))
                    Text("当前版本 \(AppUpdateController.currentVersion)").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            if updates.checking {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在检查 GitHub 最新版本…") }
            } else if updates.preparing {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在校验安装包，随后重开听桥…") }
            } else if updates.downloading {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: updates.progress).tint(Palette.accent)
                    Text("已下载 \(ByteCountFormatter.string(fromByteCount: updates.received, countStyle: .file)) · \(Int(updates.progress*100))%")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            } else if let release = updates.offer {
                VStack(alignment: .leading, spacing: 10) {
                    Text("发现新版本 \(release.version.description)").font(.system(size: 16, weight: .semibold))
                    Text("更新后自动重开，模型、记录和设置会保留。")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Link("查看更新内容 ↗", destination: release.page).font(.system(size: 12))
                    if !model.canInstallAppUpdate {
                        Text("结束收音和当前任务后即可安装。")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
            }
            if !updates.message.isEmpty {
                Text(updates.message).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("来源：GitHub · oswin-creator").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                Button(updates.downloading ? "取消下载" : "关闭") { updates.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(updates.preparing)
                if updates.offer != nil && !updates.busy {
                    Button("下载并更新") { model.installAppUpdate() }
                        .buttonStyle(.borderedProminent).tint(Palette.accent).disabled(!model.canInstallAppUpdate)
                }
            }
        }.padding(28).frame(width: 450).foregroundStyle(Palette.ink).background(.white).preferredColorScheme(.light)
    }
}
