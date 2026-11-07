import Foundation
import CryptoKit

@main struct WikidataTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(value(), message)
    }
    static func pack(_ library: TermLibrary, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(library)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = ["source": "Wikidata", "license": "CC0-1.0", "schemaVersion": 1,
            "entries": library.entries.count, "sha256": sha, "generatedAt": "2026-11-05T00:00:00Z"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.deletingPathExtension().appendingPathExtension("manifest.json"), options: .atomic)
        try data.write(to: url, options: .atomic)
    }
    static func main() async throws {
        let project = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-wikidata-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = project.appendingPathComponent("Resources/terminology.json")
        let seed = try TermLibrary.read(bundle)
        let newTerm = ProfessionalTerm(id: "wd-Q991100", domain: "computer-science", kind: .fixed,
            forms: ["en": TermForm(preferred: "specialist lattice operator"), "ko": TermForm(preferred: "전문 격자 연산자"),
                    "ja": TermForm(preferred: "専門格子演算子"), "zh-CN": TermForm(preferred: "测试外部算子")])
        var duplicate = seed.entries.first { $0.id == "anova" }!
        duplicate.id = "wd-Q991101"; duplicate.forms["zh-CN"]!.preferred = "外部测试译名"
        duplicate.forms["it"] = TermForm(preferred: "analisi della varianza")
        var external = TermLibrary(version: 1, domains: seed.domains + [TermDomain(id: "computer-science", cues: ["en": ["computer science"], "ko": ["컴퓨터 과학"]])], entries: [newTerm, duplicate])
        let url = root.appendingPathComponent("Terminology/wikidata.json")
        try pack(external, at: url)
        let service = TerminologyService(root: root, bundledURL: bundle)
        var loaded = await service.load()
        check(loaded.0 == seed.entries.count + 1 && loaded.1.isEmpty, "external entries merged with semantic deduplication")
        let summary = await service.sourceSummary
        check(summary.contains("Wikidata") && summary.contains("2 条"), "source and snapshot count visible without reading all provenance")
        func hint(_ text: String, source: String = "en", target: String = "zh-CN") async -> TerminologyHint? {
            await service.hint(text: text, source: source, target: target, recent: [], topic: "", now: Date(), memory: true)
        }
        var value = await hint("analysis of variance")
        check(value?.terms.first?[1] == "方差分析", "curated builtin beats external translation")
        value = await hint("analysis of variance", target: "it")
        check(value?.terms.first?[1] == "analisi della varianza", "external languages missing in builtin survive overlay")
        value = await hint("specialist lattice operator")
        check(value?.terms.first?[1] == "测试外部算子", "external data available offline")
        value = await hint("전문 격자 연산자", source: "ko", target: "en")
        check(value?.terms.first?[1] == "specialist lattice operator", "Korean source does not depend on English-only index")
        value = await hint("専門格子演算子", source: "ja", target: "ko")
        check(value?.terms.first?[1] == "전문 격자 연산자", "other source language index is built on demand")
        let cached = await service.cachedSourceLanguages
        check(cached.count == 2 && cached == ["ko", "ja"], "only two active language indexes are retained")
        value = await hint("specialist lattice operator", target: "ar")
        check(value == nil, "missing Arabic label is not generated or copied from English")

        var customTerm = newTerm; customTerm.id = "my-operator"; customTerm.forms = ["en": newTerm.forms["en"]!, "zh-CN": TermForm(preferred: "用户优先算子")]
        let custom = TermLibrary(version: 1, domains: external.domains, entries: [customTerm])
        let customURL = root.appendingPathComponent("user-import.json")
        try JSONEncoder().encode(custom).write(to: customURL)
        _ = try await service.importLibrary(customURL)
        value = await hint("specialist lattice operator")
        check(value?.termIDs == ["my-operator"] && value?.terms.first?[1] == "用户优先算子", "custom overrides matching term even with a different ID")
        value = await hint("전문 격자 연산자", source: "ko", target: "zh-CN")
        check(value?.terms.first?[1] == "用户优先算子", "custom override retains missing source languages from lower layer")
        let customBefore = try Data(contentsOf: root.appendingPathComponent("Terminology/custom.json"))

        external.entries[0].forms["zh-CN"]!.preferred = "更新后的外部算子"
        try pack(external, at: url)
        _ = await service.reload()
        value = await hint("specialist lattice operator")
        check(value?.terms.first?[1] == "用户优先算子", "external updates never overwrite custom priority")
        check((try! Data(contentsOf: root.appendingPathComponent("Terminology/custom.json"))) == customBefore, "custom bytes unchanged across reload")

        let previous = root.appendingPathComponent("Terminology/wikidata.previous.json")
        try pack(external, at: previous)
        try Data("corrupt".utf8).write(to: url)
        loaded = await service.reload()
        check(loaded.0 == seed.entries.count + 1 && loaded.1.contains("上一版"), "broken current data uses verified previous pack")
        value = await hint("specialist lattice operator")
        check(value?.terms.first?[1] == "用户优先算子", "fallback still preserves custom layer")
        try Data("corrupt previous".utf8).write(to: previous)
        loaded = await service.reload()
        check(loaded.0 == seed.entries.count + 1 && loaded.1.contains("校验失败"), "both packs invalid still allow seed and custom")
        check((try! Data(contentsOf: url)) == Data("corrupt".utf8), "broken data is never deleted")

        try pack(external, at: url)
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("manifest.json"))) as! [String: Any]
        manifest["sha256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: manifest).write(to: url.deletingPathExtension().appendingPathExtension("manifest.json"))
        loaded = await service.reload()
        check(loaded.1.contains("校验失败"), "mismatched update pair is rejected")

        // A fresh install must have the same offline pack without writing to
        // Application Support, and a corrupt update must fall back to it.
        let freshRoot = root.appendingPathComponent("fresh-install")
        let shipped = root.appendingPathComponent("app-resources/wikidata.json")
        try pack(external, at: shipped)
        let offline = TerminologyService(root: freshRoot, bundledURL: bundle, bundledWikidataURL: shipped)
        var bundledLoad = await offline.load()
        check(bundledLoad.0 == seed.entries.count + 1 && bundledLoad.1.isEmpty, "fresh install uses verified bundled pack offline")
        let bundledSummary = await offline.sourceSummary
        check(bundledSummary.contains("随软件内置"), "source identifies bundled data")
        check(!FileManager.default.fileExists(atPath: freshRoot.path), "loading bundled pack never copies into user directory")
        let brokenUpdate = freshRoot.appendingPathComponent("Terminology/wikidata.json")
        try FileManager.default.createDirectory(at: brokenUpdate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken update".utf8).write(to: brokenUpdate)
        bundledLoad = await offline.reload()
        check(bundledLoad.0 == seed.entries.count + 1 && !bundledLoad.1.isEmpty, "corrupt update falls back to bundled pack")
        _ = try await offline.importLibrary(customURL)
        let offlineHint = await offline.hint(text: "전문 격자 연산자", source: "ko", target: "zh-CN", recent: [], topic: "", now: Date(), memory: true)
        check(offlineHint?.terms.first?[1] == "用户优先算子", "custom import overlays bundled fallback and retains languages")
        let offlineExport = try await offline.exportLibrary()
        let exportLibrary = try JSONDecoder().decode(TermLibrary.self, from: offlineExport)
        check(exportLibrary.entries.count == seed.entries.count + 1, "export contains merged bundled and custom terms")
        check((try! Data(contentsOf: brokenUpdate)) == Data("broken update".utf8), "fallback leaves user update untouched")
        var replacement = external; replacement.entries = [newTerm]
        try pack(replacement, at: brokenUpdate)
        _ = await offline.reload()
        let updatedSummary = await offline.sourceSummary
        check(!updatedSummary.contains("随软件内置"), "valid local update takes priority over bundled snapshot")
        let actualPack = project.appendingPathComponent("Resources/wikidata.json")
        let actual = TerminologyService(root: root.appendingPathComponent("real-bundled"), bundledURL: bundle, bundledWikidataURL: actualPack)
        let actualLoad = await actual.load()
        check(actualLoad.0 == 14_251 && actualLoad.1.isEmpty, "shipped real pack yields 14251 valid deduplicated terms")
        let actualHint = await actual.hint(text: "differential equation", source: "en", target: "ko", recent: [], topic: "mathematics", now: Date(), memory: true)
        check(actualHint?.termIDs.contains("wd-Q11214") == true, "real bundled pack supports English to Korean retrieval")

        // A full custom library must not be rejected because an external pack
        // or the 31 seeds used up its previous capacity.
        let capacityRoot = root.appendingPathComponent("capacity")
        try pack(external, at: capacityRoot.appendingPathComponent("Terminology/wikidata.json"))
        var full = TermLibrary(version: 1, domains: [seed.domains[0]], entries: [])
        for n in 0..<50_000 {
            full.entries.append(ProfessionalTerm(id: "user-\(n)", domain: seed.domains[0].id, kind: .fixed,
                forms: ["en": TermForm(preferred: "userterm\(n) measurement"), "ko": TermForm(preferred: "사용자 용어\(n)")]))
        }
        let capacityService = TerminologyService(root: capacityRoot, bundledURL: bundle)
        let capacityImport = root.appendingPathComponent("capacity-import.json")
        try JSONEncoder().encode(full).write(to: capacityImport)
        let count = try await capacityService.importLibrary(capacityImport)
        check(count == 50_000, "all 50k custom terms retained under aggregate budget")
        let exported = try await capacityService.exportLibrary()
        let final = try JSONDecoder().decode(TermLibrary.self, from: exported)
        check(final.entries.allSatisfy { $0.id.hasPrefix("user-") }, "lower layers are evicted before any user entry")
        check(final.entries.contains { $0.id == "user-49999" }, "last user entry cannot be silently lost")
        print("PASS: \(checks) Wikidata layer checks — local-only, checksum, dedup, priority, updates, fallback, capacity, two-language cache")
    }
}
