import Foundation
import Darwin
import CryptoKit

// Capture and tests use the same framed interface. Inference never decides
// which PCM samples to retain; it supplies only speech probabilities.
protocol VoiceActivityDetecting: AnyObject {
    func probabilities(for samples: [Float]) throws -> [Float]
    func reset()
}

final class SileroVAD: VoiceActivityDetecting {
    static let modelName = "ggml-silero-v5.1.2.bin"
    static let modelSHA256 = "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
    private typealias Create = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?
    private typealias Destroy = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias Reset = @convention(c) (UnsafeMutableRawPointer) -> Void
    private typealias Process = @convention(c) (UnsafeMutableRawPointer, UnsafePointer<Float>, Int32, UnsafeMutablePointer<Float>) -> Int32
    private let library: UnsafeMutableRawPointer
    private let context: UnsafeMutableRawPointer
    private let destroy: Destroy
    private let resetContext: Reset
    private let process: Process
    private var slowBatches = 0

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Silero 语音检测不可用，已回退到基础音量检测，收音继续。" }
    }

    convenience init() throws {
        guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL else { throw Unavailable() }
        try self.init(libraryURL: executable.deletingLastPathComponent().appendingPathComponent("libTingQiaoVAD.dylib"), modelURL: resources.appendingPathComponent(Self.modelName))
    }

    // Explicit paths are used only by offline tests, never by a network request.
    init(libraryURL: URL, modelURL: URL) throws {
        let data = try Data(contentsOf: modelURL, options: .mappedIfSafe)
        guard data.count == 885098, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == Self.modelSHA256,
              let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else { throw Unavailable() }
        guard let createSymbol = dlsym(library, "tq_vad_create"),
              let destroySymbol = dlsym(library, "tq_vad_destroy"),
              let resetSymbol = dlsym(library, "tq_vad_reset"),
              let processSymbol = dlsym(library, "tq_vad_process") else { dlclose(library); throw Unavailable() }
        let create = unsafeBitCast(createSymbol, to: Create.self)
        guard let context = modelURL.path.withCString({ create($0) }) else { dlclose(library); throw Unavailable() }
        self.library = library; self.context = context
        destroy = unsafeBitCast(destroySymbol, to: Destroy.self)
        resetContext = unsafeBitCast(resetSymbol, to: Reset.self)
        process = unsafeBitCast(processSymbol, to: Process.self)
    }

    deinit { destroy(context); dlclose(library) }
    func reset() { resetContext(context); slowBatches = 0 }
    func probabilities(for samples: [Float]) throws -> [Float] {
        guard !samples.isEmpty, samples.count <= 4096, samples.count % 512 == 0 else { throw Unavailable() }
        var result = [Float](repeating: 0, count: samples.count / 512)
        let started = ProcessInfo.processInfo.systemUptime
        let count = samples.withUnsafeBufferPointer { input in
            result.withUnsafeMutableBufferPointer { output in process(context, input.baseAddress!, Int32(input.count), output.baseAddress!) }
        }
        guard count == result.count, result.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Unavailable() }
        // Leave ample headroom for conversion and WAV writes on the capture
        // queue. Repeated overruns switch this session back to energy detection.
        let budget = Double(samples.count) / 16000 * 0.5
        slowBatches = ProcessInfo.processInfo.systemUptime - started > budget ? slowBatches + 1 : 0
        guard slowBatches < 3 else { throw Unavailable() }
        return result
    }
}
