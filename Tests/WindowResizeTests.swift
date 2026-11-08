import AppKit
import SwiftUI

@MainActor private final class ResizeState: ObservableObject {
    @Published var text = "第一段字幕"
    var rendered = ""
    var sizes: [CGSize] = []
}

private struct ResizeContent: View {
    @ObservedObject var state: ResizeState
    var body: some View {
        GeometryReader { geometry in
            Text(state.text).frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { state.sizes.append(geometry.size); state.rendered = state.text }
                .onChange(of: geometry.size) { _, size in state.sizes.append(size) }
                .onChange(of: state.text) { _, text in state.rendered = text }
        }
    }
}

@main struct WindowResizeTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { print("FAIL: \(message)"); fflush(stdout); exit(1) }
    }
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let state=ResizeState()
        let viewport=DeferredResizeContainer(rootView:ResizeContent(state:state))
        let window=NSWindow(contentRect:NSRect(x:-3000,y:-3000,width:1100,height:700),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.contentView=viewport;window.orderFront(nil)
        func settle() { RunLoop.main.run(until:Date().addingTimeInterval(0.06)) }
        settle()
        let initial=viewport.hostingView.frame
        print("Initial viewport \(viewport.bounds.size), hosted content \(initial.size), geometry updates \(state.sizes.count)");fflush(stdout)
        check(initial.size==viewport.bounds.size,"initial content fills the viewport")
        check(viewport.isFlipped && initial.origin == .zero,"content stays anchored at the top left")
        let sizeCount=state.sizes.count
        var commits=0
        viewport.hostingView.postsFrameChangedNotifications=true
        let token=NotificationCenter.default.addObserver(forName:NSView.frameDidChangeNotification,object:viewport.hostingView,queue:.main) { _ in commits += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        viewport.viewWillStartLiveResize()
        for step in 0..<120 {
            window.setContentSize(NSSize(width:1000+step*3,height:640+step*2))
            check(viewport.hostingView.frame==initial,"live resize leaves content dimensions unchanged")
        }
        settle()
        print("During drag: frame commits \(commits), geometry updates \(state.sizes.count), original updates \(sizeCount)");fflush(stdout)
        check(commits==0 && state.sizes.count==sizeCount,"dragging does not reflow hosted content")
        state.text="拖动期间继续收到的字幕"
        settle()
        check(state.rendered==state.text,"caption updates remain visible while dimensions are frozen")
        viewport.viewDidEndLiveResize();settle()
        check(viewport.hostingView.frame.size==viewport.bounds.size,"release commits the final viewport dimensions")
        check(commits==1,"a drag gesture performs one content resize")
        check(state.sizes.count==sizeCount+1,"SwiftUI receives only the final geometry update")

        window.setContentSize(NSSize(width:1200,height:760));settle()
        check(viewport.hostingView.frame.size==viewport.bounds.size,"programmatic resize remains immediate")
        let unchanged=commits
        viewport.viewWillStartLiveResize();viewport.viewDidEndLiveResize();settle()
        check(commits==unchanged,"a gesture without a size change adds no layout work")
        viewport.viewWillStartLiveResize()
        window.setContentSize(NSSize(width:1000,height:640))
        viewport.viewDidEndLiveResize();settle()
        check(viewport.hostingView.frame.size==NSSize(width:1000,height:640),"shrinking commits the final smaller size")
        check(state.rendered==state.text,"resize preserves caption state")
        window.orderOut(nil)
        print("PASS: \(checks) deferred resize checks; 120 drag sizes produced one final content resize.")
    }
}
