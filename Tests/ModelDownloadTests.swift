import Foundation

final class DownloadEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ModelDownloadSnapshot] = []
    func append(_ snapshot: ModelDownloadSnapshot) { lock.lock(); events.append(snapshot); lock.unlock() }
    var values: [ModelDownloadSnapshot] { lock.lock(); defer { lock.unlock() }; return events }
}
@main struct ModelDownloadTests {
    static func main() async throws {
        let port = try String(contentsOfFile: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/tests/download-progress-port", encoding: .utf8)
        for path in ["known", "unknown"] {
            let events = DownloadEvents()
            let worker = ModelDownloader(expectedBytes: 2*1024*1024) { events.append($0) }
            let session = URLSession(configuration: .ephemeral, delegate: worker, delegateQueue: nil)
            let (file,response) = try await worker.download(from: URL(string:"http://127.0.0.1:\(port)/\(path)")!, session: session)
            defer { try? FileManager.default.removeItem(at: file); session.invalidateAndCancel() }
            let values = events.values
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
            precondition(values.count > 2 && values.contains { $0.fraction > 0 && $0.fraction < 1 })
            precondition(values.allSatisfy { $0.totalBytes == 2*1024*1024 })
            precondition(values.last!.receivedBytes == 2*1024*1024 && values.last!.fraction == 1)
            let content = try Data(contentsOf: file)
            precondition(content == Data(repeating: 120,count:2*1024*1024))
            print("PASS: \(path) length, \(values.count) updates, file preserved through validation handoff")
        }
        for cancelTask in [false, true] {
        let worker = ModelDownloader(expectedBytes: 2*1024*1024) { _ in }
        let session = URLSession(configuration: .ephemeral, delegate: worker, delegateQueue: nil)
        let operation = Task { try await worker.download(from: URL(string:"http://127.0.0.1:\(port)/unknown")!, session: session) }
        try await Task.sleep(nanoseconds: 120_000_000)
        if cancelTask { operation.cancel() } else { session.invalidateAndCancel() }
        defer { session.invalidateAndCancel() }
        do { let (file,_) = try await operation.value; try? FileManager.default.removeItem(at: file); preconditionFailure("cancel did not cancel") }
        catch { print("PASS: \(cancelTask ? "task" : "session") cancellation resumes download with error") }
        }
    }
}
