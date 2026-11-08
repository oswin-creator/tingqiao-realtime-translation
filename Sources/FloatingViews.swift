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

struct CaptionScrollObserver: NSViewRepresentable {
    var followsLatest: Bool
    var captions: [Caption]
    var onFollowChanged: (Bool) -> Void
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.configure(follow: followsLatest, captions: captions, onFollowChanged: onFollowChanged)
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        private weak var scroll: NSScrollView?
        private weak var document: NSView?
        private var tokens: [NSObjectProtocol] = []
        private var wheelMonitor: Any?
        private var pending: DispatchWorkItem?
        private var gestureEnd: DispatchWorkItem?
        private var onFollowChanged: ((Bool) -> Void)?
        private var following = true
        private var requestedFollow = true
        private var manualPause = false
        private var gestureActive = false
        private var lastCaptions: [Caption] = []
        private var viewportSize = NSSize.zero
        private var documentSize = NSSize.zero
        private var corrections = 0

        func configure(follow: Bool, captions: [Caption], onFollowChanged: @escaping (Bool) -> Void) {
            self.onFollowChanged = onFollowChanged
            if !follow { manualPause = false }
            if follow != requestedFollow {
                requestedFollow = follow
                following = follow && !manualPause
                if following { corrections = 3; schedule() }
                else { pending?.cancel() }
            }
            if captions != lastCaptions {
                lastCaptions = captions; corrections = 3
                if following { schedule() }
            }
            attach()
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachLater() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attachLater() }
        private func attachLater() { DispatchQueue.main.async { [weak self] in self?.attach() } }
        private func attach() {
            guard let enclosing = enclosingScrollView else { return }
            if scroll !== enclosing || document !== enclosing.documentView {
                detach(); scroll = enclosing; document = enclosing.documentView
                let center = NotificationCenter.default
                tokens.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: enclosing, queue: .main) { [weak self] _ in self?.beginGesture() })
                tokens.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: enclosing, queue: .main) { [weak self] _ in self?.settleGesture() })
                if let document {
                    document.postsFrameChangedNotifications = true
                    tokens.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in self?.documentChanged() })
                }
                wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let scroll = self.scroll, event.window === scroll.window,
                          scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return event }
                    self.beginGesture(); self.settleGesture()
                    return event
                }
                corrections = 3; schedule()
            }
            if viewportSize != enclosing.contentView.bounds.size {
                viewportSize = enclosing.contentView.bounds.size
                corrections = 3; schedule()
            }
        }
        func beginGesture() {
            gestureActive = true; manualPause = true; following = false
            pending?.cancel(); gestureEnd?.cancel()
            onFollowChanged?(false)
        }
        func settleGesture() {
            gestureEnd?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.gestureActive = false
                let follow = self.atBottom
                self.manualPause = false; self.following = follow
                self.onFollowChanged?(follow)
            }
            gestureEnd = item
            DispatchQueue.main.asyncAfter(deadline: .now()+0.2, execute: item)
        }
        private var atBottom: Bool {
            guard let scroll, let document else { return false }
            let visible = scroll.documentVisibleRect
            let distance = document.isFlipped ? document.bounds.maxY-visible.maxY : visible.minY-document.bounds.minY
            return distance <= 36
        }
        private func documentChanged() {
            guard let document, document.frame.size != documentSize else { return }
            documentSize = document.frame.size
            schedule()
        }
        private func schedule() {
            pending?.cancel()
            guard following, !gestureActive, corrections > 0 else { return }
            let item = DispatchWorkItem { [weak self] in self?.followBottom() }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now()+0.04, execute: item)
        }
        private func followBottom() {
            guard following, !gestureActive, corrections > 0, let scroll, let document else { return }
            let clip = scroll.contentView
            let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY-clip.bounds.height) : document.bounds.minY
            guard y.isFinite, abs(clip.bounds.minY-y) > 1 else { return }
            corrections -= 1
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }
        func detach() {
            pending?.cancel(); gestureEnd?.cancel()
            tokens.forEach(NotificationCenter.default.removeObserver); tokens.removeAll()
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
            wheelMonitor = nil; scroll = nil; document = nil
        }
        deinit { detach() }
    }
}

struct CaptionScroll<Content: View>: View {
    @Binding var followsLatest: Bool
    let captions: [Caption]
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content.background(CaptionScrollObserver(followsLatest: followsLatest, captions: captions) { follow in
                if followsLatest != follow { followsLatest = follow }
            })
        }
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
