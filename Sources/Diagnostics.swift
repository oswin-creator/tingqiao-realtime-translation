import Foundation
import Darwin

final class Diagnostics: @unchecked Sendable {
    enum Event: String {
        case launch, cleanExit = "clean_exit", unexpectedExit = "unexpected_exit"
        case captureStart = "capture_start", captureReady = "capture_ready", captureStop = "capture_stop"
        case captureFailure = "capture_failure", audioReady = "audio_ready", audioWriteFailure = "audio_write_failure"
        case captureAudio = "capture_audio", spokenStart = "spoken_start", spokenReady = "spoken_ready"
        case spokenPlay = "spoken_play", spokenRate = "spoken_rate", spokenEnd = "spoken_end", spokenFailure = "spoken_failure"
        case spokenPart = "spoken_part", spokenRetry = "spoken_retry"
        case spokenTempo = "spoken_tempo"
        case previewStart = "preview_start", previewResult = "preview_result", previewFailure = "preview_failure"
        case recognitionStart = "recognition_start", recognitionResult = "recognition_result"
        case translationStart = "translation_start", translationResult = "translation_result"
        case saveStart = "save_start", saveEnd = "save_end", saveFailure = "save_failure"
        case jobFailure = "job_failure", phonePublishStart = "phone_publish_start", phonePublishEnd = "phone_publish_end"
        case hang, responsive, sampleSaved = "sample_saved", sampleUnavailable = "sample_unavailable"
        case userMarker = "user_marker"
    }

    private let root: URL
    private let run: URL
    private let queue = DispatchQueue(label: "cn.tingqiao.diagnostics", qos: .utility)
    private let clock = ISO8601DateFormatter()
    private let pid = getpid()
    private let limit = 192 * 1024
    private var log: FileHandle?
    private var bytes = 0
    private var timer: DispatchSourceTimer?
    private var probeSentAt: TimeInterval?
    private var lastTick: TimeInterval?
    private var reportedHang = false
    private var sampleCount = 0

    init(root: URL) {
        self.root = root
        run = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        queue.async { self.start() }
    }

    func record(_ event: Event, id: UUID? = nil, value: Int? = nil, code: Int? = nil) {
        let date = Date()
        queue.async { self.write(event, date: date, id: id, value: value, code: code) }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.timer?.cancel()
                self.timer = nil
                self.write(.cleanExit)
                try? self.log?.close()
                self.log = nil
                try? FileManager.default.removeItem(at: self.run.appendingPathComponent("active"))
                continuation.resume()
            }
        }
    }

    func report() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.readReport()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func start() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try "\(pid)".write(to: run.appendingPathComponent("active"), atomically: true, encoding: .utf8)
            try openLog()
        } catch { return }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "test"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        append("TingQiao \(version) (\(build)) | macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) | pid \(pid)\n",
               to: run.appendingPathComponent("info.txt"))
        write(.launch)
        pruneRuns()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.checkMainThread() }
        self.timer = timer
        timer.resume()
    }

    private var events: URL { run.appendingPathComponent("events.txt") }

    private func openLog() throws {
        let fd = open(events.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        log = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        bytes = 0
    }

    private func write(_ event: Event, date: Date = Date(), id: UUID? = nil, value: Int? = nil, code: Int? = nil) {
        guard let log else { return }
        let data = Data(line(event, date: date, id: id, value: value, code: code).utf8)
        do {
            if bytes + data.count > limit {
                try log.close()
                self.log = nil
                let recent = run.appendingPathComponent("recent.txt")
                if FileManager.default.fileExists(atPath: recent.path) { try FileManager.default.removeItem(at: recent) }
                try FileManager.default.moveItem(at: events, to: recent)
                try openLog()
            }
            try self.log?.write(contentsOf: data)
            bytes += data.count
        } catch {
            try? self.log?.close()
            self.log = nil
        }
    }

    private func line(_ event: Event, date: Date = Date(), id: UUID? = nil, value: Int? = nil, code: Int? = nil) -> String {
        var text = "\(clock.string(from: date)) \(event.rawValue)"
        if let id { text += " id=\(id.uuidString.prefix(8))" }
        if let value { text += " value=\(value)" }
        if let code { text += " code=\(code)" }
        return text + "\n"
    }

    private func append(_ text: String, to url: URL) {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data(text.utf8))
    }

    private func checkMainThread() {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTick = now }
        if let sent = probeSentAt {
            if let lastTick, now - lastTick > 4 {
                probeSentAt = now
            } else if !reportedHang, now - sent >= 3 {
                reportedHang = true
                write(.hang, value: Int((now - sent) * 1000))
                if sampleCount < 3 { sampleMainThread() }
            }
            return
        }

        probeSentAt = now
        DispatchQueue.main.async { [weak self] in
            let received = ProcessInfo.processInfo.systemUptime
            self?.queue.async { [weak self] in
                guard let self, let sent = self.probeSentAt else { return }
                self.probeSentAt = nil
                if self.reportedHang {
                    self.reportedHang = false
                    self.write(.responsive, value: Int(max(0, received - sent) * 1000))
                }
            }
        }
    }

    private func sampleMainThread() {
        sampleCount += 1
        let slot = sampleCount
        let temp = run.appendingPathComponent(".sample-\(slot)")
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(pid), "1", "10", "-file", temp.path]
        sampler.standardOutput = FileHandle.nullDevice
        sampler.standardError = FileHandle.nullDevice
        sampler.terminationHandler = { [weak self] process in
            self?.queue.async { [weak self] in
                defer { try? FileManager.default.removeItem(at: temp) }
                guard let self else { return }
                if process.terminationStatus == 0,
                   self.saveStack(from: temp, in: self.run, slot: slot) {
                    self.write(.sampleSaved, value: slot)
                } else {
                    self.write(.sampleUnavailable, value: slot, code: Int(process.terminationStatus))
                }
            }
        }
        do {
            try sampler.run()
            queue.asyncAfter(deadline: .now() + 8) {
                if sampler.isRunning { sampler.terminate() }
            }
        } catch { write(.sampleUnavailable, value: slot) }
    }

    private func saveStack(from source: URL, in run: URL, slot: Int) -> Bool {
        guard let raw = try? String(contentsOf: source, encoding: .utf8),
              let stack = Self.mainStack(in: raw) else { return false }
        do {
            try stack.write(to: run.appendingPathComponent("hang-\(slot).txt"), atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    static func mainStack(in raw: String) -> String? {
        var frames: [String] = []
        var isMain = false
        for row in raw.split(separator: "\n") {
            let line = row.trimmingCharacters(in: .whitespaces)
            if !isMain {
                isMain = line.contains("com.apple.main-thread") && line.contains("Thread_")
                continue
            }
            guard line.hasPrefix("+") else { break }
            guard let image = line.range(of: " (in "), let end = line[image.upperBound...].firstIndex(of: ")") else { continue }
            let module = line[image.upperBound..<end]
            let symbol = line[..<image.lowerBound]
            guard module.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
                  !symbol.contains("/"), !symbol.contains("@file") else { continue }
            frames.append(String(symbol.prefix(240)) + " (in " + module + ")")
            if frames.count == 150 { break }
        }
        return frames.isEmpty ? nil : frames.joined(separator: "\n") + "\n"
    }

    private struct Run {
        let url: URL
        let date: Date
        let isActive: Bool
    }

    private func runs() throws -> [Run] {
        let fm = FileManager.default
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.lastPathComponent.hasPrefix("run-") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { url in
                let date = (try? url.appendingPathComponent("events.txt").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let active = url.appendingPathComponent("active")
                let pid = (try? String(contentsOf: active, encoding: .utf8)).flatMap(Int32.init)
                let alive = pid.map { $0 > 0 && (kill($0, 0) == 0 || errno == EPERM) } ?? false
                return Run(url: url, date: date, isActive: alive)
            }.sorted { $0.date > $1.date }
    }

    private func pruneRuns() {
        guard let runs = try? runs() else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for (index, run) in runs.enumerated() where !run.isActive {
            if run.date < cutoff || index >= 8 {
                try? FileManager.default.removeItem(at: run.url)
            } else {
                let active = run.url.appendingPathComponent("active")
                if FileManager.default.fileExists(atPath: active.path) {
                    let end = run.url.appendingPathComponent("end.txt")
                    if !FileManager.default.fileExists(atPath: end.path) {
                        append(line(.unexpectedExit), to: end)
                    }
                    try? FileManager.default.removeItem(at: active)
                }
                for slot in 1...3 {
                    let sample = run.url.appendingPathComponent(".sample-\(slot)")
                    if saveStack(from: sample, in: run.url, slot: slot) {
                        try? FileManager.default.removeItem(at: sample)
                    }
                }
            }
        }
    }

    private func readReport() throws -> String {
        var report = "听桥故障记录 · UTC\n"
        report += "value：hang、responsive、save_end 为毫秒；audio_ready 为音频毫秒数；save_start 为记录条数；job_failure 为阶段（0 识别、1 翻译）。\n"
        report += "unexpected_exit 的时间为下次启动时发现的时间。\n"
        report += "capture_audio 的 value 为五秒内收到的音频缓冲数；spoken_play、spoken_rate 的 value 为语速倍数乘 1000；spoken_ready 为生成音频毫秒数；spoken_failure 的 code 为 0（生成）或 1（播放）。\n"
        report += "spoken_part 的 value 为短段音频毫秒数，code 为 0（完整）、2（达到时长上限）、3（其他中断）；spoken_retry 的 value 为重试字数，code 为 2（时长上限）、3（未完成）、4（无效音频）。\n"
        report += "spoken_tempo 的 value 为慢速音频的机械加速倍数乘 1000。\n"
        for run in try runs().prefix(8).reversed() {
            report += "\n"
            for name in ["info.txt", "recent.txt", "events.txt", "end.txt", "hang-1.txt", "hang-2.txt", "hang-3.txt"] {
                let path = run.url.appendingPathComponent(name)
                guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
                if name.hasPrefix("hang-") { report += "\n主线程采样 \(name)\n" }
                report += text
            }
        }
        return report
    }
}
