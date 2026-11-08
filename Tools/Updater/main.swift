import Foundation
import AppKit
import Darwin

@main struct TingQiaoUpdater {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        guard args.count == 6, args[1] == "--install", let parent = Int32(args[2]), parent > 1 else { exit(2) }
        let staged = URL(fileURLWithPath: args[3]), target = URL(fileURLWithPath: args[4]), report = URL(fileURLWithPath: args[5])
        var previous: URL?
        func record(_ message: String) { try? Data(message.utf8).write(to: report, options: .atomic) }
        do {
            _ = try UpdateInstallation.bundleVersion(target)
            _ = try UpdateInstallation.bundleVersion(staged)
            let deadline = Date().addingTimeInterval(60)
            while kill(parent, 0) == 0 || errno == EPERM {
                guard Date() < deadline else { throw NSError(domain: "TingQiaoUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: "听桥尚未退出，更新未安装。请稍后重试。"])}
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            previous = try UpdateInstallation.replace(staged: staged, target: target)
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
            if let previous { try? FileManager.default.removeItem(at: previous) }
            record("已更新到 \(try UpdateInstallation.bundleVersion(target))")
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
            exit(0)
        } catch {
            if let previous { try? UpdateInstallation.restore(previous: previous, target: target) }
            record("更新未完成：\(error.localizedDescription)")
            _ = try? await NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration())
            exit(1)
        }
    }
}
