import Foundation

final class TerminologyMock: URLProtocol {
    static var handler: ((URLRequest) throws -> String)?
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        do {
            let text = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct TerminologyTests {
    static var checks = 0
    static let now = Date(timeIntervalSince1970: 10_000)
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(value(), message)
    }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let value = request.httpBody { data = value }
        else {
            let stream = request.httpBodyStream!; stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 65536), collected = Data()
            while true { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; collected.append(contentsOf: bytes.prefix(n)) }
            data = collected
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    static func main() async throws {
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let url = project.appendingPathComponent("Resources/terminology.json")
        let library = try TermLibrary.read(url), index = try TerminologyIndex(library: library)
        func hint(_ text: String, source: String = "en", target: String = "zh-CN", history: [TermMemoryTurn] = [], topic: String = "", memory: Bool = true) -> TerminologyHint? {
            index.retrieve(text: text, source: source, target: target, recent: history, topic: topic, now: now, useMemory: memory)
        }
        func has(_ id: String, _ value: TerminologyHint?) -> Bool { value?.termIDs.contains(id) == true }
        let statistics = [TermMemoryTurn(text: "We used a Kruskal-Wallis test and repeated measures.", date: now.addingTimeInterval(-20))]
        let positives: [(String, String, String, String)] = [
            ("en", "zh-CN", "We used the Kruskal–Wallis test.", "kruskal-wallis"),
            ("en", "ko", "The repeated measures are available.", "repeated-measures"),
            ("en", "ja", "Compare confidence intervals.", "confidence-interval"),
            ("en", "zh-TW", "Use a mixed effects model.", "mixed-model"),
            ("ko", "zh-CN", "분산분석에서는 차이를 확인했습니다.", "anova"),
            ("ko", "en", "표본크기를 늘리겠습니다.", "sample-size"),
            ("ko", "ja", "반복측정의 결과입니다.", "repeated-measures"),
            ("ja", "en", "今回は反復測定を使用します。", "repeated-measures"),
            ("ja", "ko", "標本サイズを確認します。", "sample-size"),
            ("zh-CN", "en", "我们采用重复测量设计。", "repeated-measures"),
            ("zh-TW", "ja", "這次使用變異數分析。", "anova"),
            ("es", "zh-CN", "Usamos análisis de varianza.", "anova"),
            ("fr", "ko", "Une analyse de variance est nécessaire.", "anova"),
            ("de", "en", "Wir verwenden Varianzanalyse.", "anova")
        ]
        for (source, target, text, id) in positives {
            let result = hint(text, source: source, target: target)
            check(has(id, result), "multilingual positive: \(source) → \(target), \(text)")
            let row = result!.terms[result!.termIDs.firstIndex(of: id)!]
            check(row[1] == library.entries.first { $0.id == id }!.forms[target]!.preferred, "translation direction uses target form, not hardcoded Chinese")
        }
        check(has("anova", hint("ＡＮＯＶＡ was selected.")), "full-width Latin normalization")
        check(has("confidence-interval", hint("confidence\ninterval")), "whitespace normalization")
        check(!has("mean", hint("The meaning is clear.", topic: "statistics")), "Latin word boundaries reject substrings")
        for text in ["That gift is significant.", "The power is off.", "Please water the plant.", "What do you mean?", "We need social equity.", "The service has content moderation.", "The station is magnificent."] {
            check(hint(text) == nil, "ordinary language must not receive specialist hints: \(text)")
        }
        check(has("significant", hint("The result is significant.", history: statistics)), "recent terms disambiguate a following ordinary word")
        check(has("statistical-power", hint("The power is too low.", history: statistics)), "memory preserves statistical sense")
        check(has("significant", hint("The result is significant.", topic: "统计分析")), "meeting topic can be in a different language")
        check(has("plant", hint("The plant is operating.", topic: "manufacturing")), "domain cue enables contextual meaning")
        check(!has("statistical-power", hint("The power supply for the lights is off.", history: statistics)), "negative cues override active professional memory")
        check(!has("mean", hint("What do you mean?", history: statistics)), "ordinary verb survives statistical context")
        check(!has("moderation", hint("We need content moderation.", history: statistics)), "ordinary phrase blocks a specialist sense")
        let expired = statistics.map { TermMemoryTurn(text: $0.text, date: now.addingTimeInterval(-60.01)) }
        check(hint("The power is low.", history: expired) == nil, "memory expires after 60 seconds")
        check(hint("The power is low.", history: statistics, memory: false) == nil, "memory off suppresses history")
        check(hint("What does that mean?", history: statistics) != nil, "bounded active terms help an implicit reference")
        check(hint("This sandwich is delicious.", history: statistics) == nil, "unrelated new utterance does not blindly receive active terms")
        check(hint("New topic: what does that mean?", history: statistics) == nil, "explicit topic switch resets memory")
        let resetHistory = statistics + [TermMemoryTurn(text: "New topic.", date: now.addingTimeInterval(-5))]
        check(hint("What does that mean?", history: resetHistory) == nil, "later turns cannot revive terms from before an explicit reset")
        check(hint("The power is low.", history: resetHistory, topic: "statistics") == nil, "reset boundary also suppresses stale manual topic on following turns")
        let resetWithDomain = resetHistory + [TermMemoryTurn(text: "The patient has hypertension.", date: now.addingTimeInterval(-2))]
        let resetResult = hint("This result is unexpected.", history: resetWithDomain, topic: "statistics")
        check(has("hypertension", resetResult) && !has("kruskal-wallis", resetResult), "new evidence after reset establishes fresh memory")
        let ordinaryHistory = statistics + [TermMemoryTurn(text: "The power supply for the lights is off.", date: now.addingTimeInterval(-5))]
        check(!has("statistical-power", hint("This result is unexpected.", history: ordinaryHistory)), "excluded ordinary senses are not learned into active memory")
        let medical = hint("The patient has hypertension.", history: statistics)
        check(has("hypertension", medical) && !has("kruskal-wallis", medical), "new explicit domain wins over stale statistics")
        let newTopic = statistics + [TermMemoryTurn(text: "The patient has hypertension.", date: now.addingTimeInterval(-2))]
        check(!has("statistical-power", hint("The power is low.", history: newTopic, topic: "statistics")), "new domain remains dominant over a stale manual topic on subsequent turns")
        check(hint("ICC will attend.") == nil, "short acronym requires domain evidence")
        check(has("icc", hint("The statistical ICC is high.")), "short acronym accepted with domain evidence")
        check(!has("icc", hint("The statistical icc is high.")), "case-sensitive short acronym cannot match arbitrary lowercase text")
        check(hint("Kruskel-Wallis test") == nil, "spelling correction is not trusted without domain evidence")
        let fuzzy = hint("The statistical Kruskel-Wallis test was selected.")
        check(has("kruskal-wallis", fuzzy) && fuzzy?.terms.first?[2] == "possible", "one-edit misspelling is a tentative hint, not source replacement")
        let variant = hint("The statistical Kruskal Wallace test was selected.")
        check(has("kruskal-wallis", variant) && variant?.terms.first?[2] == "possible", "curated ASR variant stays tentative")
        let crossed = hint("Wallis test was used.", history: [TermMemoryTurn(text: "We chose Kruskal", date: now.addingTimeInterval(-3))])
        check(has("kruskal-wallis", crossed), "term split across subtitle boundary is retrieved")
        let splitHistory = [TermMemoryTurn(text: "We chose Kruskal", date: now.addingTimeInterval(-5)), TermMemoryTurn(text: "Wallis test was used.", date: now.addingTimeInterval(-3))]
        check(has("kruskal-wallis", hint("What does that mean?", history: splitHistory)), "cross-fragment terms remain active for following references")
        let chineseCrossed = hint("量的结果。", source: "zh-CN", target: "en", history: [TermMemoryTurn(text: "我们使用重复测", date: now.addingTimeInterval(-3))])
        check(has("repeated-measures", chineseCrossed), "CJK term split mid-word is rejoined locally")
        check(hint("The power is low.", target: "ar", topic: "statistics") == nil, "missing target expression never fabricates a translation")
        check(hint("Kruskal-Wallis test", target: "en") == nil, "same-language path needs no hints")
        let crowded = hint("Kruskal-Wallis test, Mann-Whitney U test, Wilcoxon test, repeated measures, analysis of variance, confidence interval, sample size, statistical significance, power, significant.")!
        check(crowded.terms.count <= 8 && crowded.estimatedTokens <= 300, "ranking respects term and estimated-token caps")
        check((crowded.encoded + TerminologyHint.instructions + "\"terminology\":").utf8.count <= 900, "serialized hint has hard byte cap")
        check(crowded.termIDs == hint("Kruskal-Wallis test, Mann-Whitney U test, Wilcoxon test, repeated measures, analysis of variance, confidence interval, sample size, statistical significance, power, significant.")!.termIDs, "deterministic ranking")
        print("Offline positive retrieval: \(positives.count)/\(positives.count); crowded prompt: \(crowded.terms.count) terms, estimated \(crowded.estimatedTokens) tokens")

        try await providerTests(index: index)
        try await storageTests(library: library, url: url)
        try historyTests()
        try performanceTests(library: library)
        print("PASS: \(checks) terminology checks — local retrieval, multilingual directions, memory, risk, budgets, providers, import, performance")
    }

    static func providerTests(index: TerminologyIndex) async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TerminologyMock.self]
        let session = URLSession(configuration: config)
        let text = "The statistical power is low."
        let hint = index.retrieve(text: text, source: "en", target: "zh-CN", now: now)!
        var settings = AppSettings(); settings.provider = .custom; settings.baseURL = "https://example.invalid/v1"; settings.model = "fake-model"
        for provider in [TranslationProvider.custom, .indexTranslate] {
            settings.provider = provider
            TerminologyMock.handler = { request in
                let body = try self.body(request), messages = body["messages"] as! [[String: String]]
                let message = messages.last!["content"]!
                let json: [String: Any]
                if provider == .indexTranslate {
                    let input = message.components(separatedBy: "会议资料：\n").last!
                    json = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
                    check(request.value(forHTTPHeaderField: "Authorization") == nil, "Index never receives custom key")
                    check((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false, "Index thinking remains disabled")
                } else {
                    json = try JSONSerialization.jsonObject(with: Data(message.utf8)) as! [String: Any]
                    check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-only", "custom authorization unchanged")
                }
                check(json["current"] as? String == text, "recognized source is byte-for-byte unchanged")
                check(json["terminology"] as? [[String]] == hint.terms, "only bounded selected terminology is sent")
                check(messages.map { $0["content"]! }.joined().contains("possible"), "prompt distinguishes tentative candidates from fixed terms")
                return "{\"choices\":[{\"message\":{\"content\":\"统计功效偏低。\"}}]}"
            }
            let count = TerminologyMock.requests
            let output = try await TranslationClient(settings: settings, key: "fake-only", session: session).translate(text, language: "en-US", terminology: hint)
            check(output == "统计功效偏低。" && TerminologyMock.requests == count + 1, "one request, no auxiliary model call")
        }
        settings.provider = .custom
        TerminologyMock.handler = { request in
            let messages = try self.body(request)["messages"] as! [[String: String]]
            let json = try JSONSerialization.jsonObject(with: Data(messages.last!["content"]!.utf8)) as! [String: Any]
            check(json["terminology"] == nil, "no match or disabled feature adds no payload field")
            check(!messages[0]["content"]!.contains(TerminologyHint.instructions), "no match adds no terminology instructions")
            return "{\"choices\":[{\"message\":{\"content\":\"你好\"}}]}"
        }
        _ = try await TranslationClient(settings: settings, key: "", session: session).translate("Hello.", language: "en-US")
        settings.useTerminology = false
        _ = try await TranslationClient(settings: settings, key: "", session: session).translate(text, language: "en-US", terminology: hint)
        settings.useTerminology = true
        for provider in [TranslationProvider.googleFree, .googleCloud] {
            settings.provider = provider
            TerminologyMock.handler = { request in
                if provider == .googleFree {
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                    check(query.first { $0.name == "q" }?.value == text && query.count == 5, "Google free q is unchanged and has no prompt")
                    return "[[[\"功效偏低\",\"source\"]]]"
                }
                let json = try self.body(request)
                check(json["q"] as? String == text && Set(json.keys) == ["q", "source", "target", "format"], "Google v2 fields remain compatible; no fake glossary support")
                return "{\"data\":{\"translations\":[{\"translatedText\":\"功效偏低\"}]}}"
            }
            _ = try await TranslationClient(settings: settings, key: "fake-google", session: session).translate(text, language: "en-US", terminology: hint)
        }
        var legacy: [String: Any] = ["model": "preserve", "provider": TranslationProvider.custom.rawValue, "useTranslationContext": false]
        var migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(migrated.useTerminology && migrated.useTerminologyMemory && migrated.terminologyTopic.isEmpty && !migrated.useTranslationContext && migrated.model == "preserve", "settings migration preserves existing context and provider")
        legacy["useTerminology"] = false; legacy["useTerminologyMemory"] = false; legacy["terminologyTopic"] = String(repeating: "话", count: 200)
        migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(!migrated.useTerminology && !migrated.useTerminologyMemory && migrated.terminologyTopic.count == 120, "settings switches and topic bounds")
    }

    static func storageTests(library: TermLibrary, url: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-terms-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = TerminologyService(root: root, bundledURL: url)
        let loaded = await service.load()
        check(loaded.0 == library.entries.count && loaded.1.isEmpty, "bundled library loads once")
        var custom = library
        custom.entries = [library.entries[0]]; custom.entries[0].forms["zh-CN"]!.preferred = "自定义译名"
        let customURL = root.appendingPathComponent("import.json")
        try JSONEncoder().encode(custom).write(to: customURL)
        let count = try await service.importLibrary(customURL)
        check(count == library.entries.count, "import merges by stable ID rather than duplicating builtins")
        let result = await service.hint(text: "Kruskal-Wallis test", source: "en", target: "zh-CN", recent: [], topic: "", now: now, memory: true)
        check(result?.terms.first?[1] == "自定义译名", "imported target form is effective")
        _ = try await service.importLibrary(customURL)
        let file = await service.fileURL
        check(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("custom.previous.json").path), "replacement retains previous local import")
        let original = try Data(contentsOf: file)
        custom.entries.append(custom.entries[0]); try JSONEncoder().encode(custom).write(to: customURL)
        do { _ = try await service.importLibrary(customURL); preconditionFailure("duplicate IDs accepted") } catch { checks += 1 }
        check(try! Data(contentsOf: file) == original, "invalid import never overwrites working library")
        let exported = try await service.exportLibrary()
        check(try! JSONDecoder().decode(TermLibrary.self, from: exported).entries.count == count, "full multilingual library exports")
        let brokenRoot = root.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: brokenRoot.appendingPathComponent("Terminology"), withIntermediateDirectories: true)
        let broken = brokenRoot.appendingPathComponent("Terminology/custom.json")
        try Data("broken".utf8).write(to: broken)
        let degraded = await TerminologyService(root: brokenRoot, bundledURL: url).load()
        check(degraded.0 == library.entries.count && !degraded.1.isEmpty && (try! Data(contentsOf: broken)) == Data("broken".utf8), "corrupt custom library falls back without erasing user file")
        let absent = await TerminologyService(root: root.appendingPathComponent("absent"), bundledURL: root.appendingPathComponent("missing.json")).load()
        check(absent.0 == 0 && !absent.1.isEmpty, "missing bundle disables enhancement, not translation")
        let repeatedAbsent = await TerminologyService(root: root.appendingPathComponent("absent2"), bundledURL: root.appendingPathComponent("missing.json")).hint(text: "power", source: "en", target: "zh-CN", recent: [], topic: "statistics", now: now, memory: true)
        check(repeatedAbsent == nil, "unavailable index safely returns no hint")
        var invalid = library; invalid.entries[0].forms["xx"] = TermForm(preferred: "invalid")
        do { try invalid.validate(); preconditionFailure("unknown language") } catch { checks += 1 }
        invalid = library; invalid.entries[0].forms["en"]!.preferred = "bad\nvalue"
        do { try invalid.validate(); preconditionFailure("control character") } catch { checks += 1 }
        let international = ProfessionalTerm(id: "international", domain: "statistics", kind: .fixed, forms: [
            "en": TermForm(preferred: "international test"), "ru": TermForm(preferred: "статистический тест"),
            "ar": TermForm(preferred: "اختبار إحصائي"), "hi": TermForm(preferred: "सांख्यिकीय परीक्षण"),
            "vi": TermForm(preferred: "kiểm định"), "th": TermForm(preferred: "การทดสอบ")
        ])
        let internationalIndex = try TerminologyIndex(library: TermLibrary(version: 1, domains: library.domains, entries: [international]))
        for (language, form) in international.forms where language != "en" {
            let result = internationalIndex.retrieve(text: form.preferred, source: language, target: "en", now: now)
            check(result?.termIDs == ["international"], "Unicode marks and script preservation: \(language)")
        }
    }

    static func historyTests() throws {
        let session = UUID(), other = UUID()
        func job(_ text: String, seconds: Double, meeting: UUID, language: String = "en-US", target: MeetingLanguage = .simplifiedChinese) -> AudioJob {
            var j = AudioJob(id: UUID(), sessionID: meeting, created: now.addingTimeInterval(seconds), audioFile: "test.wav", language: language, localRecognition: true, targetLanguage: target)
            j.original = text; j.stage = .translate; return j
        }
        let valid = job("Kruskal-Wallis test", seconds: -20, meeting: session)
        var deleted = job("deleted", seconds: -3, meeting: session); deleted.deletedAt = now
        var unrecognized = job("preview only", seconds: -2, meeting: session); unrecognized.stage = .recognize
        let current = job("current", seconds: 0, meeting: session)
        let jobs = [job("old", seconds: -61, meeting: session), job("other meeting", seconds: -40, meeting: other), valid,
                    job("wrong direction", seconds: -10, meeting: session, target: .japanese), job("다른 언어", seconds: -9, meeting: session, language: "ko-KR"), deleted, unrecognized,
                    job(String(repeating: "아", count: 20), seconds: -1, meeting: session), current, job("future", seconds: 1, meeting: session)]
        let recent = TerminologyService.recent(before: current, in: jobs)
        check(recent.count == 1 && recent[0].text == valid.original, "memory isolates capture order, session, direction, language, expiry, deletion and repetition")
        var newMeeting = current; newMeeting.sessionID = UUID()
        var newJobs = jobs; newJobs[8] = newMeeting
        check(TerminologyService.recent(before: newMeeting, in: newJobs).isEmpty, "new meeting and clear cannot revive old memory")
    }

    static func performanceTests(library: TermLibrary) throws {
        var large = library
        for i in 0..<20_000 {
            large.entries.append(ProfessionalTerm(id: "benchmark-\(i)", domain: "statistics", kind: .fixed,
                forms: ["en": TermForm(preferred: "syntheticterm\(i) measure"), "zh-CN": TermForm(preferred: "合成专业术语\(i)")]))
        }
        let started = ProcessInfo.processInfo.systemUptime
        let index = try TerminologyIndex(library: large)
        let build = ProcessInfo.processInfo.systemUptime - started
        var times: [Double] = []
        let recent = (0..<40).map { TermMemoryTurn(text: "The Kruskal-Wallis test has statistical significance.", date: now.addingTimeInterval(Double(-$0))) }
        for i in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            let result = index.retrieve(text: i % 2 == 0 ? "syntheticterm19999 measure" : "The power is too low.", source: "en", target: "zh-CN", recent: recent, now: now)
            times.append(ProcessInfo.processInfo.systemUptime - start)
            check(result != nil && result!.estimatedTokens <= 300 && result!.activeCount <= 40, "20k indexed lookup stays bounded")
        }
        let sorted = times.sorted(), p95 = sorted[94]
        check(p95 < 0.25, "20k lookup does not approach a network round trip")
        print(String(format: "20k library: build %.3f s; retrieval with 40 turns mean %.2f ms, p95 %.2f ms", build, times.reduce(0,+)/Double(times.count)*1000, p95*1000))
        var many = library
        many.entries += large.entries.suffix(100)
        let memoryIndex = try TerminologyIndex(library: many)
        let turns = (0..<40).map { i in TermMemoryTurn(text: "syntheticterm\(19900+i*2) measure syntheticterm\(19901+i*2) measure", date: now.addingTimeInterval(Double(i - 40))) }
        let active = memoryIndex.retrieve(text: "What does that mean?", source: "en", target: "zh-CN", recent: turns, now: now)
        check(active?.activeCount == 40, "active memory is capped at forty even when more terms were discussed")
    }
}
