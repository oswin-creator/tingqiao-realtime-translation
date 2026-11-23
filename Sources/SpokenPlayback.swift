import Foundation
import Combine

struct SpokenLine {
    let id: UUID
    let text: String
    let language: MeetingLanguage
    let availableAt: Date
    var textOffset = 0

    func remaining(_ text: String) -> Self {
        Self(id: id, text: text, language: language, availableAt: availableAt,
             textOffset: textOffset + (self.text.hasSuffix(text) ? self.text.utf16.count - text.utf16.count : 0))
    }

    var estimatedDuration: Double {
        let weight = text.unicodeScalars.reduce(0.0) { $0 + ($1.isASCII ? 0.32 : 1) }
        return max(0.6, weight / 5)
    }
}

private final class SpokenUtterance {
    let line: SpokenLine
    let ticket = UUID()
    var sampleRate = 0
    var audio: [SpokenClip] = []
    var scheduled: [SpokenClip] = []
    var buffersInFlight: Int { scheduled.count }
    var scheduledDuration = 0.0
    var generatedDuration = 0.0
    var complete = false
    var paceChosen = false
    var expectedDuration: Double {
        complete ? generatedDuration : max(generatedDuration, line.estimatedDuration)
    }

    init(_ line: SpokenLine) { self.line = line }

    func canPlay(at rate: Double) -> Bool {
        !audio.isEmpty && (complete || audio.reduce(0.0) { $0 + $1.duration } >= rate)
    }
}

private enum SpokenPlaybackIssue {
    case synthesis(String)
    case output(String)

    var message: String {
        switch self {
        case .synthesis(let message), .output(let message): return message
        }
    }
}

enum SpokenPace {
    static func rate(base: Double, automatic: Bool, waiting: Double, previous: Double, elapsed: Double = 0.5) -> Double {
        let base = min(max(base, 0.75), 1.35)
        guard automatic else { return base }
        let extra = min(0.22, max(0, (waiting - 2.0) * 0.0275))
        let target = base * (1 + extra)
        let step = min(max(elapsed, 0), 1)
        return min(base * 1.22, max(base, min(previous + 0.16 * step, max(previous - 0.12 * step, target))))
    }
}

@MainActor
final class SpokenReadingState: ObservableObject {
    struct Position: Equatable {
        let id: UUID
        let range: NSRange?
    }
    @Published private(set) var position: Position?
    var id: UUID? { position?.id }
    var range: NSRange? { position?.range }

    func show(_ id: UUID?, range: NSRange? = nil) {
        let next = id.map { Position(id: $0, range: range) }
        guard position != next else { return }
        position = next
    }
}

@MainActor
final class SpokenPlayback: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var settings: SpokenSettings
    @Published private(set) var outputs: [SpokenOutput] = []
    let reading = SpokenReadingState()
    @Published private(set) var status = ""
    @Published private(set) var lag = 0
    @Published private(set) var canSkip = false
    @Published private(set) var canRetry = false
    @Published private(set) var previewing = false
    let downloads = SpokenModelDownloads()
    var diagnostics: Diagnostics?

    private var listener: SpokenOutputListener?
    private var ticker: Task<Void, Never>?
    private var worker: (any SpokenSynthesizing)?
    private var workerEngine: SpokenEngine?
    private var synthesis: Task<Void, Never>?
    private var workID: UUID?
    private var player: (any SpokenPlaying)?
    private var route: SpokenOutput?
    private var automaticOutputUID: String?
    private var prepared: SpokenUtterance?
    private var playing: SpokenUtterance?
    private var lines: [SpokenLine] = []
    private var rate = 1.0
    private var issue: SpokenPlaybackIssue?
    private var failedLine: SpokenLine?
    private let makeWorker: (SpokenEngine, Diagnostics?) -> any SpokenSynthesizing
    private let makePlayer: @MainActor (SpokenOutput, Int) throws -> any SpokenPlaying
    private let availableOutputs: () -> [SpokenOutput]
    private let installed: (SpokenEngine) -> Bool
    private let monitorsOutputs: Bool

    init(settings: SpokenSettings = .load(), makeWorker: @escaping (SpokenEngine, Diagnostics?) -> any SpokenSynthesizing = {
        SpokenSynthesis(engine: $0, diagnostics: $1)
    }, makePlayer: @escaping @MainActor (SpokenOutput, Int) throws -> any SpokenPlaying = {
        try SpokenAudioPlayer(output: $0, sampleRate: $1)
    }, availableOutputs: @escaping () -> [SpokenOutput] = { SpokenOutput.available() },
         installed: @escaping (SpokenEngine) -> Bool = { SpokenModelFiles.installed($0) }, monitorsOutputs: Bool = true) {
        self.settings = settings
        self.makeWorker = makeWorker
        self.makePlayer = makePlayer
        self.availableOutputs = availableOutputs
        self.installed = installed
        self.monitorsOutputs = monitorsOutputs
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        previewing = false
        clear()
        enabled = value
        if value { activate() }
        else { deactivate() }
    }

    func update(_ value: SpokenSettings) {
        let changedVoice = settings.engine != value.engine || settings.voices != value.voices
        let changedRoute = settings.outputUID != value.outputUID
        let changedPace = settings.rate != value.rate || settings.automaticRate != value.automaticRate
        settings = value
        settings.save()
        player?.setVolume(settings.volume)
        if previewing && (changedVoice || changedRoute) { stopPreview(); return }
        if changedVoice {
            requeuePrepared()
            if let playing, !playing.complete {
                lines.insert(playing.line, at: 0)
                stopPlaying()
            }
            cancelSynthesis()
            issue = nil
            failedLine = nil
        }
        if changedRoute { issue = nil; automaticOutputUID = nil }
        if changedPace {
            rate = settings.rate
            player?.setSpeed(rate)
        }
        refreshOutputs()
    }

    func preview(language: MeetingLanguage) {
        guard !previewing else { stopPreview(); return }
        refreshOutputs()
        guard route != nil else { status = "连接并选择耳机后可以试听。"; return }
        guard settings.engine.supportedSystem, settings.engine.supports(language),
              installed(settings.engine.model(for: language)) else { status = "请先下载此语言的语音包。"; return }
        clear()
        previewing = true
        let text: String
        switch language.speechCode {
        case "zh": text = "这节课我们用 difference-in-differences 估计政策效应，再看看百分之九十五置信区间。"
        case "en": text = "Today we'll use difference-in-differences to estimate the policy effect and check the ninety-five percent confidence interval."
        default: text = Self.previewText[language.speechCode] ?? "Welcome to TingQiao."
        }
        lines = [SpokenLine(id: UUID(), text: text, language: language, availableAt: Date())]
        activate()
        drive()
    }

    private static let previewText = [
        "ko": "오늘은 두 집단의 변화 차이를 비교해 정책 효과를 추정합니다.",
        "ja": "今日は二つのグループの変化を比較して、政策の効果を調べます。",
        "fr": "Aujourd’hui, nous allons estimer l’effet de cette politique.",
        "de": "Heute schätzen wir die Auswirkungen dieser Maßnahme.",
        "it": "Oggi stimiamo l’effetto di questa politica.",
        "es": "Hoy estimaremos el efecto de esta política.",
        "pt": "Hoje vamos estimar o efeito dessa política.",
        "ru": "Сегодня мы оценим эффект этой политики."
    ]

    func offer(id: UUID, text: String, language: MeetingLanguage) {
        guard enabled, !previewing, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard settings.engine.supports(language) else { status = "当前播报模型不支持\(language.title)。"; return }
        lines.append(SpokenLine(id: id, text: text, language: language, availableAt: Date()))
        drive()
    }

    func refreshOutputs() {
        let choices = availableOutputs()
        if choices != outputs { outputs = choices }
        let selection: SpokenOutput?
        if !settings.outputUID.isEmpty {
            selection = choices.first { $0.uid == settings.outputUID }
        } else if let automaticOutputUID {
            selection = choices.first { $0.uid == automaticOutputUID }
        } else {
            selection = choices.first { $0.id == SpokenOutput.defaultDevice && $0.automaticEligible }
            if enabled || previewing { automaticOutputUID = selection?.uid }
        }
        if route != selection {
            requeuePrepared()
            if let playing {
                lines.insert(playing.line, at: 0)
            }
            stopPlaying()
            if synthesis != nil || selection == nil { cancelSynthesis() }
            route = selection
            if case .output = issue { issue = nil }
        }
        listener?.watch(selection?.id)
        drive()
    }

    func retry() {
        issue = nil
        if let failedLine {
            lines.insert(failedLine, at: 0)
            self.failedLine = nil
        }
        drive()
    }

    func jumpToLatest() {
        guard canSkip, let line = lines.last ?? prepared?.line else { return }
        clear()
        lines = [line]
        drive()
    }

    func remove(_ ids: Set<UUID>) {
        lines.removeAll { ids.contains($0.id) }
        if let failedLine, ids.contains(failedLine.id) { self.failedLine = nil }
        if let prepared, ids.contains(prepared.line.id) {
            if workID == prepared.ticket { cancelSynthesis() }
            self.prepared = nil
        }
        if let playing, ids.contains(playing.line.id) {
            if workID == playing.ticket { cancelSynthesis() }
            stopPlaying()
        }
        drive()
    }

    func clear() {
        stopPlaying()
        prepared = nil
        lines.removeAll()
        cancelSynthesis()
        issue = nil
        failedLine = nil
        lag = 0
        canSkip = false
        canRetry = false
        rate = settings.rate
    }

    func endMeeting() {
        if previewing { stopPreview() }
        else { clear(); drive() }
    }

    func shutdown() {
        previewing = false
        enabled = false
        clear()
        deactivate()
        downloads.cancel()
    }

    private func activate() {
        if monitorsOutputs && listener == nil {
            listener = SpokenOutputListener { [weak self] in
                Task { @MainActor in self?.refreshOutputs() }
            }
        }
        if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    self.refreshOutputs()
                }
            }
        }
        refreshOutputs()
    }

    private func deactivate() {
        automaticOutputUID = nil
        listener = nil
        ticker?.cancel()
        ticker = nil
        status = ""
    }

    private func stopPreview() {
        previewing = false
        clear()
        if enabled { drive() } else { deactivate() }
    }

    private func stopPlaying() {
        playing = nil
        reading.show(nil)
        player?.stop()
        player = nil
    }

    private func requeuePrepared() {
        guard let prepared else { return }
        lines.insert(prepared.line, at: 0)
        self.prepared = nil
    }

    private func cancelSynthesis() {
        workID = nil
        synthesis?.cancel()
        synthesis = nil
        worker?.stop()
        worker = nil
        workerEngine = nil
    }

    private func drive() {
        guard enabled || previewing else { return }
        let waiting = lines.count + (prepared == nil ? 0 : 1)
        let skip = !previewing && waiting + (playing == nil ? 0 : 1) > 1
        if canSkip != skip { canSkip = skip }
        let oldest = waiting > 0 ? playing?.line.availableAt ?? prepared?.line.availableAt ?? lines.first?.availableAt : nil
        let seconds = oldest.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
        if lag != seconds { lag = seconds }
        let retry = issue != nil || failedLine != nil
        if canRetry != retry { canRetry = retry }

        if playing == nil && prepared == nil && synthesis == nil {
            guard settings.engine.supportedSystem else { setStatus("此模型需要 \(settings.engine.minimumSystem)"); return }
            if let next = lines.first, !installed(settings.engine.model(for: next.language)) {
                setStatus("请先下载\(next.language.title)语音包"); return
            }
        }
        guard let route else { setStatus("等待耳机连接"); return }
        if let issue { setStatus(issue.message); return }
        if playing == nil, let prepared, prepared.canPlay(at: rate) {
            choosePace(prepared)
            self.prepared = nil
            playing = prepared
            if !playAudio(prepared, on: route) { return }
        }
        if prepared == nil, synthesis == nil, let next = lines.first {
            guard settings.engine.supportedSystem && installed(settings.engine.model(for: next.language)) else { return }
            guard settings.engine.supports(next.language) else {
                let message = "当前播报模型不支持\(next.language.title)。"
                issue = .synthesis(message)
                canRetry = true
                setStatus(message)
                return
            }
            prepare(next)
        }
        if playing?.buffersInFlight ?? 0 > 0 {
            setStatus(String(format: "播报中 · %.2f×", rate))
        } else if synthesis != nil {
            setStatus("正在合成语音")
        } else {
            setStatus(failedLine == nil ? "等待下一段译文" : "一段播报未完成，可重试；后续译文继续播报")
        }
    }

    private func choosePace(_ utterance: SpokenUtterance) {
        guard !utterance.paceChosen else { return }
        utterance.paceChosen = true
        let queued = lines.reduce(0.0) { $0 + $1.estimatedDuration }
        let oldestWaiting = lines.first?.availableAt
        let wait = oldestWaiting.map { Date().timeIntervalSince($0) } ?? 0
        let excess = max(0, utterance.generatedDuration - utterance.line.estimatedDuration)
        let pressure = max(queued, wait, excess)
        let speed = SpokenPace.rate(base: settings.rate, automatic: settings.automaticRate && !previewing,
                                    waiting: pressure, previous: rate, elapsed: 1)
        if speed != rate {
            rate = speed
            player?.setSpeed(speed)
            diagnostics?.record(.spokenRate, id: utterance.line.id, value: Int(speed * 1000))
        }
    }

    @discardableResult
    private func playAudio(_ utterance: SpokenUtterance, on route: SpokenOutput) -> Bool {
        while let clip = utterance.audio.first {
            guard schedule(clip, for: utterance, on: route) else { return false }
            utterance.audio.removeFirst()
        }
        return true
    }

    private func schedule(_ clip: SpokenClip, for utterance: SpokenUtterance, on route: SpokenOutput) -> Bool {
        let starting = utterance.buffersInFlight == 0
        let ticket = utterance.ticket
        let duration = clip.duration
        let completion: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.playedBuffer(ticket: ticket, duration: duration) }
        }
        do {
            if starting, player?.matches(route, sampleRate: clip.sampleRate) != true {
                player?.stop()
                player = try makePlayer(route, clip.sampleRate)
            }
            guard let player else { throw BridgeError("无法打开耳机输出。") }
            player.setVolume(settings.volume)
            if starting { try player.play(clip, speed: rate, completion: completion) }
            else {
                player.setSpeed(rate)
                try player.enqueue(clip, completion: completion)
            }
            if starting { diagnostics?.record(.spokenPlay, id: utterance.line.id, value: Int(rate * 1000)) }
            utterance.scheduled.append(clip)
            if starting, !previewing { reading.show(utterance.line.id, range: clip.textRange) }
            utterance.scheduledDuration += duration
            return true
        } catch {
            fail(utterance, issue: .output(error.localizedDescription))
            return false
        }
    }

    private func prepare(_ line: SpokenLine) {
        lines.removeFirst()
        let utterance = SpokenUtterance(line)
        prepared = utterance
        let ticket = utterance.ticket
        workID = ticket
        let engine = settings.engine.model(for: line.language)
        if workerEngine != engine { worker?.stop(); worker = nil }
        let activeWorker = worker ?? makeWorker(engine, diagnostics)
        worker = activeWorker
        workerEngine = engine
        let voice = settings.voice(for: line.language)
        diagnostics?.record(.spokenStart, id: line.id)
        synthesis = Task { [weak self] in
            do {
                try Task.checkCancellation()
                for try await var chunk in activeWorker.stream(line.text, voice: voice, language: line.language, id: line.id) {
                    guard let self, self.workID == ticket else { return }
                    if let range = chunk.textRange {
                        chunk.textRange = NSRange(location: range.location + line.textOffset, length: range.length)
                    }
                    utterance.sampleRate = chunk.sampleRate
                    utterance.audio.append(chunk)
                    utterance.generatedDuration += chunk.duration
                    if self.playing === utterance, let route = self.route,
                       utterance.buffersInFlight > 0 || utterance.canPlay(at: self.rate) {
                        guard self.playAudio(utterance, on: route) else { return }
                    }
                    self.drive()
                }
                try Task.checkCancellation()
                guard let self, self.workID == ticket else { return }
                self.workID = nil
                self.synthesis = nil
                utterance.complete = true
                self.diagnostics?.record(.spokenReady, id: line.id, value: Int(utterance.generatedDuration * 1000))
                if self.playing === utterance, let route = self.route {
                    if !utterance.audio.isEmpty {
                        guard self.playAudio(utterance, on: route) else { return }
                    } else if utterance.buffersInFlight == 0 {
                        self.finishPlaying()
                        return
                    }
                }
                self.drive()
            } catch {
                guard let self, self.workID == ticket else { return }
                self.fail(utterance, issue: .synthesis(error.localizedDescription),
                          remainingText: (error as? SpokenGenerationError)?.remainingText ?? line.text)
            }
        }
    }

    private func fail(_ utterance: SpokenUtterance, issue: SpokenPlaybackIssue, remainingText: String? = nil) {
        let code: Int
        switch issue { case .synthesis: code = 0; case .output: code = 1 }
        diagnostics?.record(.spokenFailure, id: utterance.line.id, code: code)
        if workID == utterance.ticket { cancelSynthesis() }
        if case .synthesis = issue, !previewing {
            if let remainingText, !remainingText.isEmpty { failedLine = utterance.line.remaining(remainingText) }
            utterance.complete = true
            if playing === utterance, let route {
                if !utterance.audio.isEmpty {
                    guard playAudio(utterance, on: route) else { return }
                } else if utterance.buffersInFlight == 0 {
                    finishPlaying()
                    return
                }
            } else if prepared === utterance, utterance.audio.isEmpty { prepared = nil }
            drive()
            return
        }
        if prepared === utterance { prepared = nil }
        if playing === utterance { stopPlaying() }
        lines.insert(utterance.line, at: 0)
        self.issue = issue
        drive()
    }

    private func playedBuffer(ticket: UUID, duration: Double) {
        guard let playing, playing.ticket == ticket else { return }
        guard !playing.scheduled.isEmpty else { return }
        playing.scheduled.removeFirst()
        playing.scheduledDuration = max(0, playing.scheduledDuration - duration)
        if playing.buffersInFlight == 0 {
            if playing.complete { finishPlaying(); return }
            player?.pause()
        }
        if !previewing { reading.show(playing.line.id, range: playing.scheduled.first?.textRange) }
        drive()
    }

    private func finishPlaying() {
        if let playing { diagnostics?.record(.spokenEnd, id: playing.line.id) }
        playing = nil
        reading.show(nil)
        if previewing { stopPreview(); return }
        player?.finishLine()
        drive()
    }

    private func setStatus(_ value: String) { if status != value { status = value } }
}
