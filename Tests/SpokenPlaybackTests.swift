import Foundation

@main
struct SpokenPlaybackTests {
    @MainActor
    static func main() async throws {
        let playback = SpokenPlayback()
        playback.offer(id: UUID(), text: "这句不应播报", language: .simplifiedChinese)
        precondition(!playback.enabled && playback.reading.id == nil && playback.status.isEmpty)
        precondition(!SpokenEngine.allCases.contains(.kokoro) && SpokenSettings().engine == .melo)
        precondition(SpokenEngine.meloKO.supports(.korean) && !SpokenEngine.meloKO.supports(.english))
        precondition(SpokenSettings().rate == 1.1)
        let oldSettings = Data(#"{"engine":"meloKO","voices":[],"rate":1.25,"automaticRate":false,"outputUID":"saved-earphones"}"#.utf8)
        let migrated = try JSONDecoder().decode(SpokenSettings.self, from: oldSettings)
        precondition(migrated.engine == .melo && migrated.rate == 1.25 && migrated.volume == 1
                     && !migrated.automaticRate && migrated.outputUID == "saved-earphones")
        precondition(!SpokenEngine.allCases.contains(.meloKO) && SpokenEngine.melo.components == [.melo, .meloKO])
        precondition(SpokenEngine.melo.model(for: .korean) == .meloKO && SpokenEngine.melo.model(for: .english) == .melo)

        let normal = SpokenPace.rate(base: 1, automatic: true, waiting: 0, previous: 1)
        let catchUp = SpokenPace.rate(base: 1, automatic: true, waiting: 6, previous: 1)
        let cap = SpokenPace.rate(base: 1, automatic: true, waiting: 90, previous: 1.2)
        let recover = SpokenPace.rate(base: 1, automatic: true, waiting: 0, previous: cap)
        let manual = SpokenPace.rate(base: 1.1, automatic: false, waiting: 90, previous: cap)
        precondition(normal == 1 && catchUp > 1 && catchUp <= 1.08 && cap <= 1.22)
        precondition(recover < cap && recover > 1 && manual == 1.1)
        var ongoing = 1.35
        for _ in 0..<4 {
            ongoing = SpokenPace.rate(base: 1.35, automatic: true, waiting: 12, previous: ongoing, elapsed: 0.5)
        }
        precondition(ongoing > 1.6 && ongoing <= 1.35 * 1.22)
        precondition(SpokenPace.rate(base: 1.35, automatic: true, waiting: 0, previous: ongoing, elapsed: 0.5) < ongoing)
        verifyPauseTrimming()
        let source = String(repeating: "统计学课程，", count: 70) + "请核对置信区间。"
        let parts = SpokenSynthesis.parts(source)
        precondition(parts.joined() == source && parts.allSatisfy { $0.count <= 180 })
        let shortParts = SpokenSynthesis.parts(source, limit: 60)
        precondition(shortParts.joined() == source && shortParts.allSatisfy { $0.count <= 60 })
        let meloParts = SpokenSynthesis.meloParts(source)
        precondition(meloParts.joined() == source && meloParts[0].count <= 32 && meloParts.dropFirst().allSatisfy { $0.count <= 64 })
        let english = "First compare the two groups. " + String(repeating: "Then check the confidence interval. ", count: 10)
        precondition(SpokenSynthesis.meloParts(english).joined() == english)
        for melo in [false, true] {
            let text = "繁體🙂第一句！第二句……真的嗎？！Third 3.14 example. 最后一句。 \n"
            let pieces = SpokenSynthesis.speechParts(text, melo: melo)
            precondition(pieces.joined() == text && pieces[0] == "繁體🙂第一句！")
            precondition(pieces.allSatisfy { !$0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)).isEmpty })
        }
        precondition(SpokenTempo.correction(text: "今天我们先讨论研究方法。", duration: 3) == 1)
        precondition(SpokenTempo.correction(text: "今天我们先讨论研究方法。", duration: 15) == 1.8)
        precondition(SpokenTempo.expectedDuration("Compare the treatment and control groups.") > 2)
        var qwen = SpokenSettings()
        qwen.engine = .qwen
        qwen.voices[.qwen] = "ryan"
        precondition(qwen.voice(for: .simplifiedChinese) == "serena" && qwen.voice(for: .english) == "ryan")
        qwen.voices[.qwen] = "vivian"
        precondition(qwen.voice(for: .traditionalChinese) == "vivian")
        precondition(SpokenSynthesis.mandarinSpeechText("嗯……用 DID！为什么？！检查 n! 和 1…5。")
                     == "嗯，用 DID。为什么？检查 n! 和 1…5。")
        try await verifyCalmRequests()
        try await verifyIncompleteRecovery()
        try await verifyQueueRecovery()
        try await verifyPlaybackHighlightAndVolume()
        print("PASS: 播报默认关闭、按积压平滑调速、长文本切分保留译文")

        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--tempo" {
            try verifyMechanicalTempo()
            return
        }
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--melo" {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-korean-install-\(UUID())")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let input = temp.appendingPathComponent("download.onnx")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent("model.onnx"), to: input)
            try SpokenModelFiles.install(input, engine: .meloKO, root: temp,
                                         koreanFrontend: Bundle.main.url(forResource: "melo-korean", withExtension: "json")
                                            ?? URL(fileURLWithPath: "Resources/melo-korean.json"))
            precondition(SpokenModelFiles.installed(.meloKO, root: temp))
            for engine in [SpokenEngine.melo, .meloKO] {
                let synth = SpokenSynthesis(engine: engine, executable: URL(fileURLWithPath: CommandLine.arguments[2]),
                    directory: engine == .meloKO ? SpokenModelFiles.directory(.meloKO, root: temp) : nil)
                defer { synth.stop() }
                let language: MeetingLanguage = engine == .meloKO ? .korean : .simplifiedChinese
                let text = engine == .meloKO ? "안녕하세요. 오늘은 통계 분석을 공부하겠습니다. 두 집단의 변화를 비교해서 정책 효과를 추정합니다."
                    : "今天我们先核对研究问题，再讨论数据来源和分析方法。随后比较实验组与对照组，最后讨论置信区间和平行趋势。"
                let started = ProcessInfo.processInfo.systemUptime
                var first = 0.0, clips = 0, duration = 0.0
                for try await clip in synth.stream(text, voice: "0", language: language) {
                    if clips == 0 { first = ProcessInfo.processInfo.systemUptime - started }
                    clips += 1; duration += clip.duration
                }
                precondition(clips > 1 && duration > 5)
                print(String(format: "PASS %@ 短段 %d 首段 %.2fs 总合成 %.2fs 音频 %.2fs", engine.rawValue, clips,
                             first, ProcessInfo.processInfo.systemUptime - started, duration))
            }
            return
        }

        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--regression" {
            try await verifyRegression(executable: URL(fileURLWithPath: CommandLine.arguments[2]),
                                       reported: URL(fileURLWithPath: CommandLine.arguments[3]))
            return
        }

        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--qwen-stream" {
            let executable = URL(fileURLWithPath: CommandLine.arguments[2])
            try await verifyQwenStream(executable: executable)
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--qwen17-stream" {
            let synth = SpokenSynthesis(engine: .qwen17, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
            defer { synth.stop() }
            let cases = ["今天我将为大家讲解统计分析的基本原理。首先，我们要区分实验组和对照组。",
                         "其次，在实施政策之前，要先确认相关趋势。第三，需要计算出分析结果的置信区间，同时也要确认样本量是否足够。",
                         "现在我们来看下一个示例。对于新的材料，同样可以使用这种方法。最后，我将对本研究存在的局限性及研究结果做个小结。"]
            for (i, text) in cases.enumerated() {
                let started = ProcessInfo.processInfo.systemUptime
                let clip = try await synth.synthesize(text, voice: "vivian", language: .simplifiedChinese)
                precondition(clip.duration > 2 && clip.duration < 40)
                print(String(format: "PASS: 1.7B 第 %d 段连续合成 %.2f 秒，音频 %.2f 秒", i + 1,
                             ProcessInfo.processInfo.systemUptime - started, clip.duration))
            }
            return
        }
        guard CommandLine.arguments.count == 3 else { return }
        let assets = URL(fileURLWithPath: CommandLine.arguments[1])
        let binaries = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-speech-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for engine in SpokenEngine.allCases {
            let filename = engine.isQwen ? "\(engine.rawValue).gguf" : engine == .meloKO ? "meloKO.onnx" : "\(engine.rawValue).tar.bz2"
            let asset = assets.appendingPathComponent(filename)
            let input = root.appendingPathComponent(filename)
            if engine.isQwen || engine == .meloKO { try FileManager.default.copyItem(at: asset, to: input) }
            try SpokenModelFiles.install(engine.isQwen || engine == .meloKO ? input : asset, engine: engine, root: root,
                                         koreanFrontend: URL(fileURLWithPath: "Resources/melo-korean.json"))
            precondition(SpokenModelFiles.installed(engine, root: root))
            let synth = SpokenSynthesis(engine: engine,
                executable: binaries.appendingPathComponent(engine.isQwen ? "TingQiaoQwenTTS" : "TingQiaoSherpaTTS"),
                directory: SpokenModelFiles.directory(engine, root: root))
            var options = SpokenSettings()
            options.engine = engine
            let cases: [(String, MeetingLanguage)] = engine == .meloKO ? [("오늘은 통계 분석을 공부하겠습니다.", .korean)] :
                [("我们用 difference-in-differences 估计政策效应。", .simplifiedChinese), ("Check the confidence interval.", .english)]
            for (text, language) in cases {
                let audio = try await synth.synthesize(text, voice: options.voice(for: language), language: language)
                precondition(audio.duration > 0.5 && audio.duration < 30 && audio.pcm.contains { $0 != 0 })
            }
            synth.stop()
            print("PASS: \(engine.title) 文件安装、校验、原生进程与连续中英播报")
        }
    }

    private static func verifyCalmRequests() async throws {
        let text = "为什么要检验平行趋势？"
        for engine in [SpokenEngine.qwen, .qwen17] {
            for language in [MeetingLanguage.simplifiedChinese, .traditionalChinese, .english, .korean] {
                var settings = SpokenSettings()
                settings.engine = engine
                settings.voices[engine] = "vivian"
                let restored = try JSONDecoder().decode(SpokenSettings.self, from: JSONEncoder().encode(settings))
                precondition(restored == settings && restored.voice(for: language) == "vivian")
                let request = SpokenSynthesis.request(engine: engine, id: "test", text: text, voice: "vivian", language: language)
                precondition(request["text"] as? String == text && request["language"] as? String == language.speechCode)
                precondition(request["seed"] as? Int == 42 && request["temperature"] as? Double == (engine == .qwen17 ? 0.7 : 0.4))
                precondition(request["code_predictor_temperature"] as? Double == (engine == .qwen17 ? 0.7 : 0.5))
                precondition((request["instructions"] != nil) == (engine == .qwen17))
            }
        }
        let sherpa = SpokenSynthesis.request(engine: .melo, id: "melo", text: text, voice: "0", language: .simplifiedChinese)
        precondition(Set(sherpa.keys) == ["type", "id", "text", "voice"])
        precondition(SpokenModelFiles.directory(.qwen) != SpokenModelFiles.directory(.qwen17))
        precondition(SpokenEngine.qwen17.supports(.korean) && SpokenEngine.melo.supports(.korean))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-calm-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker.py")
        let script = """
        #!/usr/bin/python3
        import sys, json, base64
        assert sys.argv[1] == 'worker' and sys.argv[2].endswith('model.gguf')
        print(json.dumps({'type':'ready','model':{'sample_rate':24000}}), flush=True)
        for line in sys.stdin:
            r=json.loads(line)
            assert r['instructions'] and r['temperature']==0.7 and r['code_predictor_temperature']==0.7
            assert r['voice']=='vivian' and r['text'] in ('会议结果。', 'The meeting result.')
            assert ('普通话' in r['instructions']) == (r['language']=='zh')
            pcm=base64.b64encode(bytes([16,16])*12000).decode()
            for n in range(2):
                print(json.dumps({'type':'chunk','id':r['id'],'seq':n,'pcm':pcm}), flush=True)
            print(json.dumps({'type':'end','id':r['id'],'samples':24000,'stop':'complete'}), flush=True)
        """
        try script.write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let synth = SpokenSynthesis(engine: .qwen17, executable: worker, directory: root)
        defer { synth.stop() }
        for (text, language) in [("会议结果。", MeetingLanguage.simplifiedChinese), ("The meeting result.", .english)] {
            var chunks = 0
            var duration = 0.0
            for try await clip in synth.stream(text, voice: "vivian", language: language) {
                chunks += 1
                duration += clip.duration
                precondition(clip.textRange == NSRange(location: 0, length: text.utf16.count))
            }
            precondition(chunks == 1 && duration == 1)
        }
        let traditional = "會議結果……！會議結果！"
        var ranges: [NSRange] = []
        for try await clip in synth.stream(traditional, voice: "vivian", language: .traditionalChinese) {
            ranges.append(clip.textRange!)
        }
        precondition(ranges == [NSRange(location: 0, length: 7), NSRange(location: 7, length: 5)])
        print("PASS: 1.7B 中英语气指令、独立模型目录、设置保存与连续流式协议；其他引擎参数保持不变")
    }

    private static func verifyIncompleteRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("worker.py")
        let script = """
        #!/usr/bin/python3
        import json,sys,base64
        print(json.dumps({'type':'ready','model':{'sample_rate':24000}}),flush=True)
        for line in sys.stdin:
            r=json.loads(line)
            retry=r['seed']==43
            fail='永久失败' in r['text'] or ('需要恢复' in r['text'] and not retry)
            pcm=base64.b64encode(bytes([32 if fail else 16,16])*24000).decode()
            print(json.dumps({'type':'chunk','id':r['id'],'seq':0,'pcm':pcm}),flush=True)
            print(json.dumps({'type':'end','id':r['id'],'samples':24000,'stop':'max_seconds' if fail else 'complete'}),flush=True)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let synth = SpokenSynthesis(engine: .qwen17, executable: executable, directory: root)
        defer { synth.stop() }
        let audio = try await synth.synthesize("需要恢复。", voice: "vivian", language: .simplifiedChinese)
        precondition(audio.duration == 1 && audio.pcm.allSatisfy { $0 == 16 })
        var clips = 0
        let prefix = String(repeating: "前", count: 47) + "。"
        do {
            for try await clip in synth.stream(prefix + "永久失败。", voice: "vivian", language: .simplifiedChinese) {
                clips += 1
                precondition(clip.pcm.allSatisfy { $0 == 16 })
            }
            preconditionFailure("Incomplete audio must not be published")
        } catch let error as SpokenGenerationError {
            precondition(clips == 1 && error.remainingText == "永久失败。")
        }
        print("PASS: 截断音频不播放、自动重试一次、完整前段只提交一次、失败保存未完成尾段")
    }

    @MainActor
    private static func verifyQueueRecovery() async throws {
        final class Worker: SpokenSynthesizing, @unchecked Sendable {
            var requested: [String] = []
            func stop() {}
            func stream(_ text: String, voice: String, language: MeetingLanguage, id: UUID?) -> AsyncThrowingStream<SpokenClip, Error> {
                requested.append(text)
                return AsyncThrowingStream { continuation in
                    let clip = SpokenClip(pcm: Data(repeating: 16, count: 48_000), sampleRate: 24_000)
                    continuation.yield(clip)
                    if text == "第一段和失败尾段" {
                        continuation.finish(throwing: SpokenGenerationError(remainingText: "失败尾段", cause: SpokenSynthesisFailure.incomplete("max_seconds")))
                    } else { continuation.yield(clip); continuation.finish() }
                }
            }
        }
        @MainActor final class Player: SpokenPlaying {
            var played = 0
            var speeds: [Double] = []
            func matches(_ output: SpokenOutput, sampleRate: Int) -> Bool { true }
            func play(_ clip: SpokenClip, speed: Double, completion: @escaping @Sendable () -> Void) throws {
                played += 1; speeds.append(speed); try enqueue(clip, completion: completion)
            }
            func enqueue(_ clip: SpokenClip, completion: @escaping @Sendable () -> Void) throws {
                Task { try? await Task.sleep(for: .milliseconds(10)); completion() }
            }
            func setSpeed(_ speed: Double) { speeds.append(speed) }
            func setVolume(_ volume: Double) {}
            func pause() {}
            func finishLine() {}
            func stop() {}
        }
        let worker = Worker(), player = Player()
        var settings = SpokenSettings()
        settings.engine = .qwen17
        settings.outputUID = "fake"
        settings.rate = 1.35
        settings.automaticRate = false
        let playback = SpokenPlayback(settings: settings, makeWorker: { _, _ in worker }, makePlayer: { _, _ in player },
                                      availableOutputs: { [SpokenOutput(id: 1, uid: "fake", name: "fake", automaticEligible: true)] },
                                      installed: { _ in true }, monitorsOutputs: false)
        playback.setEnabled(true)
        defer { playback.shutdown() }
        playback.offer(id: UUID(), text: "第一段和失败尾段", language: .simplifiedChinese)
        playback.offer(id: UUID(), text: "后续完整译文", language: .simplifiedChinese)
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            if playback.reading.id == nil && player.played == 2 { break }
        }
        precondition(worker.requested == ["第一段和失败尾段", "后续完整译文"] && player.played == 2)
        precondition(playback.canRetry && playback.status.contains("可重试") && player.speeds.allSatisfy { $0 == 1.35 })
        playback.retry()
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            if playback.reading.id == nil && player.played == 3 { break }
        }
        precondition(worker.requested.last == "失败尾段" && player.played == 3 && !playback.canRetry)
        print("PASS: 生成失败后后续译文继续、手动重试只读尾段、每段应用设定倍速")
    }

    @MainActor
    private static func verifyPlaybackHighlightAndVolume() async throws {
        final class Worker: SpokenSynthesizing, @unchecked Sendable {
            func stop() {}
            func stream(_ text: String, voice: String, language: MeetingLanguage, id: UUID?) -> AsyncThrowingStream<SpokenClip, Error> {
                AsyncThrowingStream { continuation in
                    for range in [NSRange(location: 0, length: 4), NSRange(location: 4, length: 4)] {
                        continuation.yield(SpokenClip(pcm: Data(repeating: 16, count: 48_000), sampleRate: 24_000, textRange: range))
                    }
                    continuation.finish()
                }
            }
        }
        @MainActor final class Player: SpokenPlaying {
            var callbacks: [@Sendable () -> Void] = []
            var volume = 1.0
            var starts = 0
            func matches(_ output: SpokenOutput, sampleRate: Int) -> Bool { true }
            func play(_ clip: SpokenClip, speed: Double, completion: @escaping @Sendable () -> Void) throws {
                starts += 1; callbacks.append(completion)
            }
            func enqueue(_ clip: SpokenClip, completion: @escaping @Sendable () -> Void) throws { callbacks.append(completion) }
            func setSpeed(_ speed: Double) {}
            func setVolume(_ volume: Double) { self.volume = volume }
            func pause() {}
            func finishLine() {}
            func stop() {}
            func finish() { callbacks.removeFirst()() }
        }
        let saved = UserDefaults.standard.data(forKey: "TingQiao.spokenSettings")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "TingQiao.spokenSettings") }
            else { UserDefaults.standard.removeObject(forKey: "TingQiao.spokenSettings") }
        }
        let player = Player()
        var engines: [SpokenEngine] = []
        var settings = SpokenSettings()
        settings.outputUID = "test"
        settings.volume = 0.4
        let playback = SpokenPlayback(settings: settings, makeWorker: { engine, _ in engines.append(engine); return Worker() },
            makePlayer: { _, _ in player },
            availableOutputs: { [SpokenOutput(id: 1, uid: "test", name: "test", automaticEligible: true)] },
            installed: { _ in true }, monitorsOutputs: false)
        defer { playback.shutdown() }
        playback.setEnabled(true)
        let first = UUID(), second = UUID()
        playback.offer(id: first, text: "第一小句第二小句", language: .simplifiedChinese)
        playback.offer(id: second, text: "한국어를확인해요", language: .korean)
        for _ in 0..<100 {
            if player.callbacks.count == 2 && engines.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(engines == [.melo, .meloKO] && player.starts == 1)
        precondition(playback.reading.id == first && playback.reading.range == NSRange(location: 0, length: 4))
        precondition(player.volume == 0.4)
        settings.volume = 0.15
        playback.update(settings)
        precondition(player.volume == 0.15 && player.starts == 1 && engines.count == 2)
        player.finish()
        for _ in 0..<100 {
            if playback.reading.range?.location == 4 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(playback.reading.id == first && playback.reading.range == NSRange(location: 4, length: 4))
        player.finish()
        for _ in 0..<100 {
            if playback.reading.id == second { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(playback.reading.id == second && playback.reading.range?.location == 0 && player.volume == 0.15)
        playback.clear()
        player.finish()
        await Task.yield()
        precondition(playback.reading.id == nil && playback.reading.range == nil)
        let line = SpokenLine(id: first, text: "前段🙂后段", language: .simplifiedChinese, availableAt: Date())
        precondition(line.remaining("后段").textOffset == 4)
        print("PASS: 同一Melo选项按中韩路由、实际播放回调切换小句底纹、独立音量即时生效、清空后忽略旧回调")
    }

    private static func verifyPauseTrimming() {
        let sampleRate = 24_000
        let frameBytes = sampleRate / 100 * 2
        let firstWord = Data(repeating: 16, count: frameBytes * 40)
        let secondWord = Data(repeating: 24, count: frameBytes * 50)
        let input = Data(count: frameBytes * 120) + firstWord + Data(count: frameBytes * 90)
            + secondWord + Data(count: frameBytes * 110)
        var filter = SpokenPauseTrimmer(sampleRate: sampleRate)
        var output = Data()
        for offset in stride(from: 0, to: input.count, by: 3_850) {
            output.append(filter.consume(input.subdata(in: offset..<min(offset + 3_850, input.count))))
        }
        output.append(filter.finish())
        let expected = Data(count: frameBytes * 10) + firstWord + Data(count: frameBytes * 28)
            + secondWord + Data(count: frameBytes * 18)
        precondition(output == expected, "Long gaps are shortened without changing voiced samples across chunk boundaries")
    }

    private static func verifyMechanicalTempo() throws {
        let rate = 24_000
        var samples = (0..<(rate * 3)).map { index in
            Int16((sin(Double(index) * 2 * .pi * 440 / Double(rate)) * 9000).rounded())
        }
        let input = SpokenClip(pcm: samples.withUnsafeBytes { Data($0) }, sampleRate: rate)
        for speed in [1.1, 1.5, 1.8] {
            let output = try SpokenTempo.compress(input, rate: speed)
            precondition(abs(output.duration - input.duration / speed) < 0.1)
            let crossings = output.pcm.withUnsafeBytes { raw -> Int in
                var count = 0
                for i in 1..<(raw.count / 2) {
                    if raw.loadUnaligned(fromByteOffset: (i - 1) * 2, as: Int16.self) < 0,
                       raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self) >= 0 { count += 1 }
                }
                return count
            }
            precondition(abs(Double(crossings) / output.duration - 440) < 15)
            print(String(format: "PASS 机械变速 %.2fx 时长 %.3fs，音高约 %.1fHz", speed, output.duration, Double(crossings) / output.duration))
        }
        samples.removeAll()
    }

    private static func verifyQwenStream(executable: URL) async throws {
        let synth = SpokenSynthesis(engine: .qwen, executable: executable)
        defer { synth.stop() }
        let cases: [(String, String, MeetingLanguage)] = [
            ("中英混读", "这节课我们用 difference-in-differences 估计政策效应，再核对百分之九十五的置信区间。", .simplifiedChinese),
            ("英语", "Today we'll compare the treatment and control groups, estimate the policy effect, and check the confidence interval.", .english)
        ]
        var settings = SpokenSettings()
        settings.engine = .qwen
        for (label, text, language) in cases {
            let start = ProcessInfo.processInfo.systemUptime
            var firstPlayable: Double?
            var duration = 0.0
            var count = 0
            for try await chunk in synth.stream(text, voice: settings.voice(for: language), language: language) {
                precondition(chunk.sampleRate == 24_000 && !chunk.pcm.isEmpty)
                duration += chunk.duration
                count += 1
                if firstPlayable == nil, duration >= 0.48 {
                    firstPlayable = ProcessInfo.processInfo.systemUptime - start
                }
            }
            precondition(count >= 1 && duration > 1 && firstPlayable != nil)
            let total = ProcessInfo.processInfo.systemUptime - start
            print(String(format: "PASS: %@ 首次攒够播报缓冲 %.2f 秒，完整生成 %.2f 秒，音频时长 %.2f 秒",
                         label, firstPlayable!, total, duration))
        }

        let longPause = "嗯……接下来这个问题真的很重要！！！我们要先看处理组和对照组。"
        let first = try await synth.synthesize(longPause, voice: "serena", language: .simplifiedChinese)
        let second = try await synth.synthesize(longPause, voice: "serena", language: .simplifiedChinese)
        precondition(first.pcm == second.pcm && first.duration > 3 && first.duration < 12)
        print(String(format: "PASS: 带省略号和感叹号的同一句两次合成一致，音频时长 %.2f 秒", first.duration))

        let question = "这个结果为什么跟上一张表不一样？"
        let uncle = try await synth.synthesize(question, voice: "uncle_fu", language: .simplifiedChinese)
        let repeatedUncle = try await synth.synthesize(question, voice: "uncle_fu", language: .simplifiedChinese)
        let vivian = try await synth.synthesize(question, voice: "vivian", language: .simplifiedChinese)
        precondition(uncle.pcm == repeatedUncle.pcm && (2...5).contains(uncle.duration) && vivian.duration > 1)
        print(String(format: "PASS: Uncle Fu 问句 %.2f 秒，重复生成一致，Vivian 问句 %.2f 秒", uncle.duration, vivian.duration))

        let interrupted = Task {
            for try await _ in synth.stream(cases[0].1, voice: "serena", language: .simplifiedChinese) {
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
        }
        do {
            try await interrupted.value
            preconditionFailure("Expected stream cancellation after the first chunk")
        } catch is CancellationError {
            print("PASS: 生成首段后可取消播报")
        }
    }

    private static func verifyRegression(executable: URL, reported: URL) async throws {
        struct Reported: Decodable { let text: String }
        let failures = try JSONDecoder().decode([Reported].self, from: Data(contentsOf: reported))
        let chinese = [
            "今天我们先核对研究问题，再讨论数据来源和分析方法。",
            "如果实验组在政策实施前已经发生变化，就需要重新检验平行趋势假设。",
            "这节课我们用 difference-in-differences 估计政策效应，再核对百分之九十五的置信区间。",
            "不显著并不等于没有影响，还要考虑样本量、标准误和模型设定。",
            "先看第一张表。然后比较第二张表，最后讨论两者为什么得出了不同的结果。",
            "嗯……接下来这个问题很重要！我们需要先看清楚处理组和对照组。"
        ]
        let other: [(String, String, MeetingLanguage)] = [
            ("Today we will compare the treatment and control groups and discuss the confidence interval.", "ryan", .english),
            ("Please check whether the sample size is sufficient before drawing a conclusion.", "aiden", .english),
            ("오늘은 두 집단의 변화를 비교하고 정책 효과를 추정하겠습니다.", "sohee", .korean),
            ("今日は二つのグループを比較して、政策の効果を調べます。", "ono_anna", .japanese)
        ]
        for engine in [SpokenEngine.qwen17, .qwen] {
            let diagnostics = Diagnostics(root: URL(fileURLWithPath: "build/tests/spoken-regression-diagnostics"))
            let synth = SpokenSynthesis(engine: engine, executable: executable, diagnostics: diagnostics)
            defer { synth.stop() }
            var cases: [(String, String, MeetingLanguage)] = failures.map { ($0.text, "vivian", .simplifiedChinese) }
            for voice in ["vivian", "serena", "uncle_fu"] {
                cases += chinese.map { ($0, voice, .simplifiedChinese) }
            }
            cases += other
            for (index, item) in cases.enumerated() {
                let started = ProcessInfo.processInfo.systemUptime
                let clip = try await synth.synthesize(item.0, voice: item.1, language: item.2)
                precondition(clip.sampleRate == 24000 && clip.duration > 0.5 && clip.duration < 55)
                print(String(format: "PASS: %@ %d/%d %@ 合成 %.2fs 音频 %.2fs", engine.rawValue,
                             index + 1, cases.count, item.1, ProcessInfo.processInfo.systemUptime - started, clip.duration))
                fflush(stdout)
            }
            await diagnostics.finish()
        }
    }
}
