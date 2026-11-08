import Foundation
import AppKit
import CryptoKit

struct AppUpdateVersion: Comparable, CustomStringConvertible, Equatable, Sendable {
    let parts: [Int]
    init?(_ value: String) {
        let value = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isNumber) }),
              components.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = components.map { Int($0)! }
    }
    var description: String { parts.map(String.init).joined(separator: ".") }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AppUpdateOffer: Equatable, Sendable {
    let version: AppUpdateVersion
    let page: URL
    let download: URL
    let bytes: Int64
    var sha256: String?
    let checksum: URL?

    static let repository = "oswin-creator/tingqiao-realtime-translation"
    static let latest = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let size: Int64; let digest: String? }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let html_url: URL
        let assets: [Asset]
    }
    static func validDownload(_ url: URL, version: AppUpdateVersion, name: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
            && url.path == "/\(repository)/releases/download/v\(version)/\(name)"
    }
    static func digest(_ value: String?) -> String? {
        guard let value, value.hasPrefix("sha256:") else { return nil }
        let hash = String(value.dropFirst(7)).lowercased()
        return hash.count == 64 && hash.allSatisfy({ "0123456789abcdef".contains($0) }) ? hash : nil
    }
    static func parse(_ data: Data) throws -> Self {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, let version = AppUpdateVersion(release.tag_name), release.tag_name == "v\(version)",
              release.html_url.absoluteString == "https://github.com/\(repository)/releases/tag/v\(version)" else { throw BridgeError("GitHub 版本信息不完整，请稍后重试。", retryable: false) }
        let name = "TingQiao-macOS-arm64-\(version).dmg"
        guard let asset = release.assets.first(where: { $0.name == name }), asset.size > 0, asset.size <= 500_000_000,
              validDownload(asset.browser_download_url, version: version, name: name) else { throw BridgeError("此版本尚未提供 Mac 安装包。", retryable: false) }
        let checksum = release.assets.first(where: { $0.name == "SHA256SUMS.txt" && validDownload($0.browser_download_url, version: version, name: "SHA256SUMS.txt") })?.browser_download_url
        let hash = digest(asset.digest)
        guard hash != nil || checksum != nil else { throw BridgeError("此版本缺少安装包校验信息。", retryable: false) }
        return Self(version: version, page: release.html_url, download: asset.browser_download_url, bytes: asset.size, sha256: hash, checksum: checksum)
    }
    static func checksum(_ data: Data, version: AppUpdateVersion) -> String? {
        let name = "TingQiao-macOS-arm64-\(version).dmg"
        guard data.count < 16_384, let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count == 2, fields[1] == name, let hash = digest("sha256:"+fields[0]) { return hash }
        }
        return nil
    }
}

struct AppUpdatePackage: Sendable {
    let staged: URL
    let target: URL
    let helper: URL
    let report: URL
    static func prepare(dmg: URL, offer: AppUpdateOffer, target: URL, helperSource: URL, root: URL, report: URL) throws -> Self {
        do { try LocalModelFiles.verify(dmg, bytes: offer.bytes, sha256: offer.sha256 ?? "") }
        catch { throw BridgeError("更新安装包校验未通过，请重新下载。", retryable: false) }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else { throw UpdateInstallation.Failure.notWritable }
        let mount = root.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        func diskImage(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil"); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw BridgeError("无法打开更新安装包，请重试。", retryable: false) }
        }
        try diskImage(["attach","-readonly","-nobrowse","-mountpoint",mount.path,dmg.path])
        defer { try? diskImage(["detach",mount.path]) }
        let app = mount.appendingPathComponent("听桥.app", isDirectory: true)
        guard try UpdateInstallation.bundleVersion(app) == offer.version.description else { throw UpdateInstallation.Failure.invalidBundle }
        try UpdateInstallation.verifySignature(app)
        try UpdateInstallation.verifyIdentity(from: target, to: app)
        let staged = root.appendingPathComponent("听桥.app", isDirectory: true)
        try fm.copyItem(at: app, to: staged)
        let helper = root.appendingPathComponent("TingQiaoUpdater")
        try fm.copyItem(at: helperSource, to: helper)
        return Self(staged: staged, target: target, helper: helper, report: report)
    }
    func launch(parent: Int32) throws {
        let process = Process(); process.executableURL = helper
        process.arguments = ["--install",String(parent),staged.path,target.path,report.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

@MainActor final class AppUpdateController: ObservableObject {
    @Published var checking = false
    @Published var downloading = false
    @Published var preparing = false
    @Published var offer: AppUpdateOffer?
    @Published var progress: Double = 0
    @Published var received: Int64 = 0
    @Published var message = ""
    private var operation: Task<Void, Never>?
    private var session: URLSession?
    var busy: Bool { checking || downloading || preparing }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    func check() {
        guard !busy else { return }
        offer = nil; message = ""; checking = true
        operation = Task {
            defer { checking = false; operation = nil }
            do {
                var request = URLRequest(url: AppUpdateOffer.latest, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("TingQiao/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
                let (data,response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576 else { throw BridgeError("暂时无法获取 GitHub 最新版本，请稍后再试。") }
                let release = try AppUpdateOffer.parse(data)
                guard let current = AppUpdateVersion(Self.currentVersion) else { throw BridgeError("无法读取当前版本。") }
                if release.version > current { offer = release }
                else { message = "当前已是最新版本。" }
            } catch is CancellationError { message = "" }
            catch { message = error.localizedDescription }
        }
    }
    func install(canInstall: @escaping () -> Bool, onPrepared: @escaping () -> Void) {
        guard !busy, var release = offer else { return }
        downloading = true; progress = 0; received = 0; message = ""
        operation = Task {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("TingQiaoUpdate-\(UUID())", isDirectory: true)
            var handedOff = false
            defer {
                session?.invalidateAndCancel(); session = nil
                downloading = false; preparing = false; operation = nil
                if !handedOff { try? FileManager.default.removeItem(at: root) }
            }
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if release.sha256 == nil, let checksum = release.checksum {
                    let (data,response) = try await URLSession.shared.data(from: checksum)
                    guard (response as? HTTPURLResponse)?.statusCode == 200, let hash = AppUpdateOffer.checksum(data, version: release.version) else { throw BridgeError("无法读取安装包校验值。") }
                    release.sha256 = hash
                }
                let downloader = ModelDownloader(expectedBytes: release.bytes) { [weak self = self] snapshot in
                    Task { @MainActor in self?.progress = snapshot.fraction; self?.received = snapshot.receivedBytes }
                }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 1800
                let transfer = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil); session = transfer
                let (file,response) = try await downloader.download(from: release.download, session: transfer)
                defer { try? FileManager.default.removeItem(at: file) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BridgeError("更新下载未完成，请重试。") }
                try Task.checkCancellation()
                downloading = false; preparing = true
                guard let helper = Bundle.main.url(forAuxiliaryExecutable: "TingQiaoUpdater") else { throw BridgeError("当前安装缺少更新工具，请使用完整安装包。", retryable: false) }
                let target = Bundle.main.bundleURL
                let reportDirectory = LocalModel.directory.deletingLastPathComponent().appendingPathComponent("Updates", isDirectory: true)
                try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let report = reportDirectory.appendingPathComponent("last-update.txt")
                let downloadedRelease = release
                let ready = try await Task.detached(priority: .utility) { try AppUpdatePackage.prepare(dmg: file, offer: downloadedRelease, target: target, helperSource: helper, root: root, report: report) }.value
                try Task.checkCancellation()
                guard canInstall() else { throw BridgeError("请结束收音和当前任务后再安装更新。", retryable: false) }
                try ready.launch(parent: ProcessInfo.processInfo.processIdentifier)
                handedOff = true
                onPrepared()
            } catch is CancellationError { message = "下载已取消。" }
            catch let error as URLError where error.code == .cancelled { message = "下载已取消。" }
            catch { message = error.localizedDescription }
        }
    }
    func cancel() { guard !preparing else { return }; operation?.cancel(); session?.invalidateAndCancel() }
}
