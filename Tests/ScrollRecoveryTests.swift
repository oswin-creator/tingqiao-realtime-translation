import AppKit
import Combine

private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
@main struct ScrollRecoveryTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x:0,y:0,width:320,height:220))
        let document = FlippedDocument(frame: NSRect(x:0,y:0,width:320,height:3000))
        scroll.documentView = document
        let probe = CaptionScrollObserver.Probe(frame: .zero); document.addSubview(probe)
        var following: [Bool] = []
        var captions = [Caption(id:UUID(),date:Date(),original:"한글",translated:"测试字幕")]
        func configure(_ follow: Bool) { probe.configure(follow:follow,captions:captions) { following.append($0) } }
        func wait(_ seconds: Double = 0.15) { RunLoop.main.run(until:Date().addingTimeInterval(seconds)) }
        configure(true);wait()
        check(abs(scroll.documentVisibleRect.maxY-document.bounds.maxY)<2,"first captions reach the bottom")
        probe.beginGesture()
        scroll.contentView.scroll(to:NSPoint(x:0,y:140));scroll.reflectScrolledClipView(scroll.contentView)
        captions.append(Caption(id:UUID(),date:Date(),original:"다음 문장",translated:"新字幕"))
        configure(true);wait()
        check(abs(scroll.contentView.bounds.minY-140)<2,"gesture pauses follow before binding update")
        configure(false);probe.settleGesture();wait(0.3)
        check(following.first==false && following.last==false,"scrolling older content keeps follow paused")
        document.setFrameSize(NSSize(width:320,height:3600));wait()
        check(abs(scroll.contentView.bounds.minY-140)<2,"new content does not pull a paused reader down")
        configure(true);wait()
        check(abs(scroll.documentVisibleRect.maxY-document.bounds.maxY)<2,"back-to-latest resumes native scrolling")
        document.setFrameSize(NSSize(width:320,height:4000));wait()
        check(abs(scroll.documentVisibleRect.maxY-document.bounds.maxY)<2,"document growth continues following")
        probe.beginGesture();configure(false)
        scroll.contentView.scroll(to:NSPoint(x:0,y:document.bounds.maxY-scroll.contentView.bounds.height))
        probe.settleGesture();wait(0.3)
        check(following.last==true,"manual return to bottom re-enables following")
        probe.detach();let stopped=scroll.contentView.bounds.minY
        document.setFrameSize(NSSize(width:320,height:4500));wait()
        check(abs(scroll.contentView.bounds.minY-stopped)<2,"detached view has no delayed scroll")

        let root=FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-meter-test-\(UUID())")
        let model=AppModel(store:try SessionStore(root:root),settings:AppSettings(),startBackgroundWork:false)
        var rootUpdates=0, meterUpdates=0
        let rootToken=model.objectWillChange.sink { rootUpdates += 1 }
        let meterToken=model.audioLevel.objectWillChange.sink { meterUpdates += 1 }
        for i in 0..<100 { model.level=Double(i)/100 }
        check(rootUpdates==0 && meterUpdates==100,"audio levels refresh only the meter, not the workspace")
        check(model.level==0.99,"meter value remains available to capture code")
        withExtendedLifetime((rootToken,meterToken)) {}
        check(model.canInstallAppUpdate,"idle app can install an update")
        model.isRunning=true
        check(!model.canInstallAppUpdate,"recording cannot be interrupted by installation")
        model.isRunning=false;model.downloadingModel = .whisperTurbo
        check(!model.canInstallAppUpdate,"model downloads finish before application replacement")
        model.downloadingModel=nil;model.choosingMeetingDomains=true
        check(!model.canInstallAppUpdate,"starting a meeting prevents installation")
        model.choosingMeetingDomains=false
        check(model.canInstallAppUpdate,"installation becomes available after tasks finish")
        try? FileManager.default.removeItem(at:root)
        print("PASS: \(checks) scroll and meter recovery checks")
    }
}
