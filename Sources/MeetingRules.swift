import Foundation

struct SpeechWindow {
    var id: UUID
    var url: URL
    var date: Date
    var overlap: Bool
    var isFinal: Bool
    var duration: Double
}

enum MeetingRules {
    static let previewInterval = 4.0
    static let completePause = 0.7
    static let incompletePause = 1.5
    static let earliestNaturalCut = 7.0
    static let naturalCutSearchStart = 7.0
    static let maximumWindow = 10.0
    private static let sentencePunctuation = ".?!。？！؟۔।"

    private static let koreanFinalEndings = [
        "니다", "습니까", "읍시다", "십시오", "세요", "으세요",
        "아요", "어요", "해요", "예요", "이에요", "에요",
        "네요", "군요", "구나", "잖아요", "거든요", "지요", "죠",
        "나요", "까요", "인가요", "래요", "대요", "게요",
        "는다", "한다", "된다", "있다", "없다", "이다", "였다", "겠다", "았다", "었다",
        "간다", "온다", "본다", "같다", "맞다", "좋다"
    ]
    private static let koreanContinuingEndings = [
        "지만", "지만요", "면", "면서", "려고", "으려고", "고 나서",
        "어서", "아서", "해서", "더라도", "다가", "도록"
    ]
    private static let koreanAmbiguousEndings = ["데", "데요", "거든", "니까", "니까요", "고", "고요"]
    private static let koreanQuestionWords = ["뭐", "무엇", "무슨", "누구", "어디", "언제", "왜", "어떻", "어떤", "어느", "얼마", "몇", "어쩌"]

    static func looksComplete(_ text: String, language: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if language.hasPrefix("ko") { return looksCompleteInKorean(t) }
        if let last = t.last, sentencePunctuation.contains(last) {
            let words = t.lowercased().split(separator: " ")
            // Common unfinished English links should not become a sentence just
            // because a recognizer supplied punctuation.
            if language.hasPrefix("en"), let last = words.last?.trimmingCharacters(in: .punctuationCharacters),
               ["and", "but", "because", "if", "the", "a", "of", "to", "with", "that"].contains(last) { return false }
            return true
        }
        return false
    }

    private static func looksCompleteInKorean(_ text: String) -> Bool {
        let closingMarks = CharacterSet(charactersIn: "\"'”’」』)]}》〉】")
        let tail = text.trimmingCharacters(in: .whitespacesAndNewlines.union(closingMarks))
        guard let last = tail.last, !",，、:：;；".contains(last) else { return false }

        let marks = tail.reversed().prefix { sentencePunctuation.contains($0) || $0 == "…" }
        guard !marks.contains("…"), marks.filter({ $0 == "." }).count < 2 else { return false }
        let sentence = tail.dropLast(marks.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sentence.contains(where: { $0.isLetter || $0.isNumber }) else { return false }

        // Formal -ㅂ니까 and -ㅂ시다 attach ㅂ to the preceding syllable (갑니까, 봅시다).
        if sentence.hasSuffix("니까") || sentence.hasSuffix("시다"),
           let syllable = sentence.dropLast(2).last?.unicodeScalars.first?.value,
           (0xAC00...0xD7A3).contains(syllable), (syllable - 0xAC00) % 28 == 17 {
            return true
        }
        if koreanFinalEndings.contains(where: sentence.hasSuffix) { return true }
        if koreanContinuingEndings.contains(where: sentence.hasSuffix) { return false }
        if koreanAmbiguousEndings.contains(where: sentence.hasSuffix) {
            guard marks.contains("?") || marks.contains("？") else { return false }
            let lastClause = sentence.split(whereSeparator: { sentencePunctuation.contains($0) || ",，".contains($0) }).last ?? ""
            return lastClause.split(whereSeparator: \.isWhitespace).contains { word in
                let token = word.trimmingCharacters(in: .punctuationCharacters)
                return koreanQuestionWords.contains(where: token.hasPrefix)
            }
        }
        return !marks.isEmpty
    }

    static func shouldEnd(duration: Double, silence: Double, complete: Bool) -> Bool {
        // A longer silence eventually commits even a fragment: otherwise a quiet
        // teacher or an imperfect transcript could stall translation indefinitely.
        duration >= 1.0 && silence >= (complete ? completePause : incompletePause)
    }
}

struct DraftStability {
    private var history: [String] = []
    private(set) var stable = ""
    mutating func update(_ text: String) -> String {
        history.append(text); history = Array(history.suffix(3))
        guard history.count == 3 else { return text }
        var common = Array(history[0])
        for other in history.dropFirst() { common = Array(zip(common, other).prefix { $0.0 == $0.1 }.map { $0.0 }) }
        let prefix = String(common)
        // Stabilize complete words only; final recognition remains authoritative.
        if let boundary = prefix.lastIndex(where: { $0.isWhitespace || ".?!。？！".contains($0) }) {
            let candidate = String(prefix[...boundary])
            if candidate.count > stable.count && candidate.hasPrefix(stable) { stable = candidate }
        }
        // Preserve a repeatedly confirmed prefix in the temporary display. A
        // final recognition may still correct it before translation is submitted.
        if !stable.isEmpty && !text.hasPrefix(stable) {
            let count = stable.split(whereSeparator: \.isWhitespace).count
            let words = text.split(whereSeparator: \.isWhitespace)
            if words.count < count { return stable.trimmingCharacters(in: .whitespaces) }
            return stable + words.dropFirst(count).joined(separator: " ")
        }
        return text
    }
}
