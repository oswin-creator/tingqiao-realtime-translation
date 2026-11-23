import Foundation
import Combine

enum SpokenEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    case kokoro, melo, meloKO, qwen, qwen17
    static let allCases: [Self] = [.melo, .qwen, .qwen17]
    static let assets: [Self] = [.melo, .meloKO, .qwen, .qwen17]
    var id: Self { self }
    var isQwen: Bool { self == .qwen || self == .qwen17 }
    var isMelo: Bool { self == .melo || self == .meloKO }
    var components: [Self] { self == .melo ? [.melo, .meloKO] : [self] }
    var componentTitle: String { self == .melo ? "中文与英语" : self == .meloKO ? "韩语" : title }
    func model(for language: MeetingLanguage) -> Self { self == .melo && language.speechCode == "ko" ? .meloKO : self }

    var title: String {
        switch self {
        case .kokoro: return "Kokoro 82M"
        case .melo: return "MeloTTS · 中英韩"
        case .meloKO: return "MeloTTS · 韩语（测试版）"
        case .qwen: return "Qwen3-TTS 0.6B"
        case .qwen17: return "Qwen3-TTS 1.7B"
        }
    }

    var detail: String {
        switch self {
        case .kokoro: return "轻量推荐 · 普通话和英语，多种预设音色"
        case .melo: return "中文、英语、韩语 · 随译文语言选择声音，中英可混读"
        case .meloKO: return "韩语语音包 · 部分词语的发音仍需改进"
        case .qwen: return "4 位量化 · 普通话、英语、韩语等十种语言"
        case .qwen17: return "4 位量化 · 十种语言 · 平静自然的口译语气"
        }
    }

    var supportedSystem: Bool {
        if isQwen {
            if #available(macOS 15.0, *) { return true }
        } else if #available(macOS 15.5, *) { return true }
        return false
    }
    var minimumSystem: String { isQwen ? "macOS 15" : "macOS 15.5" }

    func supports(_ language: MeetingLanguage) -> Bool {
        if self == .meloKO { return language.speechCode == "ko" }
        if self == .melo { return ["zh", "en", "ko"].contains(language.speechCode) }
        let codes = isQwen ? ["zh", "en", "ko", "ja", "de", "fr", "ru", "pt", "es", "it"] : ["zh", "en"]
        return codes.contains(language.speechCode)
    }

    struct Voice: Identifiable, Sendable {
        let id: String
        let title: String
        let language: String
    }

    var voices: [Voice] {
        switch self {
        case .kokoro:
            return [Voice(id: "3", title: "普通话女声", language: "zh"), Voice(id: "58", title: "普通话男声", language: "zh"),
                    Voice(id: "0", title: "美式英语女声", language: "en"), Voice(id: "2", title: "英式英语女声", language: "en")]
        case .melo:
            return [Voice(id: "0", title: "中英混读", language: "zh")]
        case .meloKO:
            return [Voice(id: "0", title: "韩语", language: "ko")]
        case .qwen, .qwen17:
            return [Voice(id: "serena", title: "Serena · 普通话女声", language: "zh"),
                    Voice(id: "vivian", title: "Vivian · 普通话女声", language: "zh"),
                    Voice(id: "uncle_fu", title: "Uncle Fu · 普通话男声", language: "zh"),
                    Voice(id: "ryan", title: "Ryan · 英语男声", language: "en"),
                    Voice(id: "aiden", title: "Aiden · 英语男声", language: "en"),
                    Voice(id: "sohee", title: "Sohee · 韩语女声", language: "ko"),
                    Voice(id: "ono_anna", title: "Ono Anna · 日语女声", language: "ja")]
        }
    }

    func voices(for language: MeetingLanguage) -> [Voice] {
        if self == .melo && language.speechCode == "ko" { return SpokenEngine.meloKO.voices }
        if isQwen && language.speechCode == "zh" {
            return voices.filter { $0.language == "zh" }
        }
        return voices
    }

    var source: URL {
        switch self {
        case .kokoro: return URL(string: "https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh")!
        case .melo: return URL(string: "https://github.com/myshell-ai/MeloTTS")!
        case .meloKO: return URL(string: "https://huggingface.co/MiaoMint/MeloTTS-ONNX")!
        case .qwen: return URL(string: "https://huggingface.co/sakasegawa/Qwen3-TTS-12Hz-0.6B-CustomVoice-GGUF")!
        case .qwen17: return URL(string: "https://huggingface.co/sakasegawa/Qwen3-TTS-12Hz-1.7B-CustomVoice-GGUF")!
        }
    }

    var download: (url: URL, bytes: Int64, sha: String) {
        switch self {
        case .kokoro:
            return (URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-multi-lang-v1_1.tar.bz2")!,
                    147_052_523, "259c9c8bc906d6078e4e0570421885dabb68b539c2f970fcbb890a58eeaf3e9c")
        case .melo:
            return (URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-melo-tts-zh_en.tar.bz2")!,
                    167_006_755, "e58351ed7149f290a54534538badd4077cdbe6fddc964b24d0bee870415d1514")
        case .meloKO:
            return (URL(string: "https://huggingface.co/MiaoMint/MeloTTS-ONNX/resolve/7a50512ba14a067701943e18b6636a6a18e7c69a/onnx_exports/ko/model.onnx")!,
                    170_609_357, "137350733443bd77e05934c043c2753856dbb0c9649f1a6681f91a225e8d849b")
        case .qwen:
            return (URL(string: "https://huggingface.co/sakasegawa/Qwen3-TTS-12Hz-0.6B-CustomVoice-GGUF/resolve/fd9df9364613a92a86b4137074bc281204823033/Qwen3-TTS-12Hz-0.6B-CustomVoice-Q4_K.gguf")!,
                    760_680_704, "67cbe04239d079d3e3649a054258b8cf1553a99a03cc5b38d57350c6905e4cbd")
        case .qwen17:
            return (URL(string: "https://huggingface.co/sakasegawa/Qwen3-TTS-12Hz-1.7B-CustomVoice-GGUF/resolve/a72e6c6575d67652488cdffc1c863215a9899978/Qwen3-TTS-12Hz-1.7B-CustomVoice-Q4_K.gguf")!,
                    1_329_512_960, "d643b25ffa11e7c9687aae50d21b5a47076c4f5642c5e6b957f101a98024cc74")
        }
    }
    var downloadSize: String { ByteCountFormatter.string(fromByteCount: download.bytes, countStyle: .file) }
    var modelName: String { isQwen ? "model.gguf" : self == .kokoro ? "model.int8.onnx" : "model.onnx" }
    var requiredFiles: [String] {
        switch self {
        case .kokoro: return [modelName, "voices.bin", "tokens.txt", "lexicon-zh.txt", "lexicon-us-en.txt", "phone-zh.fst", "date-zh.fst", "number-zh.fst", "espeak-ng-data/en_dict"]
        case .melo: return [modelName, "tokens.txt", "lexicon.txt", "phone.fst", "date.fst", "number.fst"]
        case .meloKO: return [modelName, "frontend.json"]
        case .qwen, .qwen17: return [modelName]
        }
    }
}

struct SpokenSettings: Codable, Equatable {
    var engine: SpokenEngine = .melo
    var voices: [SpokenEngine: String] = [:]
    var rate = 1.1
    var volume = 1.0
    var automaticRate = true
    var outputUID = ""
    private static let key = "TingQiao.spokenSettings"

    init() {}

    private enum CodingKeys: String, CodingKey { case engine, voices, rate, volume, automaticRate, outputUID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = try values.decodeIfPresent(SpokenEngine.self, forKey: .engine) ?? .melo
        if engine == .kokoro || engine == .meloKO { engine = .melo }
        voices = try values.decodeIfPresent([SpokenEngine: String].self, forKey: .voices) ?? [:]
        rate = try values.decodeIfPresent(Double.self, forKey: .rate) ?? 1.1
        let gain = try values.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        volume = gain.isFinite ? min(1, max(0, gain)) : 1
        automaticRate = try values.decodeIfPresent(Bool.self, forKey: .automaticRate) ?? true
        outputUID = try values.decodeIfPresent(String.self, forKey: .outputUID) ?? ""
    }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if value.engine == .kokoro { value.engine = .melo }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func voice(for language: MeetingLanguage) -> String {
        let voices = engine.voices(for: language)
        return voices.first { $0.id == self.voices[engine] }?.id
            ?? voices.first { $0.language == language.speechCode }?.id
            ?? voices[0].id
    }
}

enum SpokenModelFiles {
    static let root = LocalModel.directory.deletingLastPathComponent().appendingPathComponent("SpeechModels", isDirectory: true)
    static func directory(_ engine: SpokenEngine, root: URL = SpokenModelFiles.root) -> URL { root.appendingPathComponent(engine.rawValue, isDirectory: true) }

    static func installed(_ engine: SpokenEngine, root: URL = SpokenModelFiles.root) -> Bool {
        let folder = directory(engine, root: root)
        let marker = folder.appendingPathComponent(".verified")
        guard (try? String(contentsOf: marker, encoding: .utf8)) == engine.download.sha else { return false }
        return complete(engine, in: folder)
    }

    private static func complete(_ engine: SpokenEngine, in folder: URL) -> Bool {
        engine.requiredFiles.allSatisfy { name in
            let url = folder.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let bytes = values.fileSize, bytes > 0 else { return false }
            return (!engine.isQwen && engine != .meloKO) || name != engine.modelName || Int64(bytes) == engine.download.bytes
        }
    }

    static func install(_ source: URL, engine: SpokenEngine, root: URL = SpokenModelFiles.root,
                        koreanFrontend: URL? = Bundle.main.url(forResource: "melo-korean", withExtension: "json")) throws {
        let descriptor = engine.download
        try LocalModelFiles.verify(source, bytes: descriptor.bytes, sha256: descriptor.sha)
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stage = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: stage) }

        if engine == .meloKO {
            guard let koreanFrontend else { throw BridgeError("安装包缺少韩语发音组件。") }
            try files.copyItem(at: koreanFrontend, to: stage.appendingPathComponent("frontend.json"))
            try files.moveItem(at: source, to: stage.appendingPathComponent(engine.modelName))
        } else if engine.isQwen {
            try files.moveItem(at: source, to: stage.appendingPathComponent(engine.modelName))
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xjf", source.path, "-C", stage.path, "--strip-components", "1"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw BridgeError("无法解压播报模型，请检查磁盘空间。") }
        }

        try Task.checkCancellation()
        guard complete(engine, in: stage) else { throw BridgeError("播报模型文件不完整。") }
        try descriptor.sha.write(to: stage.appendingPathComponent(".verified"), atomically: true, encoding: .utf8)
        let target = directory(engine, root: root)
        if files.fileExists(atPath: target.path) { _ = try files.replaceItemAt(target, withItemAt: stage) }
        else { try files.moveItem(at: stage, to: target) }
    }
}

@MainActor
final class SpokenModelDownloads: ObservableObject {
    @Published private(set) var installed = Set(SpokenEngine.assets.filter { SpokenModelFiles.installed($0) })
    @Published private(set) var downloading: SpokenEngine?
    @Published private(set) var progress: Double?
    @Published private(set) var message = ""
    private var task: Task<Void, Never>?

    func install(_ engine: SpokenEngine) {
        guard downloading == nil, engine.supportedSystem, !installed.contains(engine) else { return }
        let asset = engine.download
        downloading = engine
        progress = 0
        message = ""
        task = Task { [self] in
            defer { downloading = nil; progress = nil; task = nil }
            let downloader = ModelDownloader(expectedBytes: asset.bytes) { [weak self] status in
                Task { @MainActor in
                    guard let self, self.downloading == engine, self.progress != nil else { return }
                    self.progress = status.fraction
                }
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 3600
            let session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (temporary, response) = try await downloader.download(from: asset.url, session: session)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BridgeError("下载服务暂时不可用。") }
                progress = nil
                let work = Task.detached(priority: .utility) { try SpokenModelFiles.install(temporary, engine: engine) }
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                installed.insert(engine)
                message = "已安装 \(engine.title)。"
            } catch is CancellationError {
                message = "已取消下载。"
            } catch {
                message = Task.isCancelled ? "已取消下载。" : "安装失败：\(error.localizedDescription)"
            }
        }
    }

    func cancel() { task?.cancel() }

    func remove(_ engine: SpokenEngine) {
        guard downloading != engine, installed.contains(engine) else { return }
        do {
            try FileManager.default.removeItem(at: SpokenModelFiles.directory(engine))
            installed.remove(engine)
            message = "已移除 \(engine.title)。"
        } catch {
            message = "移除失败：\(error.localizedDescription)"
        }
    }
}
