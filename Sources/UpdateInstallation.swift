import Foundation
import Security

enum UpdateInstallation {
    static let identifier = "cn.tingqiao.bridge"
    enum Failure: LocalizedError {
        case invalidBundle, signature, identity, notWritable
        var errorDescription: String? {
            switch self {
            case .invalidBundle: return "安装包与听桥不匹配。"
            case .signature: return "安装包签名校验未通过。"
            case .identity: return "新版签名身份与当前版本不同，请核对 GitHub 发布说明后手动安装。"
            case .notWritable: return "当前应用位置无法写入，请手动安装下载的 DMG。"
            }
        }
    }
    static func bundleVersion(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard url.pathExtension == "app",
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == identifier,
              info["CFBundleExecutable"] as? String == "TingQiao",
              let version = info["CFBundleShortVersionString"] as? String else { throw Failure.invalidBundle }
        return version
    }
    static func verifySignature(_ url: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", url.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.signature }
    }
    static func verifyIdentity(from target: URL, to candidate: URL) throws {
        var current: SecStaticCode?, next: SecStaticCode?
        guard SecStaticCodeCreateWithPath(target as CFURL, [], &current) == errSecSuccess,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &next) == errSecSuccess,
              let current, let next else { throw Failure.signature }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(current, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { throw Failure.signature }
        let certificates = (info as NSDictionary?)?[kSecCodeInfoCertificates] as? [SecCertificate] ?? []
        guard !certificates.isEmpty else { return }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(current, [], &requirement) == errSecSuccess,
              let requirement, SecStaticCodeCheckValidity(next, [], requirement) == errSecSuccess else { throw Failure.identity }
    }
    static func replace(staged: URL, target: URL) throws -> URL {
        let fm = FileManager.default
        _ = try bundleVersion(staged); _ = try bundleVersion(target)
        guard staged.standardizedFileURL != target.standardizedFileURL else { throw Failure.invalidBundle }
        let parent = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else { throw Failure.notWritable }
        try verifySignature(staged)
        try verifyIdentity(from: target, to: staged)
        let candidate = parent.appendingPathComponent(".TingQiao-update-\(UUID()).app")
        let previous = parent.appendingPathComponent(".TingQiao-previous-\(UUID()).app")
        defer { try? fm.removeItem(at: candidate) }
        try fm.copyItem(at: staged, to: candidate)
        try verifySignature(candidate)
        try fm.moveItem(at: target, to: previous)
        do { try fm.moveItem(at: candidate, to: target) }
        catch { try fm.moveItem(at: previous, to: target); throw error }
        return previous
    }
    static func restore(previous: URL, target: URL) throws {
        let fm = FileManager.default
        _ = try bundleVersion(previous)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: previous, to: target)
    }
}
