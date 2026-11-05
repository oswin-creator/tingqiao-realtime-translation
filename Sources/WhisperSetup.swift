import Foundation
import AppKit
import CryptoKit

enum WhisperModelFile {
    static let sha256 = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    static let bytes: Int64 = 1_624_555_275
    static func install(from source: URL) throws {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size == bytes else { throw BridgeError("模型大小不正确，需要完整的 ggml-large-v3-turbo.bin（约 1.6 GB）。", retryable: false) }
        let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
        var digest = SHA256()
        while let block = try handle.read(upToCount: 4_194_304), !block.isEmpty { digest.update(data: block) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256 else { throw BridgeError("模型校验未通过，请重新下载官方模型。", retryable: false) }
        let target = WhisperEngine.modelURL
        if source.standardizedFileURL == target.standardizedFileURL { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".part")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.copyItem(at: source, to: staged)
        if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: target) }
    }
}

extension AppModel {
    func downloadWhisper() {
        guard !downloadingWhisper, !isRunning, !isStarting, !isStopping else { return }
        whisperInstalled = WhisperEngine.installed
        guard !whisperInstalled else {
            recognitionInfo = "Whisper large-v3-turbo 已安装，无需重复下载。"
            return
        }
        downloadingWhisper = true; recognitionInfo = "正在下载约 1.6 GB 的模型，请保持联网…"
        Task {
            defer { downloadingWhisper = false }
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (url, response) = try await session.download(from: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/98aa99a0a9db05ae2342309f5096248665f7cba3/ggml-large-v3-turbo.bin")!)
                defer { try? FileManager.default.removeItem(at: url) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BridgeError("模型下载失败，也可以下载后使用“导入已有模型”。") }
                recognitionInfo = "下载完成，正在校验模型…"
                try await Task.detached { try WhisperModelFile.install(from: url) }.value
                whisperInstalled = true; recognitionInfo = "Whisper large-v3-turbo 已准备好。"
            } catch { recognitionInfo = "下载未完成：\(error.localizedDescription)" }
        }
    }
    func importWhisper() {
        guard !downloadingWhisper, !isRunning, !isStarting else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择官方 ggml-large-v3-turbo.bin 模型文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadingWhisper = true; recognitionInfo = "正在校验并导入模型…"
        Task {
            defer { downloadingWhisper = false }
            do { try await Task.detached { try WhisperModelFile.install(from: url) }.value; whisperInstalled = true; recognitionInfo = "模型已导入。" }
            catch { recognitionInfo = error.localizedDescription }
        }
    }
}
