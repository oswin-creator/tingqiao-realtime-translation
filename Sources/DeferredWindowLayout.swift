import AppKit
import SwiftUI

final class DeferredResizeContainer<Content: View>: NSView {
    let hostingView: NSHostingView<Content>
    private var resizing = false
    override var isFlipped: Bool { true }

    init(rootView: Content, background: NSColor = .clear) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        layer?.masksToBounds = true
        hostingView.sizingOptions = []
        hostingView.safeAreaRegions = []
        hostingView.autoresizingMask = []
        addSubview(hostingView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeContent()
    }
    override func layout() {
        super.layout()
        resizeContent()
    }
    override func viewWillStartLiveResize() {
        resizing = true
        super.viewWillStartLiveResize()
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        resizing = false
        resizeContent()
    }
    private func resizeContent() {
        guard !resizing, bounds.width > 0, bounds.height > 0 else { return }
        let frame = NSRect(origin: .zero, size: bounds.size)
        if hostingView.frame != frame { hostingView.frame = frame }
    }
}

struct DeferredWindowLayout<Content: View>: NSViewRepresentable {
    var background: NSColor = .clear
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> DeferredResizeContainer<Content> {
        DeferredResizeContainer(rootView: content, background: background)
    }
    func updateNSView(_ view: DeferredResizeContainer<Content>, context: Context) {
        view.hostingView.rootView = content
    }
}
