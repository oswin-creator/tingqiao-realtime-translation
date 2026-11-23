import Foundation

@main struct SpokenOutputTests {
    @MainActor static func main() async throws {
        guard let output = SpokenOutput.available().first(where: { $0.id == SpokenOutput.defaultDevice }) else {
            throw BridgeError("测试需要连接当前系统耳机。")
        }
        let player = try SpokenAudioPlayer(output: output, sampleRate: 24_000)
        defer { player.stop() }
        let clip = SpokenClip(pcm: Data(count: 24_000 * 2 * 4), sampleRate: 24_000)
        var deviceLatency = 0.0
        for (index, speed) in [1.0, 1.0, 1.1, 1.35, 1.6, 1.1].enumerated() {
            let started = ProcessInfo.processInfo.systemUptime
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                do { try player.play(clip, speed: speed) { continuation.resume() } }
                catch { continuation.resume(throwing: error) }
            }
            let duration = ProcessInfo.processInfo.systemUptime - started
            FileHandle.standardError.write(Data(String(format: "speed %.2f duration %.3f expected %.3f\n", speed, duration, 4 / speed).utf8))
            if speed == 1 { deviceLatency = duration - 4 }
            if index > 1 { precondition(abs(duration - deviceLatency - 4 / speed) < 0.35, "播放倍速与实测时长不符") }
            player.finishLine()
            try await Task.sleep(for: .milliseconds(300))
            print(String(format: "PASS: 耳机静音片段 %.2f×，实测 %.2f 秒", speed, duration))
        }
    }
}
