import Foundation
import AVFoundation

enum RecognitionAudio {
    static func croppedInput(_ source: URL, skipping samples: Int) throws -> URL {
        guard samples > 0 else { return source }
        let input = try AVAudioFile(forReading: source)
        guard input.processingFormat.sampleRate == 16000, input.processingFormat.channelCount == 1,
              input.length > AVAudioFramePosition(samples) else { throw BridgeError("这段音频没有可供复核的新内容。", retryable: false) }
        input.framePosition = AVAudioFramePosition(samples)
        let length = input.length - input.framePosition
        guard let pcm = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(length)) else { throw BridgeError("无法准备复核音频。") }
        try input.read(into: pcm)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("tingqiao-review-\(UUID()).wav")
        do {
            var output: AVAudioFile? = try AVAudioFile(forWriting: target, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
                commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
            try output?.write(from: pcm); output = nil
            return target
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
}
