import Foundation
import Darwin

@main struct DiagnosticsTests {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 2 {
            let root = URL(fileURLWithPath: args[1], isDirectory: true)
            let diagnostics = Diagnostics(root: root)
            diagnostics.record(.saveStart, value: 2500)
            await MainActor.run { blockInterface() }
            await diagnostics.finish()
            return
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-diagnostics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let normal = Diagnostics(root: root)
        normal.record(.userMarker)
        await normal.finish()

        let child = Process()
        child.executableURL = URL(fileURLWithPath: args[0]).standardizedFileURL
        child.arguments = [root.path]
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

        let deadline = ProcessInfo.processInfo.systemUptime + 14
        var capture = ""
        while ProcessInfo.processInfo.systemUptime < deadline {
            let runs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            for run in runs where FileManager.default.fileExists(atPath: run.appendingPathComponent("active").path) {
                capture = (try? String(contentsOf: run.appendingPathComponent("events.txt"), encoding: .utf8)) ?? ""
                if capture.contains(" sample_saved") || capture.contains(" sample_unavailable") { break }
            }
            if capture.contains(" sample_saved") || capture.contains(" sample_unavailable") { break }
            try await Task.sleep(for: .milliseconds(150))
        }
        precondition(capture.contains(" hang value="), "The watchdog did not run while the main thread was blocked")
        precondition(kill(child.processIdentifier, SIGKILL) == 0)
        child.waitUntilExit()

        let restarted = Diagnostics(root: root)
        let report = try await restarted.report()
        precondition(report.contains(" user_marker") && report.contains(" clean_exit"))
        precondition(report.contains(" save_start value=2500") && report.contains(" hang value="))
        precondition(report.components(separatedBy: " unexpected_exit\n").count == 2)
        if capture.contains(" sample_saved") {
            precondition(report.contains("主线程采样 hang-1.txt") && report.contains("NSThread sleepForTimeInterval"))
            precondition(!report.contains("Binary Images:") && !report.contains("Path:"))
            print("PASS: background watchdog captures a main-thread stack and retains it across a forced restart")
        } else {
            precondition(report.contains(" sample_unavailable"))
            print("PASS: background watchdog records a hang across a forced restart even when system sampling fails")
        }
        await restarted.finish()
    }

    @inline(never) private static func blockInterface() {
        Thread.sleep(forTimeInterval: 25)
    }
}
