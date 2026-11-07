import Foundation
import CryptoKit

@main struct KomixVocabularyTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    static func checksum(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func main() throws {
        let fm = FileManager.default
        let model = LocalModel.find(.whisperKomix)!
        let template = URL(fileURLWithPath: "Resources/whisper-medium-vocab.bin")
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--repair" {
            let target = URL(fileURLWithPath: CommandLine.arguments[2])
            print("Repaired:", try LocalModelFiles.repairKomixVocabulary(model, at: target, template: template))
            return
        }
        let metadata = try Data(contentsOf: template)
        check(checksum(metadata) == "49639ac8580c3985225c05981ed17f85c8d193ebeaaab3bde2a0cddc38d2eb56", "official metadata identity")
        func readInt(_ at: Int) -> Int { Int(UInt32(littleEndian: metadata.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) })) }
        func appendInt(_ value: Int, to data: inout Data) { var value = UInt32(value).littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        let vocabOffset = 56 + readInt(48) * readInt(52) * 4
        let count = readInt(vocabOffset)
        var legacy = metadata.prefix(vocabOffset), offset = vocabOffset + 4
        appendInt(count, to: &legacy)
        var tokens: [Data] = []
        for _ in 0..<count {
            let length = readInt(offset); offset += 4
            let token = metadata.subdata(in: offset..<offset+length); offset += length; tokens.append(token)
            let decoded = Data(String(decoding: token, as: UTF8.self).utf8)
            appendInt(decoded.count, to: &legacy); legacy.append(decoded)
        }
        check(offset == metadata.count && count == 50_257, "complete vocabulary")
        check(tokens[94] == Data([0xa1]), "individual byte retained")
        check(tokens.filter { $0.range(of: Data([0xef,0xbf,0xbd])) != nil }.count == 4, "only original replacement tokens present")
        check(checksum(legacy) == "f676437ddef445443e95fc77d88d59013e9f6dc05d25ebcbabd89abeefc5565b", "damaged vocabulary reproduced")
        for text in ["한국어 통계 데이터", "안녕하세요", "평행추세 가정", "AI · 한글 123"] {
            let reconstructed = Data(text.utf8.flatMap { byte in tokens.first(where: { $0 == Data([byte]) })! })
            check(String(data: reconstructed, encoding: .utf8) == text, "Korean byte fragments reassemble")
        }
        let root = fm.temporaryDirectory.appendingPathComponent("tingqiao-komix-tests-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("komix.bin")
        let payload = Data((0..<65536).map { UInt8($0 % 251) })
        let original = legacy + payload
        try original.write(to: target)
        let receipt = LocalModelFiles.Receipt(engine: .whisperKomix, sourceSHA256: model.sha256, fileSHA256: checksum(original), bytes: Int64(original.count))
        try JSONEncoder().encode(receipt).write(to: LocalModelFiles.receiptURL(target))
        check(try LocalModelFiles.repairKomixVocabulary(model, at: target, template: template), "repair performed")
        check(try Data(contentsOf: target) == metadata + payload, "all weight bytes unchanged")
        let updated = try JSONDecoder().decode(LocalModelFiles.Receipt.self, from: Data(contentsOf: LocalModelFiles.receiptURL(target)))
        check(updated.sourceSHA256 == receipt.sourceSHA256 && updated.fileSHA256 == checksum(metadata+payload) && updated.bytes == metadata.count+payload.count, "receipt updated")
        check(try !LocalModelFiles.repairKomixVocabulary(model, at: target, template: template), "repeated repair is a no-op")
        let other = root.appendingPathComponent("other.bin"); try original.write(to: other)
        for engine in [RecognitionEngine.whisperTurbo, .whisperLarge, .qwenASR] {
            check(try !LocalModelFiles.repairKomixVocabulary(LocalModel.find(engine)!, at: other, template: template), "other engine bypasses repair")
            check(try Data(contentsOf: other) == original, "other engine file unchanged")
        }
        let unknown = root.appendingPathComponent("unknown.bin")
        try Data(repeating: 7, count: 600_000).write(to: unknown)
        do { try LocalModelFiles.repairKomixVocabulary(model, at: unknown, template: template); preconditionFailure("unknown model accepted") } catch { checks += 1 }
        check(try Data(contentsOf: unknown) == Data(repeating:7,count:600_000), "unknown file untouched")
        try original.write(to: target)
        try JSONEncoder().encode(receipt).write(to: LocalModelFiles.receiptURL(target))
        var damaged = original; damaged[damaged.count-1] ^= 1; try damaged.write(to: target)
        do { try LocalModelFiles.repairKomixVocabulary(model, at: target, template: template); preconditionFailure("wrong checksum accepted") } catch { checks += 1 }
        check(try Data(contentsOf: target) == damaged, "checksum failure leaves model intact")
        check(try fm.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".part") && !$0.hasSuffix(".backup") }, "temporary files cleaned")
        print("PASS: \(checks) Komix vocabulary checks")
    }
}
