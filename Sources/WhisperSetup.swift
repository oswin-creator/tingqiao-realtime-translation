import Foundation
import AppKit

extension AppModel {
    func refreshLocalModels() {
        installedLocalModels = Set(LocalModel.all.filter { LocalModelFiles.installed($0) }.map(\.engine))
        whisperInstalled = installedLocalModels.contains(.whisperTurbo)
    }
    func requestModelDownload() {
        guard !modelManagementLocked, let model = LocalModel.find(settings.recognitionEngine) else { return }
        refreshLocalModels()
        guard !installedLocalModels.contains(model.engine) else { return }
        modelInstallPrompt = model
    }
    func downloadWhisper() { requestModelDownload() }
    func confirmModelDownload(_ model: LocalModel) {
        modelInstallPrompt = nil
        guard !modelManagementLocked else { return }
        refreshLocalModels()
        guard !installedLocalModels.contains(model.engine) else { return }
        downloadingWhisper = true; downloadingModel = model.engine; modelDownloadProgress = 0; modelDownloadedBytes = 0
        modelDownloadCanCancel = true
        recognitionInfo = "正在下载 \(model.title)…"
        Task {
            defer {
                modelDownloadSession?.invalidateAndCancel(); modelDownloadSession = nil
                downloadingWhisper = false; downloadingModel = nil; modelDownloadProgress = nil
                modelDownloadCanCancel = false; refreshLocalModels()
            }
            do {
                let required = model.needsConversion ? model.bytes + 1_600_000_000 : model.bytes
                try FileManager.default.createDirectory(at: LocalModel.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if let space = try? LocalModel.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   space < required + 500_000_000 { throw BridgeError("可用空间不足，请腾出约 \(String(format: "%.1f", Double(required + 500_000_000) / 1_000_000_000)) GB 后重试。", retryable: false) }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 120
                configuration.timeoutIntervalForResource = 14_400
                let progress = ModelDownloader(expectedBytes: model.bytes) { [weak self = self] snapshot in
                    Task { @MainActor in
                        guard self?.downloadingModel == model.engine, self?.modelDownloadCanCancel == true else { return }
                        self?.modelDownloadProgress = snapshot.fraction
                        self?.modelDownloadedBytes = snapshot.receivedBytes
                    }
                }
                let session = URLSession(configuration: configuration, delegate: progress, delegateQueue: nil)
                modelDownloadSession = session
                let (url, response) = try await progress.download(from: model.downloadURL, session: session)
                defer { try? FileManager.default.removeItem(at: url) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BridgeError("模型下载失败，请稍后重试，也可以导入已有模型。") }
                modelDownloadCanCancel = false; modelDownloadProgress = nil
                recognitionInfo = model.needsConversion ? "正在校验并准备本机模型…" : "正在校验模型…"
                try await Task.detached(priority: .utility) { try LocalModelFiles.install(url, model: model, moveSource: true) }.value
                recognitionInfo = "\(model.title) 已准备好。"
            } catch let error as URLError where error.code == .cancelled { recognitionInfo = "已取消下载。" }
            catch { recognitionInfo = "下载未完成：\(error.localizedDescription)" }
        }
    }
    func cancelModelDownload() { guard modelDownloadCanCancel else { return }; modelDownloadSession?.invalidateAndCancel() }
    func importWhisper() {
        guard !modelManagementLocked, let model = LocalModel.find(settings.recognitionEngine) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "选择 \(model.title) 的 \(model.downloadFile) 文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadingWhisper = true; downloadingModel = model.engine; modelDownloadProgress = nil
        recognitionInfo = "正在校验并导入模型…"
        Task {
            defer { downloadingWhisper = false; downloadingModel = nil; refreshLocalModels() }
            do {
                try await Task.detached(priority: .utility) { try LocalModelFiles.install(url, model: model) }.value
                recognitionInfo = "\(model.title) 已导入。"
            } catch { recognitionInfo = error.localizedDescription }
        }
    }
    func requestModelRemoval() {
        guard !modelManagementLocked, let model = LocalModel.find(settings.recognitionEngine) else { return }
        modelRemovalPrompt = model
    }
    func removeLocalModel(_ model: LocalModel) {
        modelRemovalPrompt = nil
        guard !modelManagementLocked else { return }
        WhisperEngine.shared.stop()
        do { try LocalModelFiles.remove(model); recognitionInfo = "已移除 \(model.title)。" }
        catch { recognitionInfo = "移除未完成：\(error.localizedDescription)" }
        refreshLocalModels()
    }
}
