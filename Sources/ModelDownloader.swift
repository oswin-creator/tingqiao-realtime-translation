import Foundation

struct ModelDownloadSnapshot: Sendable {
    let receivedBytes: Int64
    let totalBytes: Int64
    var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }
}

final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let update: @Sendable (ModelDownloadSnapshot) -> Void
    private let lock = NSLock()
    private var pending: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var savedFile: URL?
    private var fileError: Error?
    private var lastProgress = -1.0
    private var lastUpdate = -Double.infinity

    init(expectedBytes: Int64, update: @escaping @Sendable (ModelDownloadSnapshot) -> Void) {
        self.expectedBytes = expectedBytes; self.update = update
    }
    func download(from url: URL, session: URLSession) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                let download = session.downloadTask(with: url)
                pending = continuation; task = download
                lock.unlock()
                download.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let download = task; lock.unlock()
        download?.cancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        let snapshot = ModelDownloadSnapshot(receivedBytes: totalBytesWritten, totalBytes: total)
        let now = ProcessInfo.processInfo.systemUptime
        if snapshot.fraction - lastProgress >= 0.005 || now - lastUpdate >= 0.2 || snapshot.fraction >= 1 {
            lastProgress = snapshot.fraction; lastUpdate = now; update(snapshot)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-model-\(UUID()).download")
        do { try FileManager.default.moveItem(at: location, to: target); savedFile = target }
        catch { fileError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<(URL, URLResponse), Error>
        if let error = error ?? fileError {
            if let savedFile { try? FileManager.default.removeItem(at: savedFile) }
            result = .failure(error)
        } else if let file = savedFile, let response = task.response { result = .success((file, response)) }
        else { result = .failure(URLError(.cannotCreateFile)) }
        lock.lock(); let continuation = pending; pending = nil; self.task = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}
