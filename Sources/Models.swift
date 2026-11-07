import Foundation
import Security
import LocalAuthentication

enum MeetingMode: String, Codable, CaseIterable {
    case online = "线上会议", inPerson = "线下会议"
    var icon: String { self == .online ? "desktopcomputer" : "mic" }
}

enum TranslationProvider: String, Codable, CaseIterable {
    case googleFree = "谷歌 · 免费试用", googleCloud = "谷歌 · 官方接口", custom = "自定义大模型", indexTranslate = "Index · 免费"
}

enum RecognitionEngine: String, Codable, CaseIterable {
    case apple = "Apple 系统识别", whisperTurbo = "Whisper large-v3-turbo"
    case whisperKomix = "Whisper Medium KomixV2"
    case qwenASR = "Qwen3-ASR-1.7B"
    case whisperLarge = "Whisper Large V3"

    var isLocalModel: Bool { self != .apple }
    var isWhisper: Bool { self != .apple && self != .qwenASR }
    var shortTitle: String {
        switch self {
        case .apple: return "Apple"
        case .whisperTurbo: return "Whisper Turbo"
        case .whisperKomix: return "Whisper KomixV2"
        case .qwenASR: return "Qwen3 ASR"
        case .whisperLarge: return "Whisper Large V3"
        }
    }
    func supports(_ language: String) -> Bool { self != .whisperKomix || language.hasPrefix("ko") }
}

enum MeetingLanguage: String, Codable, CaseIterable {
    case english = "en-US", korean = "ko-KR", japanese = "ja-JP"
    case simplifiedChinese = "zh-CN", traditionalChinese = "zh-TW"
    case spanish = "es-ES", french = "fr-FR", german = "de-DE"
    case portuguese = "pt-BR", italian = "it-IT", russian = "ru-RU"
    case arabic = "ar-SA", hindi = "hi-IN", indonesian = "id-ID"
    case vietnamese = "vi-VN", thai = "th-TH"

    var title: String {
        switch self {
        case .english: return "英语"
        case .korean: return "韩语"
        case .japanese: return "日语"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁体中文"
        case .spanish: return "西班牙语"
        case .french: return "法语"
        case .german: return "德语"
        case .portuguese: return "葡萄牙语"
        case .italian: return "意大利语"
        case .russian: return "俄语"
        case .arabic: return "阿拉伯语"
        case .hindi: return "印地语"
        case .indonesian: return "印尼语"
        case .vietnamese: return "越南语"
        case .thai: return "泰语"
        }
    }

    var speechCode: String { String(rawValue.prefix(2)) }
    var translationCode: String { speechCode == "zh" ? rawValue : speechCode }
    static func sourceName(_ locale: String) -> String { Self(rawValue: locale)?.title ?? locale }
}

struct AppSettings: Codable {
    var mode: MeetingMode = .online
    var language = "en-US"
    var targetLanguage: MeetingLanguage = .simplifiedChinese
    var microphoneID = ""
    var applicationID = ""
    var provider: TranslationProvider = .googleFree
    var baseURL = "https://api.deepseek.com"
    var model = ""
    var recognitionEngine: RecognitionEngine = .apple
    var localRecognition = true
    var showOriginal = true
    var fontSize = 24.0
    var useTranslationContext = true
    var translationContextCount = 4
    var useTerminology = true
    var useTerminologyMemory = true
    var terminologyDomains: [String] = []
    var floatingOpacity = 1.0
    var floatingAlwaysOnTop = true
    var floatingFontSize = 24.0
    var effectiveTranslationContextCount: Int {
        useTranslationContext ? min(6, max(1, translationContextCount)) : 0
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "settings"), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") } }

    enum CodingKeys: String, CodingKey {
        case mode, language, targetLanguage, microphoneID, applicationID, provider, baseURL, model
        case recognitionEngine, localRecognition, showOriginal, fontSize, useTranslationContext, translationContextCount
        case floatingOpacity, floatingAlwaysOnTop, floatingFontSize
        case useTerminology, useTerminologyMemory, terminologyDomains
    }
}

extension AppSettings {
    // Adding preferences must preserve the user's existing provider and audio setup.
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(MeetingMode.self, forKey: .mode) ?? mode
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? language
        targetLanguage = try values.decodeIfPresent(MeetingLanguage.self, forKey: .targetLanguage) ?? targetLanguage
        microphoneID = try values.decodeIfPresent(String.self, forKey: .microphoneID) ?? microphoneID
        applicationID = try values.decodeIfPresent(String.self, forKey: .applicationID) ?? applicationID
        provider = try values.decodeIfPresent(TranslationProvider.self, forKey: .provider) ?? provider
        baseURL = try values.decodeIfPresent(String.self, forKey: .baseURL) ?? baseURL
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? model
        recognitionEngine = try values.decodeIfPresent(RecognitionEngine.self, forKey: .recognitionEngine) ?? .apple
        localRecognition = try values.decodeIfPresent(Bool.self, forKey: .localRecognition) ?? localRecognition
        showOriginal = try values.decodeIfPresent(Bool.self, forKey: .showOriginal) ?? showOriginal
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        useTranslationContext = try values.decodeIfPresent(Bool.self, forKey: .useTranslationContext) ?? useTranslationContext
        translationContextCount = try values.decodeIfPresent(Int.self, forKey: .translationContextCount) ?? translationContextCount
        useTerminology = try values.decodeIfPresent(Bool.self, forKey: .useTerminology) ?? useTerminology
        useTerminologyMemory = try values.decodeIfPresent(Bool.self, forKey: .useTerminologyMemory) ?? useTerminologyMemory
        terminologyDomains = Array(Set(try values.decodeIfPresent([String].self, forKey: .terminologyDomains) ?? [])).sorted()
        floatingOpacity = min(1, max(0, try values.decodeIfPresent(Double.self, forKey: .floatingOpacity) ?? floatingOpacity))
        floatingAlwaysOnTop = try values.decodeIfPresent(Bool.self, forKey: .floatingAlwaysOnTop) ?? floatingAlwaysOnTop
        floatingFontSize = min(48, max(12, try values.decodeIfPresent(Double.self, forKey: .floatingFontSize) ?? fontSize))
    }
}

struct TranslationContextTurn: Codable, Equatable {
    var original: String
    var translation: String?
}

enum RepeatedText {
    static let limit = 10
    static let translationLimit = 15
    static func containsRun(_ text: String, minimum: Int = limit) -> Bool {
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
        let characters = Array(normalized.filter { !$0.isWhitespace && !$0.isPunctuation })
        let words = Array(normalized.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'", with: "")
            .split { $0.isWhitespace || $0.isPunctuation })
        return (1...10).contains { containsRun(in: characters, unitLength: $0, minimum: minimum) }
            || (1...10).contains { containsRun(in: words, unitLength: $0, minimum: minimum) }
    }
    static func containsTranslationRun(_ text: String) -> Bool { containsRun(text, minimum: translationLimit) }
    private static func containsRun<Element: Equatable>(in elements: [Element], unitLength: Int, minimum: Int) -> Bool {
        guard elements.count >= minimum * unitLength else { return false }
        let requiredMatches = (minimum - 1) * unitLength
        var matches = 0
        for index in unitLength..<elements.count {
            matches = elements[index] == elements[index - unitLength] ? matches + 1 : 0
            if matches >= requiredMatches { return true }
        }
        return false
    }
}

struct RecognitionSpan: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

struct RecognitionResult: Equatable {
    var text: String
    var spans: [RecognitionSpan] = []
}

enum TranslationHistory {
    static func context(before job: AudioJob, in jobs: [AudioJob], limit: Int) -> [TranslationContextTurn] {
        let limit = min(6, max(0, limit))
        guard limit > 0, let index = jobs.firstIndex(where: { $0.id == job.id }) else { return [] }
        var history: [TranslationContextTurn] = []
        // Use capture order, not completion order: retries may complete after newer audio.
        for earlier in jobs[..<index].reversed() {
            guard earlier.deletedAt == nil, earlier.sessionID == job.sessionID, earlier.stage != .recognize,
                  !earlier.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !RepeatedText.containsRun(earlier.original), !RepeatedText.containsTranslationRun(earlier.translated) else { continue }
            let translation = earlier.resolvedTargetLanguage == job.resolvedTargetLanguage && !earlier.translated.isEmpty ? earlier.translated : nil
            history.append(TranslationContextTurn(original: earlier.original, translation: translation))
            if history.count == limit { break }
        }
        return history.reversed()
    }
}

enum JobStage: String, Codable { case recognize, translate, done, blocked }

enum AssistantAction: String, Codable, CaseIterable {
    case answer, explain
    var title: String { self == .answer ? "帮我回答" : "解释刚才" }
    var icon: String { self == .answer ? "bubble.left.and.bubble.right" : "sparkle.magnifyingglass" }
}

struct AssistantRequest: Equatable {
    var action: AssistantAction
    var id: String

    init?(action: String, id: String) {
        guard let action = AssistantAction(rawValue: action), Self.validID(id) else { return nil }
        self.action = action
        self.id = id
    }

    static func validID(_ id: String) -> Bool {
        id.utf8.count == 12 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct AssistantReply: Codable, Equatable {
    var id: String
    var action: AssistantAction
    var state: State
    var text: String
    var reasoning: String? = nil

    enum State: String, Codable { case waiting, ready, error }
}

struct Caption: Codable, Identifiable, Equatable {
    var isDraft: Bool? = nil
    var id: UUID
    var date: Date
    var original: String
    var translated: String
    var recognitionStatus: String? = nil

    var displayText: String {
        if let recognitionStatus { return recognitionStatus }
        if isDraft == true { return "正在听 · 确认整句后翻译" }
        return translated.isEmpty ? "正在翻译…" : translated
    }
}
struct AudioJob: Codable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var created: Date
    var audioFile: String
    var language: String
    var localRecognition: Bool
    var targetLanguage: MeetingLanguage? = nil
    var recognitionEngine: RecognitionEngine? = nil
    var terminologyDomains: [String]? = nil
    var previewText: String? = nil
    var repetitionRetries: Int? = nil
    var translationRepetitionRetries: Int? = nil
    var overlap: Bool = false
    var contextSampleCount: Int? = nil
    var audioStartSample: Int64? = nil
    var newAudioSampleCount: Int? = nil
    var audioTimelineID: UUID? = nil
    var recognitionSuspected: Bool? = nil
    var effectiveContextSampleCount: Int { contextSampleCount ?? (overlap ? 8000 : 0) }
    var audioEndSample: Int64? {
        guard let start = audioStartSample, let count = newAudioSampleCount else { return nil }
        return start + Int64(effectiveContextSampleCount + count)
    }
    var stage: JobStage = .recognize
    var original = ""
    var translated = ""
    var attempts = 0
    var retryAfter = Date.distantPast
    var error = ""
    var deletedAt: Date?
    var resolvedTargetLanguage: MeetingLanguage { targetLanguage ?? .simplifiedChinese }

    var recognitionFailures: Int { max(attempts, repetitionRetries ?? 0) }
}

enum TranscriptExport {
    static func render(_ jobs: [AudioJob]) -> String {
        jobs.enumerated().filter { $0.element.deletedAt == nil && !$0.element.original.isEmpty }
            .sorted { lhs, rhs in lhs.element.created == rhs.element.created ? lhs.offset < rhs.offset : lhs.element.created < rhs.element.created }
            .map { _, job in
                "[\(job.created.formatted(date: .numeric, time: .standard))]\n原文：\(job.original)\n译文：\(job.translated.isEmpty ? "（待翻译）" : job.translated)"
            }.joined(separator: "\n\n")
    }
}

struct BridgeError: LocalizedError {
    var message: String
    var retryable = true
    var errorDescription: String? { message }
    init(_ message: String, retryable: Bool = true) { self.message = message; self.retryable = retryable }
}

enum SecretStore {
    // Check item metadata only. This never loads the saved key into a text field
    // and never opens an authentication prompt just to show a saved indicator.
    static func contains(_ account: String) throws -> Bool {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "cn.tingqiao.bridge",
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authentication
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw BridgeError("暂未确认钥匙串里的密钥，请重新检查或在系统提示中允许访问。", retryable: false)
        }
        return true
    }

    static func read(_ account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cn.tingqiao.bridge", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else {
            throw BridgeError("尚未读取到已保存的 API 密钥，请处理 macOS 钥匙串提示，或在翻译设置中重新读取（\(status)）。", retryable: false)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cn.tingqiao.bridge", kSecAttrAccount as String: account]
        let status: OSStatus
        if value.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let update = [kSecValueData as String: Data(value.utf8)]
            let existing = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if existing == errSecItemNotFound {
                status = SecItemAdd(query.merging(update) { _, new in new } as CFDictionary, nil)
            } else { status = existing }
        }
        guard status == errSecSuccess || (value.isEmpty && status == errSecItemNotFound) else { throw BridgeError("钥匙串保存失败（\(status)），请重新保存。", retryable: false) }
    }
}

final class SessionStore {
    let root: URL
    let audio: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    init(root: URL? = nil) throws {
        let override = ProcessInfo.processInfo.environment["TINGQIAO_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        self.root = root ?? override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TingQiao")
        audio = self.root.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func load() throws -> [AudioJob] {
        let url = root.appendingPathComponent("jobs.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([AudioJob].self, from: Data(contentsOf: url))
    }
    func save(_ jobs: [AudioJob]) throws {
        try encoder.encode(jobs).write(to: root.appendingPathComponent("jobs.json"), options: .atomic)
    }
    func removeAudio(_ job: AudioJob) { try? FileManager.default.removeItem(at: audio.appendingPathComponent(job.audioFile)) }
    func permanentlyRemoveAudio(_ job: AudioJob) throws {
        let url = audio.appendingPathComponent(job.audioFile)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func recoverOrphanAudio(known: [AudioJob]) throws -> [URL] {
        let filenames = Set(known.map(\.audioFile))
        return try FileManager.default.contentsOfDirectory(at: audio, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" && !filenames.contains($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

enum CaptionText {
    static func comparisonText(_ text: String) -> String {
        String(text.precomposedStringWithCanonicalMapping.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
    }
    static func removingOverlap(previous: String, current: String) -> String {
        let left = Array(comparisonText(previous))
        let characters = Array(current.precomposedStringWithCanonicalMapping)
        var right: [Character] = [], offsets: [Int] = []
        for (index, character) in characters.enumerated() {
            for c in String(character).lowercased() where !c.isWhitespace && !c.isPunctuation {
                right.append(c); offsets.append(index + 1)
            }
        }
        let limit = min(80, left.count, right.count)
        guard limit >= 8 else { return current }
        for count in stride(from: limit, through: 8, by: -1) {
            if count < right.count && left.suffix(count).elementsEqual(right.prefix(count)) {
                let rest = String(characters.dropFirst(offsets[count - 1]))
                return String(rest.drop(while: { $0.isWhitespace || $0.isPunctuation })).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return current
    }
}

enum RecognitionBoundary {
    static func resolve(_ result: RecognitionResult, sharedSamples: Int, maximumDuration: Double) -> String? {
        guard sharedSamples > 0, !result.text.isEmpty else { return result.text }
        let boundary = Double(sharedSamples) / 16000
        let spans = result.spans
        let sameText = CaptionText.comparisonText(spans.map(\.text).joined()) == CaptionText.comparisonText(result.text)
        var lastStart = -1.0
        let valid = spans.count > 1 && sameText && spans.allSatisfy { span in
            defer { lastStart = span.start }
            return span.start.isFinite && span.end.isFinite && span.start >= 0 && span.end > span.start
                && span.start >= lastStart && span.end <= maximumDuration + 0.2
        }
        guard valid else { return nil }
        let text = spans.filter { $0.end > boundary }.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    static func resolve(_ result: RecognitionResult, previous: String, sharedSamples: Int, maximumDuration: Double) -> String? {
        if let timed = resolve(result, sharedSamples: sharedSamples, maximumDuration: maximumDuration) { return timed }
        let aligned = CaptionText.removingOverlap(previous: previous, current: result.text)
        return aligned != result.text ? aligned : nil
    }
}
