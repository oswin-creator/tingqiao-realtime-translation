import AppKit
import SwiftUI

struct RecordActions: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Button { model.export() } label: { Label("导出 TXT", systemImage: "square.and.arrow.up") }
                .disabled(model.allCaptions.isEmpty)
            Button { model.clearHistory() } label: { Label("清空记录", systemImage: "trash") }
                .disabled(model.visibleJobs.isEmpty || model.isClearing)
            if model.canUndoClear {
                Menu {
                    Button("撤销上一次清空") { model.undoClear() }
                    Divider()
                    Button("永久删除最近清除的记录（\(model.deletedCount) 段）") { model.purgeDeleted() }
                } label: { Label("撤销清空", systemImage: "arrow.uturn.backward") }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Palette.muted)
    }
}

final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class FloatingWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

// Observe only user-initiated scrolling, so programmatic scrolling cannot disable follow.
struct CaptionScrollObserver: NSViewRepresentable {
    var onFollowChanged: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.onFollowChanged = onFollowChanged; return view }
    func updateNSView(_ view: Probe, context: Context) { view.onFollowChanged = onFollowChanged; view.attach() }
    final class Probe: NSView {
        var onFollowChanged: ((Bool) -> Void)?
        private weak var observedScroll: NSScrollView?
        private var tokens: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); DispatchQueue.main.async { [weak self] in self?.attach() } }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); DispatchQueue.main.async { [weak self] in self?.attach() } }
        func attach() {
            guard let scroll = enclosingScrollView, scroll !== observedScroll else { return }
            tokens.forEach(NotificationCenter.default.removeObserver); tokens.removeAll()
            observedScroll = scroll
            tokens.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in self?.onFollowChanged?(false) })
            tokens.append(NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self, weak scroll] _ in
                guard let scroll, let document = scroll.documentView else { return }
                let visible = scroll.documentVisibleRect
                let distance = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
                self?.onFollowChanged?(distance < 36)
            })
        }
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

// scrollTo can synchronously lay out a lazy stack. Run it after the current
// SwiftUI update and coalesce requests when several captions arrive together.
private final class CaptionScrollRequests: ObservableObject {
    private var pending: DispatchWorkItem?

    func schedule(_ scroll: @escaping () -> Void) {
        cancel()
        let item = DispatchWorkItem(block: scroll)
        pending = item
        DispatchQueue.main.async(execute: item)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

struct CaptionScroll<Content: View>: View {
    @StateObject private var requests = CaptionScrollRequests()
    @Binding var followsLatest: Bool
    let captions: [Caption]
    @ViewBuilder var content: Content
    private let end = "caption-scroll-end"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    content
                    Color.clear.frame(height: 1).id(end)
                }.background(CaptionScrollObserver { follow in
                    if followsLatest != follow { followsLatest = follow }
                })
            }
            .onAppear { if followsLatest { scrollAfterLayout(proxy) } }
            .onChange(of: captions) { if followsLatest { scrollAfterLayout(proxy) } }
            .onChange(of: followsLatest) {
                if followsLatest { scrollAfterLayout(proxy) } else { requests.cancel() }
            }
            .background(GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size) { if followsLatest { scrollAfterLayout(proxy) } }
            })
            .onDisappear { requests.cancel() }
        }
    }

    private func scrollAfterLayout(_ proxy: ScrollViewProxy) {
        requests.schedule { [end] in proxy.scrollTo(end, anchor: .bottom) }
    }
}

struct FloatingCaptions: View {
    @ObservedObject var model: AppModel
    private var opacity: Binding<Double> {
        Binding(get: { 1 - model.settings.floatingOpacity }, set: {
            model.settings.floatingOpacity = $0 >= 0.999 ? 0 : 1 - $0
            model.updateFloatingAppearance()
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.accent)
                Text("听桥字幕").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink).fixedSize()
                Spacer(minLength: 0)
                if !model.floatingFollowsLatest {
                    Button { model.floatingFollowsLatest = true } label: { Image(systemName: "arrow.down.to.line") }.help("回到最新字幕")
                }
                HStack(spacing: 4) {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 10))
                    Slider(value: opacity, in: 0...1).frame(width: 70).help("背景透明度").accessibilityLabel("背景透明度")
                }
                Button {
                    model.settings.floatingAlwaysOnTop.toggle(); model.updateFloatingAppearance()
                } label: { Image(systemName: model.settings.floatingAlwaysOnTop ? "pin.fill" : "pin")
                        .foregroundStyle(model.settings.floatingAlwaysOnTop ? Palette.accent : Palette.muted) }
                    .help(model.settings.floatingAlwaysOnTop ? "取消始终置顶" : "始终置顶")
                    .accessibilityLabel("始终置顶")
                Divider().frame(height: 14).opacity(model.settings.floatingOpacity)
                Button { changeFont(-2) } label: { Image(systemName: "textformat.size.smaller") }.help("减小字幕字号")
                    .disabled(model.settings.floatingFontSize <= 12)
                Text("\(Int(model.settings.floatingFontSize))").monospacedDigit().font(.system(size: 10)).frame(width: 18)
                Button { changeFont(2) } label: { Image(systemName: "textformat.size.larger") }.help("增大字幕字号")
                    .disabled(model.settings.floatingFontSize >= 48)
            }.buttonStyle(.plain).foregroundStyle(Palette.muted).padding(.leading, 76).padding(.trailing, 12).frame(height: 34)
            HStack {
                Text("实时字幕").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                Spacer()
                AssistantButtons(model: model, compact: true)
            }.padding(.horizontal, 13).padding(.vertical, 4)
            Divider().overlay(Palette.line).opacity(model.settings.floatingOpacity)
            if model.allCaptions.isEmpty {
                Text("等待下一句对话…").foregroundStyle(Palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CaptionScroll(followsLatest: $model.floatingFollowsLatest, captions: model.allCaptions) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.allCaptions) { caption in
                            VStack(alignment: .leading, spacing: 4) {
                                if !caption.original.isEmpty && (model.settings.showOriginal || caption.isDraft == true || caption.translated.isEmpty) {
                                    Text(caption.original).font(.system(size: max(11, model.settings.floatingFontSize * 0.62))).foregroundStyle(Palette.muted)
                                }
                                Text(caption.displayText)
                                    .font(.system(size: model.settings.floatingFontSize, weight: .medium)).foregroundStyle(Palette.ink)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                                .background(.white.opacity(0.78 * model.settings.floatingOpacity), in: RoundedRectangle(cornerRadius: 10)).textSelection(.enabled)
                        }
                    }.padding(10)
                }
            }
            AssistantReplyRegion(presentation: model.assistantPresentation, compact: true)
        }.background(LinearGradient(colors: [.white.opacity(model.settings.floatingOpacity), Palette.canvas.opacity(model.settings.floatingOpacity), Palette.sidebar.opacity(model.settings.floatingOpacity)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.captionSurfaceOpacity, model.settings.floatingOpacity)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .ignoresSafeArea(.container, edges: .top).preferredColorScheme(.light)
    }
    private func changeFont(_ delta: Double) {
        model.settings.floatingFontSize = min(48, max(12, model.settings.floatingFontSize + delta))
        model.updateFloatingAppearance()
    }
}
