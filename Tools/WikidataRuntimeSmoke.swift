import Foundation
import Darwin

// Read-only smoke test of the actual installed data layers; no app records.
@main struct WikidataRuntimeSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: WikidataRuntimeSmoke APP_DATA_ROOT BUNDLED_TERMINOLOGY_JSON\n", stderr)
            exit(2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundled = URL(fileURLWithPath: CommandLine.arguments[2])
        let service = TerminologyService(root: root, bundledURL: bundled)
        let result = await service.load()
        precondition(result.0 > 31 && result.1.isEmpty, "installed data layers did not load cleanly")
        let english = await service.hint(text: "normal distribution", source: "en", target: "ko", recent: [], topic: "statistics", now: Date(), memory: true)
        let korean = await service.hint(text: "정규 분포", source: "ko", target: "en", recent: [], topic: "statistics", now: Date(), memory: true)
        let externalEnglish = await service.hint(text: "differential equation", source: "en", target: "ko", recent: [], topic: "mathematics", now: Date(), memory: true)
        let externalKorean = await service.hint(text: "미분방정식", source: "ko", target: "en", recent: [], topic: "mathematics", now: Date(), memory: true)
        let hints = [english, korean, externalEnglish, externalKorean].compactMap { $0 }
        precondition(hints.count == 4, "real EN/KO terminology was not retrieved")
        precondition(externalEnglish!.termIDs.contains("wd-Q11214") && externalKorean!.termIDs.contains("wd-Q11214"), "external concept was not retrieved")
        precondition(hints.allSatisfy { $0.estimatedTokens <= 300 && $0.terms.count <= 8 && ($0.encoded + "\"terminology\":" + TerminologyHint.instructions).utf8.count <= 900 })
        let cached = await service.cachedSourceLanguages
        precondition(cached.count == 2)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("PASS: installed layers; effective entries \(result.0); builtin/external EN/KO lookup; hint budget; cached languages \(cached.joined(separator: ",")); audit-process peak \(Double(usage.ru_maxrss) / 1024 / 1024) MiB")
        print(await service.sourceSummary)
    }
}
