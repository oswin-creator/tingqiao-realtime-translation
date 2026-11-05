import Foundation
import Darwin

// Optional local-data audit. No URLSession, credentials, or meeting records.
@main struct WikidataTerminologyAudit {
    static func seconds() -> Double { ProcessInfo.processInfo.systemUptime }
    static func peakMiB() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1024 / 1024
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let baseline = peakMiB(), started = seconds()
        let library: TermLibrary
        do { library = try TermLibrary.read(file) }
        catch {
            if let raw = try? JSONDecoder().decode(TermLibrary.self, from: Data(contentsOf: file)) {
                do { try TermLibrary(version: raw.version, domains: raw.domains, entries: []).validate() }
                catch { print("INVALID domain metadata: \(String(decoding: try JSONEncoder().encode(raw.domains), as: UTF8.self))") }
                for entry in raw.entries {
                    do { try TermLibrary(version: raw.version, domains: raw.domains, entries: [entry]).validate() }
                    catch { print("INVALID entry: \(String(decoding: try JSONEncoder().encode(entry), as: UTF8.self))") }
                    for (language, form) in entry.forms {
                        if TermText.normalized(form.preferred).count < 2 { print("INVALID preferred graphemes: \(entry.id) \(language) \(String(reflecting: form.preferred))") }
                        for text in [form.preferred] + (form.aliases ?? []) {
                            if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                                print("INVALID control: \(entry.id) \(language) \(String(reflecting: text))")
                            }
                        }
                    }
                }
            }
            throw error
        }
        let parseSeconds = seconds() - started
        var report: [String: Any] = ["entries": library.entries.count, "bytes": try Data(contentsOf: file).count,
            "parseSeconds": parseSeconds, "initialPeakMiB": baseline]
        let now = Date(), recent = (0..<40).map { TermMemoryTurn(text: "We evaluated statistical significance with analysis of variance.", date: now.addingTimeInterval(Double(-$0))) }
        var results: [[String: Any]] = []
        var indexes: [TerminologyIndex] = []
        for source in ["en", "ko"] {
            let start = seconds()
            let index = try TerminologyIndex(library: library, sourceLanguages: [source])
            indexes.append(index)
            let indexSeconds = seconds() - start
            var times: [Double] = [], hits = 0, samples = 0
            for domain in library.domains {
                let entries = library.entries.filter { $0.domain == domain.id && $0.forms[source] != nil && $0.forms[source == "en" ? "ko" : "en"] != nil }
                let topic = domain.cues["en"]?.first ?? ""
                for entry in entries.prefix(40) {
                    let begin = seconds()
                    let hint = index.retrieve(text: entry.forms[source]!.preferred, source: source, target: source == "en" ? "ko" : "en", topic: topic, now: now)
                    times.append(seconds() - begin); samples += 1
                    if hint?.termIDs.contains(entry.id) == true { hits += 1 }
                    precondition(hint == nil || hint!.estimatedTokens <= 300)
                }
            }
            var memoryTimes: [Double] = []
            if source == "en" {
                for _ in 0..<50 {
                    let begin = seconds()
                    let hint = index.retrieve(text: "The power is too low.", source: source, target: "ko", recent: recent, topic: "statistics", now: now)
                    memoryTimes.append(seconds() - begin)
                    precondition(hint == nil || (hint!.activeCount <= 40 && hint!.estimatedTokens <= 300))
                }
                for text in ["Hello, how are you?", "What do you mean?", "The power supply for the lights is off.", "This coffee tastes good."] {
                    precondition(index.retrieve(text: text, source: source, target: "ko", now: now) == nil, "ordinary sentence gained specialist hints: \(text)")
                }
            }
            let sorted = times.sorted(), memorySorted = memoryTimes.sorted()
            results.append(["source": source, "indexSeconds": indexSeconds, "sampleHits": hits, "samples": samples,
                "retrievalMeanMS": times.isEmpty ? 0 : times.reduce(0, +) / Double(times.count) * 1000,
                "retrievalP95MS": sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000,
                "memory40P95MS": memorySorted.isEmpty ? 0 : memorySorted[47] * 1000])
        }
        report["sourceIndexes"] = results
        report["peakMiBWithTwoSourceIndexes"] = peakMiB()
        report["peakDeltaMiB"] = peakMiB() - baseline
        report["totalSeconds"] = seconds() - started
        report["note"] = "real local Wikidata labels; sampled retrieval is not translation accuracy; peak RSS is whole audit process, not application memory"
        // Keep both indexes alive for the measured peak, not all 16 languages.
        withExtendedLifetime(indexes) {}
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)
        print(String(decoding: data, as: UTF8.self))
    }
}
