import Foundation
import CryptoKit

enum MeetingDomain: String, CaseIterable {
    case statistics, mathematics, computerScience = "computer-science", medicine, business, law, industry
    var title: String {
        switch self {
        case .statistics: return "统计与研究方法"
        case .mathematics: return "数学"
        case .computerScience: return "计算机与 AI"
        case .medicine: return "医学"
        case .business: return "经济与商务"
        case .law: return "法律"
        case .industry: return "工程与工业"
        }
    }
    static func summary(_ ids: [String]) -> String {
        let names = ids.map { Self(rawValue: $0)?.title ?? $0 }
        return names.isEmpty ? "未选专业领域 · 普通翻译" : names.joined(separator: "、")
    }
}

struct TermForm: Codable {
    var preferred: String
    var aliases: [String]? = nil
    var recognitionVariants: [String]? = nil
}

struct ProfessionalTerm: Codable {
    enum Kind: String, Codable { case fixed, contextual }
    var id: String
    var domain: String
    var kind: Kind
    // Language keys use the app's translation codes, including zh-CN/zh-TW.
    var forms: [String: TermForm]
    var notes: [String: String]? = nil
    var excludeCues: [String: [String]]? = nil
}

struct TermDomain: Codable {
    var id: String
    var cues: [String: [String]]
}

struct TermLibrary: Codable {
    var version: Int
    var domains: [TermDomain]
    var entries: [ProfessionalTerm]

    static let maximumEntries = 50_000
    static let maximumBytes = 32 * 1024 * 1024
    static func read(_ url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw invalid() }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw invalid() }
        let library = try JSONDecoder().decode(Self.self, from: data)
        try library.validate()
        return library
    }
    func validate() throws {
        let languages = Set(MeetingLanguage.allCases.map(\.translationCode))
        func valid(_ value: String, max: Int = 120) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= max &&
                !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard version == 1, entries.count <= Self.maximumEntries, domains.count <= 64,
              Set(entries.map(\.id)).count == entries.count, Set(domains.map(\.id)).count == domains.count else { throw Self.invalid() }
        let domainIDs = Set(domains.map(\.id))
        for domain in domains {
            guard valid(domain.id, max: 48), domain.cues.count <= languages.count else { throw Self.invalid() }
            for (language, cues) in domain.cues {
                guard languages.contains(language), cues.count <= 32, cues.allSatisfy({ valid($0) }) else { throw Self.invalid() }
            }
        }
        for entry in entries {
            guard valid(entry.id, max: 64), domainIDs.contains(entry.domain), (2...languages.count).contains(entry.forms.count) else { throw Self.invalid() }
            for (language, form) in entry.forms {
                let aliases = (form.aliases ?? []) + (form.recognitionVariants ?? [])
                guard languages.contains(language), valid(form.preferred), aliases.count <= 24,
                      aliases.allSatisfy({ valid($0) }),
                      TermText.normalized(form.preferred).count >= 2 else { throw Self.invalid() }
            }
            for (language, note) in entry.notes ?? [:] {
                guard languages.contains(language), valid(note, max: 160) else { throw Self.invalid() }
            }
            for (language, cues) in entry.excludeCues ?? [:] {
                guard languages.contains(language), cues.count <= 24, cues.allSatisfy({ valid($0) }) else { throw Self.invalid() }
            }
        }
    }
    static func invalid() -> BridgeError { BridgeError("术语库格式无效：需要版本 1、有效语言、唯一词条及对应领域；最多 5 万条、32 MB。原词库未被覆盖。", retryable: false) }
}

enum TermText {
    static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) ? Character(String($0)) : " " })
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func isEastAsian(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x3040...0x30ff).contains($0.value) || (0x3400...0x9fff).contains($0.value) || (0xac00...0xd7af).contains($0.value) }
    }
    static func keys(_ normalized: String) -> Set<String> {
        var keys = Set<String>()
        for token in normalized.split(separator: " ") {
            let chars = Array(token)
            if chars.contains(where: isEastAsian) {
                if chars.count >= 2 { for n in 0..<(chars.count - 1) { keys.insert(String(chars[n...n+1])) } }
                for part in token.split(whereSeparator: { !$0.isASCII || !($0.isLetter || $0.isNumber) }) {
                    keys.insert(String(part))
                    if let singular = singular(String(part)) { keys.insert(singular) }
                }
            } else {
                keys.insert(String(token))
                if let singular = singular(String(token)) { keys.insert(singular) }
            }
        }
        return keys
    }
    static func singular(_ token: String) -> String? {
        guard token.count >= 5, token.hasSuffix("s"), !["ss", "is", "us"].contains(where: token.hasSuffix) else { return nil }
        return String(token.dropLast())
    }
    static func acronym(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return !letters.isEmpty && letters.count <= 5 && letters.allSatisfy(\.isASCII) &&
            (letters.allSatisfy(\.isUppercase) || letters.filter(\.isUppercase).count >= 2)
    }
    static let koreanSuffixes: Set<String> = ["은", "는", "이", "가", "을", "를", "의", "에", "에서", "에서는", "에는", "으로", "으로는", "로", "와", "과", "도", "만", "까지", "부터", "보다", "라고", "이라고", "이라는", "란", "입니다", "이다", "이었다", "였다", "에선"]

    static func ranges(of phrase: String, in text: String, language: String) -> [Range<String.Index>] {
        guard !phrase.isEmpty else { return [] }
        var cursor = text.startIndex, output: [Range<String.Index>] = []
        while cursor < text.endIndex, let range = text.range(of: phrase, range: cursor..<text.endIndex) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            var left = before == nil || !(before!.isLetter || before!.isNumber)
            var right = after == nil || !(after!.isLetter || after!.isNumber)
            if language == "ja" || language.hasPrefix("zh") {
                if phrase.first.map(isEastAsian) == true { left = true }
                if phrase.last.map(isEastAsian) == true { right = true }
            } else if language == "ko", !right {
                let suffix = text[range.upperBound...].prefix { $0.isLetter }
                right = koreanSuffixes.contains(String(suffix))
            } else if language == "en", !right {
                let suffix = text[range.upperBound...].prefix { $0.isLetter }
                let lastWord = String(phrase.split(separator: " ").last ?? "")
                right = suffix == "s" && singular(lastWord + "s") == lastWord
            }
            if left && right { output.append(range); if output.count >= 8 { break } }
            cursor = range.upperBound
        }
        return output
    }
    static func oneEdit(_ a: String, _ b: String) -> Bool {
        guard a != b, a.count >= 7, b.count >= 7, abs(a.count - b.count) <= 1,
              a.allSatisfy(\.isASCII), b.allSatisfy(\.isASCII) else { return false }
        let x = Array(a), y = Array(b)
        var i = 0, j = 0, edits = 0
        while i < x.count && j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1; if edits > 1 { return false }
            if x.count >= y.count { i += 1 }
            if y.count >= x.count { j += 1 }
        }
        return edits + (i < x.count || j < y.count ? 1 : 0) <= 1
    }
}

struct TermMemoryTurn {
    var text: String
    var date: Date
}

struct TerminologyHint {
    // [source, target, fixed|context|possible, optional sense note]
    var terms: [[String]]
    var termIDs: [String]
    var activeCount: Int
    static let instructions = "术语项为[原词,译名,类型,可选含义]：fixed规范译名；context按语境选用；possible仅是识别候选。与原文或当前话题冲突则忽略，不改写事实。"
    static let maximumEstimatedTokens = 300
    static let maximumBytes = 900
    var estimatedTokens: Int { Self.estimate(Self.instructions + "\"terminology\":" + encoded) }
    var encoded: String { String(decoding: (try? JSONEncoder().encode(terms)) ?? Data(), as: UTF8.self) }
    static func estimate(_ text: String) -> Int {
        // Deliberately conservative heuristic, not a provider-specific tokenizer.
        var cost = 0.0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { cost += CharacterSet.alphanumerics.contains(scalar) ? 0.34 : 1 }
            else { cost += 2 }
        }
        return Int(cost.rounded(.up))
    }
    static func bounded(_ candidates: [([String], String)], activeCount: Int) -> Self? {
        var hint = Self(terms: [], termIDs: [], activeCount: activeCount)
        for (row, id) in candidates where hint.terms.count < 8 {
            var next = hint; next.terms.append(row); next.termIDs.append(id)
            guard next.estimatedTokens <= maximumEstimatedTokens,
                  (next.encoded + "\"terminology\":" + instructions).utf8.count <= maximumBytes else { continue }
            hint = next
        }
        return hint.terms.isEmpty ? nil : hint
    }
}

final class TerminologyIndex {
    let library: TermLibrary
    private struct Form {
        var entry: Int
        var language: String
        var original: String
        var normalized: String
        var tentative: Bool
    }
    private struct Match {
        var entry: Int
        var possible: Bool
        var short: Bool
        var length: Int
    }
    private var forms: [Form] = []
    private var postings: [String: [String: [Int]]] = [:]
    private var fuzzy: [String: [String: [Int]]] = [:]
    private var cues: [String: [(String, String)]] = [:]

    init(library: TermLibrary, sourceLanguages: Set<String>? = nil) throws {
        try library.validate(); self.library = library
        var frequency: [String: [String: Int]] = [:]
        for (entryID, entry) in library.entries.enumerated() {
            for language in entry.forms.keys.sorted() {
                guard sourceLanguages?.contains(language) ?? true else { continue }
                let value = entry.forms[language]!
                let values = ([value.preferred] + (value.aliases ?? [])).map { ($0, false) } + (value.recognitionVariants ?? []).map { ($0, true) }
                for (text, tentative) in values {
                    let normalized = TermText.normalized(text), keys = TermText.keys(normalized)
                    guard normalized.count >= 2, !keys.isEmpty else { continue }
                    forms.append(Form(entry: entryID, language: language, original: text, normalized: normalized, tentative: tentative))
                    for key in keys { frequency[language, default: [:]][key, default: 0] += 1 }
                }
            }
        }
        for (id, form) in forms.enumerated() {
            let anchor = TermText.keys(form.normalized).min { a, b in
                let ac = frequency[form.language]?[a] ?? 0, bc = frequency[form.language]?[b] ?? 0
                return ac == bc ? a < b : ac < bc
            }!
            postings[form.language, default: [:]][anchor, default: []].append(id)
            if !form.tentative {
                for word in form.normalized.split(separator: " ").map(String.init) where word.count >= 7 && word.allSatisfy(\.isASCII) {
                    fuzzy[form.language, default: [:]][String(word.prefix(2)), default: []].append(id)
                }
            }
        }
        for domain in library.domains {
            for (language, values) in domain.cues {
                for cue in values { cues[language, default: []].append((TermText.normalized(cue), domain.id)) }
            }
        }
    }

    private func matches(_ text: String, raw: String, language: String, crossing boundary: String.Index? = nil, allowFuzzy: Bool = false) -> [Match] {
        let keys = TermText.keys(text)
        var candidateIDs = Set<Int>()
        for key in keys.sorted() {
            for id in (postings[language]?[key] ?? []).prefix(512) { candidateIDs.insert(id) }
        }
        if allowFuzzy {
            for key in keys.sorted() where key.count >= 7 && key.allSatisfy(\.isASCII) {
                for id in (fuzzy[language]?[String(key.prefix(2))] ?? []).prefix(64) { candidateIDs.insert(id) }
            }
        }
        var found: [Int: Match] = [:]
        for id in candidateIDs.sorted().prefix(1024) {
            let form = forms[id]
            let ranges = TermText.ranges(of: form.normalized, in: text, language: language)
            var exact = ranges.contains { range in boundary == nil || (range.lowerBound < boundary! && range.upperBound > boundary!) }
            if exact && TermText.acronym(form.original) {
                exact = raw.range(of: form.original, options: .literal) != nil
            }
            var possible = form.tentative
            if !exact && allowFuzzy && boundary == nil && !form.tentative && library.entries[form.entry].kind == .fixed {
                let words = form.normalized.split(separator: " ").map(String.init)
                let spoken = text.split(separator: " ").map(String.init)
                if words.count <= spoken.count, words.count <= 8 {
                    for start in 0...(spoken.count - words.count) {
                        var edits = 0, valid = true
                        for n in words.indices where words[n] != spoken[start + n] {
                            if TermText.oneEdit(words[n], spoken[start + n]) { edits += 1 } else { valid = false; break }
                        }
                        if valid && edits == 1 { exact = true; possible = true; break }
                    }
                }
            }
            guard exact else { continue }
            let short = TermText.acronym(form.original) && form.original.filter(\.isLetter).count <= 3
            let match = Match(entry: form.entry, possible: possible, short: short, length: form.normalized.count)
            if let old = found[form.entry], (!old.possible && match.possible) || old.length > match.length { continue }
            found[form.entry] = match
        }
        return found.values.sorted { $0.entry < $1.entry }
    }
    private func domains(in text: String, language: String) -> Set<String> {
        Set((cues[language] ?? []).compactMap { phrase, domain in
            TermText.ranges(of: phrase, in: text, language: language).isEmpty ? nil : domain
        })
    }
    private func strongDomains(_ matches: [Match]) -> Set<String> {
        Set(matches.filter { !$0.possible && !$0.short && library.entries[$0.entry].kind == .fixed }.map { library.entries[$0.entry].domain })
    }

    func retrieve(text: String, source: String, target: String, recent: [TermMemoryTurn] = [], topic: String = "", now: Date, useMemory: Bool = true, selectedDomains: Set<String>? = nil) -> TerminologyHint? {
        guard source != target, !text.isEmpty, selectedDomains?.isEmpty != true else { return nil }
        let current = TermText.normalized(String(text.prefix(2000)))
        var direct = matches(current, raw: text, language: source, allowFuzzy: true)
        let resets: [String: [String]] = ["en": ["change the topic", "switch topics", "new topic"], "ko": ["다른 주제", "주제를 바꾸"], "ja": ["話題を変え", "別の話題"], "zh-CN": ["换个话题", "新话题"], "zh-TW": ["換個話題", "新話題"]]
        func resetsTopic(_ normalized: String) -> Bool {
            (resets[source] ?? []).contains { normalized.contains(TermText.normalized($0)) }
        }
        func excluded(_ id: Int, in normalized: String) -> Bool {
            (library.entries[id].excludeCues?[source] ?? []).contains {
                !TermText.ranges(of: TermText.normalized($0), in: normalized, language: source).isEmpty
            }
        }
        let reset = resetsTopic(current)
        var relevant = useMemory && !reset ? Array(recent.filter { (0...60).contains(now.timeIntervalSince($0.date)) }.sorted { $0.date < $1.date }.suffix(40)) : []
        // A reset is a capture-order boundary, not just a one-utterance hint.
        let resetPosition = relevant.lastIndex { resetsTopic(TermText.normalized($0.text)) }
        if let resetPosition { relevant = Array(relevant[resetPosition...]) }
        if let previous = relevant.last {
            let separator = source == "ja" || source.hasPrefix("zh") ? "" : " "
            let prefix = TermText.normalized(String(previous.text.suffix(160))) + separator
            let joined = prefix + current
            let boundary = joined.index(joined.startIndex, offsetBy: prefix.count)
            direct += matches(joined, raw: previous.text + separator + text, language: source, crossing: boundary)
        }
        let topicText = TermText.normalized(String(topic.prefix(120)))
        // Topic text may be in any supported language, but is never sent verbatim.
        let topicDomains: Set<String> = reset || resetPosition != nil ? [] : Set(cues.keys.flatMap { domains(in: topicText, language: $0) })
        direct = direct.filter { !excluded($0.entry, in: current) }
        let currentDomains = strongDomains(direct).union(domains(in: current, language: source))
        var active: [Int: Date] = [:]
        var activeDomains: Set<String> = topicDomains
        var previousTurn: TermMemoryTurn?
        for turn in relevant {
            let normalized = TermText.normalized(String(turn.text.prefix(1500)))
            var hits = matches(normalized, raw: turn.text, language: source)
            if let previousTurn, !resetsTopic(normalized) {
                let separator = source == "ja" || source.hasPrefix("zh") ? "" : " "
                let prefix = TermText.normalized(String(previousTurn.text.suffix(160))) + separator
                let joined = prefix + normalized
                let boundary = joined.index(joined.startIndex, offsetBy: prefix.count)
                hits += matches(joined, raw: previousTurn.text + separator + turn.text, language: source, crossing: boundary)
            }
            previousTurn = turn
            hits = hits.filter { !excluded($0.entry, in: normalized) }
            let evidence = strongDomains(hits).union(domains(in: normalized, language: source))
            if !evidence.isEmpty && !activeDomains.isEmpty && evidence.isDisjoint(with: activeDomains) { active.removeAll() }
            if !evidence.isEmpty { activeDomains = evidence }
            for hit in hits where !hit.possible && (!hit.short || activeDomains.contains(library.entries[hit.entry].domain)) {
                let entry = library.entries[hit.entry]
                if entry.kind == .fixed || activeDomains.contains(entry.domain) { active[hit.entry] = turn.date }
            }
            if active.count > 40 {
                let sorted = active.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                active = Dictionary(uniqueKeysWithValues: sorted.prefix(40).map { ($0.key, $0.value) })
            }
        }
        // Explicit evidence for a new domain wins over historical context.
        let allowed = selectedDomains ?? (currentDomains.isEmpty ? activeDomains : currentDomains)
        active = active.filter { allowed.contains(library.entries[$0.key].domain) }
        var ranked: [Int: (Int, Bool)] = [:]
        for hit in direct {
            let entry = library.entries[hit.entry]
            guard entry.forms[target] != nil, selectedDomains?.contains(entry.domain) ?? true else { continue }
            if (entry.kind == .contextual || hit.possible || hit.short) && !allowed.contains(entry.domain) { continue }
            let score = (hit.possible ? 50 : entry.kind == .fixed ? 100 : 80) + min(30, hit.length)
            if score > (ranked[hit.entry]?.0 ?? 0) { ranked[hit.entry] = (score, hit.possible) }
        }
        // Retain a little context for references, not for every unrelated sentence.
        let references: [String: [String]] = ["en": ["this result", "that test", "these results", "what does that mean", "why is that"], "ko": ["그 결과", "이 결과", "그것은"], "ja": ["その結果", "この結果", "それは"], "zh-CN": ["这个结果", "上述结果", "这说明"], "zh-TW": ["這個結果", "上述結果", "這說明"]]
        let refersBack = (references[source] ?? []).contains { !TermText.ranges(of: $0, in: current, language: source).isEmpty }
        if refersBack || !ranked.isEmpty {
            let remembered = active.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            for (id, date) in remembered.prefix(3) where ranked[id] == nil && !excluded(id, in: current) {
                if library.entries[id].forms[target] != nil { ranked[id] = (max(1, 35 - Int(now.timeIntervalSince(date) / 3)), false) }
            }
        }
        let candidates: [([String], String)] = ranked.sorted { a, b in
            a.value.0 == b.value.0 ? library.entries[a.key].id < library.entries[b.key].id : a.value.0 > b.value.0
        }.compactMap { id, score in
            let entry = library.entries[id]
            guard let sourceForm = entry.forms[source], let targetForm = entry.forms[target] else { return nil }
            var row = [sourceForm.preferred, targetForm.preferred, score.1 ? "possible" : entry.kind == .fixed ? "fixed" : "context"]
            if let note = entry.notes?[target], entry.kind == .contextual { row.append(String(note.prefix(50))) }
            return (row, entry.id)
        }
        return TerminologyHint.bounded(candidates, activeCount: active.count)
    }
}

// Immutable indexes are confined to this actor. No AI summarizer, embeddings,
// extra network calls, persistent meeting memory or completion-order mutation.
actor TerminologyService {
    private let root: URL
    private let bundledURL: URL?
    private let bundledWikidataURL: URL?
    private var library: TermLibrary?
    // Only the two most recently used source languages need an inverted index.
    // Target labels remain available in the shared, immutable library.
    private var indexes: [String: TerminologyIndex] = [:]
    private var indexOrder: [String] = []
    var cachedSourceLanguages: [String] { indexOrder }
    private var attemptedLoad = false
    private(set) var warning = ""
    private(set) var sourceSummary = "未安装 Wikidata 本地数据包"
    init(root: URL, bundledURL: URL? = Bundle.main.url(forResource: "terminology", withExtension: "json"),
         bundledWikidataURL: URL? = Bundle.main.url(forResource: "wikidata", withExtension: "json")) {
        self.root = root; self.bundledURL = bundledURL; self.bundledWikidataURL = bundledWikidataURL
    }
    var fileURL: URL { root.appendingPathComponent("Terminology/custom.json") }
    var wikidataURL: URL { root.appendingPathComponent("Terminology/wikidata.json") }

    private struct PackManifest: Decodable {
        var source: String
        var license: String
        var schemaVersion: Int
        var entries: Int
        var sha256: String
        var generatedAt: String
    }
    private func readPack(_ url: URL) throws -> (TermLibrary, PackManifest) {
        let manifestURL = url.deletingPathExtension().appendingPathExtension("manifest.json")
        guard (try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 65_536 else { throw TermLibrary.invalid() }
        let manifest = try JSONDecoder().decode(PackManifest.self, from: Data(contentsOf: manifestURL))
        let pack = try TermLibrary.read(url)
        let checksum = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        guard manifest.source == "Wikidata", manifest.license == "CC0-1.0", manifest.schemaVersion == 1,
              manifest.entries == pack.entries.count, checksum == manifest.sha256,
              pack.entries.allSatisfy({ $0.id.range(of: "^wd-Q[1-9][0-9]*$", options: .regularExpression) != nil }) else { throw TermLibrary.invalid() }
        return (pack, manifest)
    }
    func load() -> (Int, String) {
        if !attemptedLoad {
            attemptedLoad = true
            do {
                var base = try lowerLayers()
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    do { base = try Self.merged(base, TermLibrary.read(fileURL)) }
                    catch { warning += "自定义术语库未加载，原文件已保留；其他有效词库继续使用。" }
                }
                library = base
            } catch { warning = "术语库不可用，翻译继续，不添加术语提示。" }
        }
        return (library?.entries.count ?? 0, warning)
    }
    private func lowerLayers() throws -> TermLibrary {
        let seed = try bundledURL.map(TermLibrary.read) ?? TermLibrary(version: 1, domains: [], entries: [])
        // A verified user-installed update replaces the bundled snapshot;
        // the bundled pack remains an offline fallback, never a user file.
        var selected: TermLibrary?
        if FileManager.default.fileExists(atPath: wikidataURL.path) {
            do {
                let (pack, manifest) = try readPack(wikidataURL)
                selected = pack
                sourceSummary = "Wikidata 本地包 \(manifest.entries) 条 · \(manifest.generatedAt.prefix(10)) · CC0"
            } catch {
                let previous = wikidataURL.deletingLastPathComponent().appendingPathComponent("wikidata.previous.json")
                if let (pack, manifest) = try? readPack(previous) {
                    selected = pack
                    sourceSummary = "Wikidata 上一版本地包 \(manifest.entries) 条 · \(manifest.generatedAt.prefix(10))"
                    warning = "Wikidata 数据包校验失败，暂用上一版；文件均已保留。"
                } else { warning = "Wikidata 数据包未加载或校验失败，暂用内置与自定义词库；原文件已保留。" }
            }
        }
        if selected == nil, let bundledWikidataURL {
            do {
                let (pack, manifest) = try readPack(bundledWikidataURL)
                selected = pack
                sourceSummary = "随软件内置 · Wikidata \(manifest.entries) 条 · \(manifest.generatedAt.prefix(10)) · CC0"
            } catch { warning += "随软件附带的 Wikidata 词库校验失败，继续使用其他有效词库。" }
        }
        return try selected.map { try Self.merged($0, seed) } ?? seed
    }
    private static func merged(_ base: TermLibrary, _ custom: TermLibrary) throws -> TermLibrary {
        var domains = Dictionary(uniqueKeysWithValues: base.domains.map { ($0.id, $0) })
        for domain in custom.domains {
            var combined = domains[domain.id] ?? domain
            for (language, cues) in domain.cues {
                var seen = Set<String>()
                combined.cues[language] = Array((cues + (combined.cues[language] ?? [])).filter { seen.insert(TermText.normalized($0)).inserted }.prefix(32))
            }
            domains[domain.id] = combined
        }
        var entries = Dictionary(uniqueKeysWithValues: base.entries.map { ($0.id, $0) })
        // A custom ID always wins. Exact English preferred names in the same
        // domain also override the lower layer even when the IDs differ.
        func semanticKey(_ entry: ProfessionalTerm) -> String? {
            entry.forms["en"].map { entry.domain + "\n" + TermText.normalized($0.preferred) }
        }
        let byName = Dictionary(grouping: base.entries.compactMap { entry in semanticKey(entry).map { ($0, entry.id) } }, by: { $0.0 })
        for entry in custom.entries {
            let duplicates = semanticKey(entry).flatMap { byName[$0] }?.map { $0.1 } ?? []
            var combined = entry
            for id in Set(duplicates + [entry.id]).sorted() {
                guard let lower = entries.removeValue(forKey: id) else { continue }
                combined.forms = lower.forms.merging(combined.forms) { _, high in high }
                if combined.notes == nil { combined.notes = lower.notes }
                if combined.excludeCues == nil { combined.excludeCues = lower.excludeCues }
            }
            entries[entry.id] = combined
        }
        // Reserve capacity for every custom term, then curated builtins, then
        // the external pack's priority order. Never evict a custom entry merely
        // because an external update filled the 50k budget.
        var seen = Set<String>()
        let ordered = (custom.entries.map(\.id) + base.entries.map(\.id)).compactMap { id -> ProfessionalTerm? in
            guard seen.insert(id).inserted else { return nil }; return entries[id]
        }
        let sortedDomains = domains.values.sorted { $0.id < $1.id }
        let encoder = JSONEncoder()
        let originals = Dictionary(uniqueKeysWithValues: custom.entries.map { ($0.id, $0) })
        var bytes = try encoder.encode(TermLibrary(version: 1, domains: sortedDomains, entries: [])).count
        var selected: [ProfessionalTerm] = []
        // The aggregate also obeys the serialized budget. If lower-layer
        // language enrichment would crowd out the user's original, retain the
        // original instead; lower-priority terms may be omitted.
        var originalBytesRemaining = try custom.entries.reduce(0) { try $0 + encoder.encode($1).count + 1 }
        for candidate in ordered.prefix(TermLibrary.maximumEntries) {
            var entry = candidate
            var size = try encoder.encode(entry).count + 1
            if let original = originals[entry.id] {
                let originalSize = try encoder.encode(original).count + 1
                originalBytesRemaining -= originalSize
                if bytes + size + originalBytesRemaining > TermLibrary.maximumBytes { entry = original; size = originalSize }
                guard bytes + size <= TermLibrary.maximumBytes else { throw TermLibrary.invalid() }
            } else if bytes + size > TermLibrary.maximumBytes { continue }
            selected.append(entry); bytes += size
        }
        let library = TermLibrary(version: 1, domains: sortedDomains, entries: selected)
        try library.validate(); return library
    }
    private func clearIndexes() { indexes.removeAll(); indexOrder.removeAll() }
    private func index(for source: String) -> TerminologyIndex? {
        guard let library else { return nil }
        indexOrder.removeAll { $0 == source }; indexOrder.append(source)
        if let cached = indexes[source] { return cached }
        // Drop an unused index before allocating a replacement.
        if indexes.count >= 2, let oldest = indexOrder.first {
            indexes.removeValue(forKey: oldest); indexOrder.removeFirst()
        }
        guard let replacement = try? TerminologyIndex(library: library, sourceLanguages: [source]) else { return nil }
        indexes[source] = replacement
        return replacement
    }
    func availableDomains() -> [String] {
        _ = load()
        return (library?.domains.map(\.id) ?? MeetingDomain.allCases.map(\.rawValue)).sorted()
    }
    func prepare(source: String) { _ = load(); _ = index(for: source) }
    func reload() -> (Int, String) {
        clearIndexes(); library = nil; attemptedLoad = false; warning = ""; sourceSummary = "未安装 Wikidata 本地数据包"
        return load()
    }
    func importLibrary(_ url: URL) throws -> Int {
        let custom = try TermLibrary.read(url)
        // Rebuild the lower layers without the previously imported custom file.
        let base = try lowerLayers()
        let merged = try Self.merged(base, custom)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try Data(contentsOf: fileURL).write(to: fileURL.deletingLastPathComponent().appendingPathComponent("custom.previous.json"), options: .atomic)
        }
        try JSONEncoder().encode(custom).write(to: fileURL, options: .atomic)
        library = merged; clearIndexes(); attemptedLoad = true
        warning = warning.contains("Wikidata") ? warning : ""
        return merged.entries.count
    }
    func exportLibrary() throws -> Data {
        _ = load()
        guard let library else { throw TermLibrary.invalid() }
        let encoder = JSONEncoder(); encoder.outputFormatting = library.entries.count <= 1000 ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(library)
    }
    func hint(text: String, source: String, target: String, recent: [TermMemoryTurn], topic: String, now: Date, memory: Bool, selectedDomains: Set<String>? = nil) -> TerminologyHint? {
        guard source != target, !text.isEmpty else { return nil }
        _ = load()
        return index(for: source)?.retrieve(text: text, source: source, target: target, recent: recent, topic: topic, now: now, useMemory: memory, selectedDomains: selectedDomains)
    }
    static func recent(before job: AudioJob, in jobs: [AudioJob]) -> [TermMemoryTurn] {
        guard let position = jobs.firstIndex(where: { $0.id == job.id }) else { return [] }
        var turns: [TermMemoryTurn] = []
        for earlier in jobs[..<position].reversed() {
            guard earlier.deletedAt == nil, earlier.sessionID == job.sessionID, earlier.language == job.language,
                  earlier.resolvedTargetLanguage == job.resolvedTargetLanguage, earlier.stage != .recognize,
                  !earlier.original.isEmpty, !RepeatedText.containsRun(earlier.original),
                  (0...60).contains(job.created.timeIntervalSince(earlier.created)) else { continue }
            turns.append(TermMemoryTurn(text: String(earlier.original.prefix(1500)), date: earlier.created))
            if turns.count >= 40 { break }
        }
        return turns.reversed()
    }
}
