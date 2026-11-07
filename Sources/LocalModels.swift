import Foundation
import CryptoKit

struct LocalModel: Identifiable, Sendable {
    let engine: RecognitionEngine
    let repository: String
    let revision: String
    let downloadFile: String
    let installedFile: String
    let sha256: String
    let bytes: Int64
    let installedSize: String
    let summary: String
    let license: String
    var id: String { engine.rawValue }
    var title: String { engine.rawValue }
    var needsConversion: Bool { engine == .whisperKomix }
    var downloadSize: String { String(format: "%.2f GB", Double(bytes) / 1_000_000_000) }
    var pageURL: URL { URL(string: "https://huggingface.co/\(repository)")! }
    var downloadURL: URL { URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(downloadFile)")! }
    var fileURL: URL { Self.directory.appendingPathComponent(installedFile) }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TingQiao/Models", isDirectory: true)
    }
    static let all: [LocalModel] = [
        LocalModel(engine: .whisperTurbo, repository: "ggerganov/whisper.cpp", revision: "98aa99a0a9db05ae2342309f5096248665f7cba3",
            downloadFile: "ggml-large-v3-turbo.bin", installedFile: "ggml-large-v3-turbo.bin",
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", bytes: 1_624_555_275,
            installedSize: "1.62 GB", summary: "多语言本机识别，兼顾速度与准确率。", license: "MIT"),
        LocalModel(engine: .whisperKomix, repository: "seastar105/whisper-medium-komixv2", revision: "752b1b5bfa0c8219bca737ea180a4ad7eed1e621",
            downloadFile: "model.safetensors", installedFile: "ggml-medium-komixv2.bin",
            sha256: "8ce118afc03743d449ec266c3f0ada1027ac9e51c10fe34e13846b902d47c5d0", bytes: 3_055_544_304,
            installedSize: "约 1.53 GB", summary: "针对韩语微调的 Whisper Medium，适合韩语课堂与会议。", license: "许可与使用条件见原作者页面"),
        LocalModel(engine: .qwenASR, repository: "handy-computer/Qwen3-ASR-1.7B-gguf", revision: "0e0a596e3959c3f3f2ab7d443a5b6f0f4a4bba6f",
            downloadFile: "Qwen3-ASR-1.7B-Q8_0.gguf", installedFile: "Qwen3-ASR-1.7B-Q8_0.gguf",
            sha256: "9a0d81792dfea2d5f278b8a63deb3ea6e02139ce42c2301f32ea19c4f77526b7", bytes: 2_185_030_624,
            installedSize: "2.19 GB", summary: "Qwen 多语言识别，使用适合 Apple 芯片的 Q8 本机版本。", license: "Apache-2.0"),
        LocalModel(engine: .whisperLarge, repository: "ggerganov/whisper.cpp", revision: "5359861c739e955e79d9a303bcbc70fb988958b1",
            downloadFile: "ggml-large-v3.bin", installedFile: "ggml-large-v3.bin",
            sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2", bytes: 3_095_033_483,
            installedSize: "3.10 GB", summary: "完整版 Whisper Large V3，侧重准确率，识别耗时较长。", license: "MIT")
    ]
    static func find(_ engine: RecognitionEngine) -> LocalModel? { all.first { $0.engine == engine } }
}

enum LocalModelFiles {
    struct Receipt: Codable {
        let engine: RecognitionEngine
        let sourceSHA256: String
        let fileSHA256: String
        let bytes: Int64
    }
    static func receiptURL(_ target: URL) -> URL { target.appendingPathExtension("installed.json") }
    static func installed(_ model: LocalModel, at target: URL? = nil) -> Bool {
        let target = target ?? model.fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        if !model.needsConversion { return size == model.bytes }
        guard let data = try? Data(contentsOf: receiptURL(target)), let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return false }
        return receipt.engine == model.engine && receipt.sourceSHA256 == model.sha256 && receipt.bytes == size && size > 1_000_000_000
    }
    static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var digest = SHA256()
        while let block = try handle.read(upToCount: 4_194_304), !block.isEmpty {
            try Task.checkCancellation(); digest.update(data: block)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func verify(_ source: URL, bytes: Int64, sha256: String) throws {
        let size = (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard Int64(size) == bytes else { throw BridgeError("模型文件不完整，请重新下载或选择对应的原始文件。", retryable: false) }
        guard try hash(source) == sha256 else { throw BridgeError("模型校验未通过，请重新下载。", retryable: false) }
    }
    static func publish(_ source: URL, to target: URL, moveSource: Bool = false) throws {
        if source.standardizedFileURL == target.standardizedFileURL { return }
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staged = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".part")
        defer { try? fm.removeItem(at: staged) }
        if moveSource { try fm.moveItem(at: source, to: staged) }
        else { try fm.copyItem(at: source, to: staged) }
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: staged) }
        else { try fm.moveItem(at: staged, to: target) }
    }
    static func install(_ source: URL, model: LocalModel, moveSource: Bool = false) throws {
        try verify(source, bytes: model.bytes, sha256: model.sha256)
        if !model.needsConversion { try publish(source, to: model.fileURL, moveSource: moveSource); return }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "TingQiaoWhisper"),
              let template = Bundle.main.url(forResource: "whisper-medium-vocab", withExtension: "bin") else {
            throw BridgeError("当前安装缺少模型转换工具，请使用完整安装包。", retryable: false)
        }
        try FileManager.default.createDirectory(at: LocalModel.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let converted = LocalModel.directory.appendingPathComponent(UUID().uuidString + ".part")
        defer { try? FileManager.default.removeItem(at: converted) }
        let process = Process(); process.executableURL = helper
        process.arguments = ["--convert-komix", source.path, template.path, converted.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BridgeError("模型转换未完成，请检查可用空间后重试。", retryable: false) }
        let digest = try hash(converted)
        let size = Int64(try converted.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let receipt = Receipt(engine: model.engine, sourceSHA256: model.sha256, fileSHA256: digest, bytes: size)
        if FileManager.default.fileExists(atPath: model.fileURL.path) { _ = try FileManager.default.replaceItemAt(model.fileURL, withItemAt: converted) }
        else { try FileManager.default.moveItem(at: converted, to: model.fileURL) }
        try JSONEncoder().encode(receipt).write(to: receiptURL(model.fileURL), options: .atomic)
    }
    @discardableResult
    static func repairKomixVocabulary(_ model: LocalModel, at target: URL? = nil, template: URL) throws -> Bool {
        guard model.engine == .whisperKomix else { return false }
        let target = target ?? model.fileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return false }
        let metadata = try Data(contentsOf: template)
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard digest(metadata) == "49639ac8580c3985225c05981ed17f85c8d193ebeaaab3bde2a0cddc38d2eb56" else {
            throw BridgeError("KomixV2 编码表校验失败，请使用完整安装包。", retryable: false)
        }
        let input = try FileHandle(forReadingFrom: target); defer { try? input.close() }
        let prefix = try input.read(upToCount: 575_451) ?? Data()
        if prefix.prefix(metadata.count) == metadata { return false }
        guard prefix.count == 575_451, digest(prefix) == "f676437ddef445443e95fc77d88d59013e9f6dc05d25ebcbabd89abeefc5565b" else {
            throw BridgeError("KomixV2 文件格式不匹配，请重新导入模型。", retryable: false)
        }
        let receiptData = try Data(contentsOf: receiptURL(target))
        let receipt = try JSONDecoder().decode(Receipt.self, from: receiptData)
        try verify(target, bytes: receipt.bytes, sha256: receipt.fileSHA256)
        guard receipt.engine == .whisperKomix, receipt.sourceSHA256 == model.sha256 else {
            throw BridgeError("KomixV2 模型校验未通过，请重新导入模型。", retryable: false)
        }
        let staged = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".part")
        let stagedReceipt = receiptURL(staged)
        let backupName = UUID().uuidString + ".backup"
        let backup = target.deletingLastPathComponent().appendingPathComponent(backupName)
        defer { try? fm.removeItem(at: staged); try? fm.removeItem(at: stagedReceipt) }
        try metadata.write(to: staged, options: .withoutOverwriting)
        let output = try FileHandle(forWritingTo: staged)
        do {
            try output.seekToEnd()
            var checksum = SHA256(); checksum.update(data: metadata)
            var size = Int64(metadata.count)
            while let block = try input.read(upToCount: 4_194_304), !block.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: block); checksum.update(data: block); size += Int64(block.count)
            }
            try output.synchronize(); try output.close()
            let updated = Receipt(engine: model.engine, sourceSHA256: model.sha256,
                fileSHA256: checksum.finalize().map { String(format: "%02x", $0) }.joined(), bytes: size)
            try JSONEncoder().encode(updated).write(to: stagedReceipt, options: .atomic)
        } catch { try? output.close(); throw error }
        _ = try fm.replaceItemAt(target, withItemAt: staged, backupItemName: backupName, options: .withoutDeletingBackupItem)
        do { _ = try fm.replaceItemAt(receiptURL(target), withItemAt: stagedReceipt) }
        catch {
            _ = try fm.replaceItemAt(target, withItemAt: backup)
            throw error
        }
        try? fm.removeItem(at: backup)
        return true
    }
    static func remove(_ model: LocalModel, at target: URL? = nil) throws {
        let target = target ?? model.fileURL
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        if FileManager.default.fileExists(atPath: receiptURL(target).path) { try FileManager.default.removeItem(at: receiptURL(target)) }
    }
}
