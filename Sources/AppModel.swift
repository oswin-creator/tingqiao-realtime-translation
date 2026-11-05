import Foundation
import AppKit
import Speech
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings.load()
    @Published var jobs: [AudioJob] = []
    @Published var isRunning = false
    @Published var isStarting = false
    @Published var isStopping = false
    @Published var isReconnecting = false
    @Published var level = 0.0
    @Published var notice = ""
    @Published var devices: [InputDevice] = []
    @Published var applications: [MeetingApplication] = []
    @Published var phoneEnabled = false
    @Published var phoneURL = ""
    @Published var bluetoothEnabled = false
    @Published var bluetoothStatus = "蓝牙字幕未开启"
    @Published var bluetoothCode = ""
    @Published var bluetoothConnections = 0
    @Published var pairedPhones: [BluetoothPeer] = []
    @Published var hideDesktopCaptions = false
    @Published var floatingVisible = false
    @Published var startedAt: Date?
    @Published var checkingAPI = false
    @Published var apiResult = ""
    @Published var customKey = ""
    @Published var googleKey = ""
    @Published var section = "会议翻译"
    @Published var stylePreview = CommandLine.arguments.contains("--ui-preview")
    @Published var recognitionInfo = ""
    @Published var installingAppleLanguage = false
    @Published var whisperInstalled = WhisperEngine.installed
    @Published var downloadingWhisper = false
    @Published var draftText = ""
    @Published var assistantSettings = AssistantSettings.load()
    let assistantPresentation = AssistantPresentation()
    var assistantReply: AssistantReply? {
        get { assistantPresentation.reply }
        set { if assistantPresentation.reply != newValue { assistantPresentation.reply = newValue } }
    }
    @Published private(set) var assistantBusy = false
    private var assistantTask: Task<Void, Never>?
    private var draftCaption: Caption?
    private var draftStability = DraftStability()
    private var draftWindowID: UUID?
    private var previewTask: Task<Void, Never>?
    private var previewActive = false
    private var previewCooldown = Date.distantPast
    private var finalizedWindows = Set<UUID>()
    @Published var isRecoveringPipeline = false
    @Published private(set) var pipelineRecoveryCount = 0
    private var pipelineGeneration = 0
    private var pipelineRecovery: Task<Void, Never>?
    @Published var secretsLoading = false
    @Published var keychainNeedsAccess = false
    private var customKeyLoaded = false
    private var googleKeyLoaded = false
    @Published var isClearing = false
    @Published var floatingFollowsLatest = true
    @Published var mainFollowsLatest = true

    private var store: SessionStore?
    private let speech = SpeechRecognition()
    private var capture: AudioCapture?
    private let server = PhoneServer()
    private let bluetooth = BluetoothCaptionServer()
    private var recognitionActive = false
    private var translationsActive = Set<UUID>()
    private var recognitionTask: Task<Void, Never>?
    private var recognitionJobID: UUID?
    private var translationTasks: [UUID: Task<Void, Never>] = [:]
    private var timer: Timer?
    private var captureRetry: Task<Void, Never>?
    private var captureSettings: AppSettings?
    private var sessionID = UUID()
    private var sleepActivity: NSObjectProtocol?
    private var storageHealthy = true
    private var speechAuthorized = false
    private var floating: NSPanel?
    private var terminating = false
    private var lastAudioAt = Date()
    private var lastDiskCheck = Date.distantPast
    private var lastRecognitionAt = Date.distantFuture
    private var sleepObservers: [NSObjectProtocol] = []
    private var captureEpoch = UUID()
    private var backgroundWorkEnabled = true
    private var floatingDelegate: FloatingWindowDelegate?

    var visibleJobs: [AudioJob] { jobs.filter { $0.deletedAt == nil } }
    var deletedCount: Int { jobs.filter { $0.deletedAt != nil }.count }
    var canUndoClear: Bool { deletedCount > 0 }
    var pendingCount: Int { jobs.filter { $0.deletedAt == nil && $0.stage != .done }.count }
    var blockedCount: Int { jobs.filter { $0.deletedAt == nil && $0.stage == .blocked }.count }
    var currentCaptureEpoch: UUID { captureEpoch }
    var currentPipelineGeneration: Int { pipelineGeneration }
    var languageSelectionLocked: Bool { isRunning || isStarting || isStopping || installingAppleLanguage }
    var allCaptions: [Caption] {
        var result = jobs.filter { $0.deletedAt == nil }.compactMap { job -> Caption? in
            if !job.original.isEmpty { return Caption(id: job.id, date: job.created, original: job.original, translated: job.translated) }
            guard job.stage == .recognize || job.stage == .blocked else { return nil }
            let preview = job.previewText ?? ""
            let cleanPreview = RepeatedText.containsRun(preview) ? "" : preview
            let status: String? = job.stage == .blocked ? "这一段识别失败 · 音频已保留"
                : job.recognitionFailures > 0 ? "正在重新识别…" : nil
            guard !cleanPreview.isEmpty || status != nil else { return nil }
            return Caption(isDraft: true, id: job.id, date: job.created, original: cleanPreview, translated: "", recognitionStatus: status)
        }
        if let draftCaption, !result.contains(where: { $0.id == draftCaption.id }) { result.append(draftCaption) }
        return result
    }
    var captions: [Caption] {
        Array(allCaptions.suffix(200))
    }
    var status: String {
        if isStarting { return "正在准备收音" }
        if isStopping { return "正在结束收音" }
        if isReconnecting { return "收音中断，正在重新连接" }
        if isRecoveringPipeline { return "识别与翻译正在自动恢复 · 音频继续保存" }
        if isRunning {
            let configuration = captureSettings ?? settings
            return "正在收音 · \(MeetingLanguage.sourceName(configuration.language)) → \(configuration.targetLanguage.title)"
        }
        if pendingCount > 0 && (recognitionActive || !translationsActive.isEmpty) { return "正在处理已保存的内容" }
        return pendingCount > 0 ? "已停止收音 · 有待处理内容" : "准备就绪，随时开始"
    }

    init(store providedStore: SessionStore? = nil, settings initialSettings: AppSettings? = nil, startBackgroundWork: Bool = true) {
        if let initialSettings { settings = initialSettings }
        backgroundWorkEnabled = startBackgroundWork
        do {
            let storage = try providedStore ?? SessionStore()
            store = storage
            jobs = try storage.load()
            for url in try storage.recoverOrphanAudio(known: jobs) {
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                jobs.append(AudioJob(id: UUID(), sessionID: UUID(), created: date, audioFile: url.lastPathComponent, language: settings.language, localRecognition: settings.localRecognition, targetLanguage: settings.targetLanguage))
                notice = "找回了上次意外退出前的音频。开始会议或点击“重试待处理”后继续识别；语言采用当前设置。"
            }
            jobs.sort { $0.created < $1.created }
            try storage.save(jobs)
        } catch { storageHealthy = false; notice = "历史数据无法读取或保存。为保护原文件，已暂停处理。请打开数据文件夹检查：\(error.localizedDescription)" }
        if startBackgroundWork { refreshDevices() }
        if jobs.contains(where: { $0.deletedAt == nil && $0.stage == .recognize }) && notice.isEmpty { notice = "有上次会议的音频等待识别，点击“重试待处理”可继续。" }
        server.onReady = { [weak self] port in Task { @MainActor in guard let self, self.phoneEnabled else { return }; self.phoneURL = self.server.pairingURL(port: port); self.publishPhone() } }
        server.onError = { [weak self] message in Task { @MainActor in self?.notice = message; self?.phoneEnabled = false; self?.phoneURL = "" } }
        let remoteAssistant: (AssistantRequest, @escaping (AssistantReply) -> Void) -> Void = { [weak self] request, deliver in
            Task { @MainActor in self?.requestAssistant(request, deliver: deliver) }
        }
        server.onAssistantRequest = remoteAssistant
        bluetooth.onAssistantRequest = remoteAssistant
        if CommandLine.arguments.contains("--ui-preview") || CommandLine.arguments.contains("--connection-check") {
            bluetooth.onDiagnostic = { print("[BLE test] " + $0); fflush(stdout) }
        }
        bluetooth.onState = { [weak self] status, count in
            Task { @MainActor in
                guard let self, self.bluetoothEnabled else { return }
                self.bluetoothStatus = status; self.bluetoothConnections = count
            }
        }
        bluetooth.onPeers = { [weak self] peers in Task { @MainActor in self?.pairedPhones = peers } }
        if startBackgroundWork { bluetooth.refreshPeers() }
        guard startBackgroundWork else { return }
        sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in if self?.isRunning == true { self?.captureFailed("电脑即将休眠，唤醒后将尝试重新收音。") } } })
        sleepObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in if self?.isRunning == true { self?.captureFailed("电脑已唤醒，正在恢复收音。") } } })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.pump() } }
    }

    func refreshDevices() { devices = AudioCapture.devices() }
    func refreshApplications() {
        Task {
            do { applications = try await AudioCapture.applications() }
            catch { notice = "读取应用列表需要系统录音权限。也可以先选择“全部系统声音”，点击开始后授权。" }
        }
    }
    func saveSettings() {
        guard !secretsLoading else { notice = "请先处理正在等待的 macOS 钥匙串提示，再保存密钥。"; return }
        settings.save()
        do {
            // A denied read must never turn an empty field into deletion of a saved key.
            if customKeyLoaded || !customKey.isEmpty { try SecretStore.write(customKey, account: "custom-api"); customKeyLoaded = true }
            if googleKeyLoaded || !googleKey.isEmpty { try SecretStore.write(googleKey, account: "google-cloud"); googleKeyLoaded = true }
            notice = "设置已保存，API 密钥存放在 macOS 钥匙串中。"
            retryTranslations()
        } catch { notice = error.localizedDescription }
    }
    var providerKeyReady: Bool {
        switch settings.provider {
        case .googleFree, .indexTranslate: return true
        case .custom: return customKeyLoaded || !customKey.isEmpty
        case .googleCloud: return googleKeyLoaded || !googleKey.isEmpty
        }
    }
    func loadSecrets() {
        guard !CommandLine.arguments.contains("--ui-preview"), !CommandLine.arguments.contains("--connection-check"), !secretsLoading else { return }
        secretsLoading = true
        Task {
            // System keychain authorization can wait for the user. Keep the window responsive.
            let results = await Task.detached(priority: .userInitiated) {
                (Result { try SecretStore.read("custom-api") }, Result { try SecretStore.read("google-cloud") })
            }.value
            var errors: [String] = []
            switch results.0 {
            case .success(let value): if customKey.isEmpty { customKey = value }; customKeyLoaded = true
            case .failure(let error): errors.append(error.localizedDescription)
            }
            switch results.1 {
            case .success(let value): if googleKey.isEmpty { googleKey = value }; googleKeyLoaded = true
            case .failure(let error): errors.append(error.localizedDescription)
            }
            secretsLoading = false; keychainNeedsAccess = !errors.isEmpty
            if let error = errors.first { notice = error }
            pump()
        }
    }

    func start() {
        guard !CommandLine.arguments.contains("--connection-check") else { notice = "连接检查模式仅显示测试字幕，不开启收音。请正常重开听桥后使用会议翻译。"; return }
        guard !languageSelectionLocked, storageHealthy, let store else { return }
        let needsTranslation = settings.language != settings.targetLanguage.rawValue
        guard !needsTranslation || providerKeyReady else { notice = "请先处理 macOS 钥匙串提示，以读取已保存的翻译密钥；也可在翻译设置中重新读取。"; return }
        isStarting = true; notice = ""; settings.save()
        Task {
            do {
                if let space = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, space < 250_000_000 { throw BridgeError("可用磁盘空间不足 250 MB，请先清理空间。", retryable: false) }
                if needsTranslation && settings.provider == .custom { _ = try TranslationClient.endpoint(settings.baseURL); guard !settings.model.isEmpty else { throw BridgeError("请先到翻译设置填写模型名称并保存。", retryable: false) } }
                if needsTranslation && settings.provider == .googleCloud && googleKey.isEmpty { throw BridgeError("请先到翻译设置保存谷歌 Cloud API Key。", retryable: false) }
                if settings.localRecognition { notice = "正在检查本机识别资源…" }
                try await speech.authorize(language: settings.language, localOnly: settings.localRecognition, engine: settings.recognitionEngine)
                speechAuthorized = true; lastRecognitionAt = Date()
                sessionID = UUID(); captureEpoch = UUID(); captureSettings = settings
                let engine = makeCapture(settings: settings)
                capture = engine
                try await engine.start(settings: settings)
                finalizedWindows.removeAll(); draftCaption = nil; draftText = ""
                lastAudioAt = Date()
                isRunning = true; startedAt = Date(); isStarting = false; notice = ""
                sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiatedAllowingIdleSystemSleep], reason: "听桥正在持续收音和翻译会议")
                publishPhone(); pump()
            } catch {
                if let capture { await capture.stop() }; capture = nil
                isStarting = false; notice = error.localizedDescription
                publishPhone()
            }
        }
    }

    func stop() {
        guard !isStarting, !isStopping else { return }
        isRunning = false; isStopping = true; isReconnecting = false
        captureRetry?.cancel(); captureRetry = nil
        let old = capture; capture = nil
        Task {
            await old?.stop()
            if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity); sleepActivity = nil }
            level = 0; isStopping = false
            persist(); publishPhone(); pump()
        }
    }

    private func makeCapture(settings: AppSettings) -> AudioCapture {
        let engine = AudioCapture(directory: store!.audio, epoch: captureEpoch)
        engine.segmenter.onLevel = { [weak self] value in Task { @MainActor in self?.level = value; self?.lastAudioAt = Date() } }
        engine.onWindow = { [weak self] window, epoch in
            Task { @MainActor in
                guard let self else { return }
                self.acceptWindow(window, epoch: epoch, settings: settings)
            }
        }
        engine.segmenter.onFailure = { [weak self] message in Task { @MainActor in self?.storageHealthy = false; self?.notice = message; self?.stop() } }
        engine.onFailure = { [weak self] message in Task { @MainActor in self?.captureFailed(message) } }
        return engine
    }

    private func captureFailed(_ message: String) {
        guard isRunning, !isReconnecting else { return }
        notice = message; isReconnecting = true; publishPhone()
        captureRetry = Task { [weak self] in
            guard let self else { return }
            await self.capture?.stop(); self.capture = nil
            var attempt = 0
            while self.isRunning, !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(min(20, 2 + attempt * 2)) * 1_000_000_000)
                    guard self.isRunning, !Task.isCancelled, let settings = self.captureSettings else { return }
                    let engine = self.makeCapture(settings: settings)
                    self.capture = engine
                    try await engine.start(settings: settings)
                    if !self.isRunning || Task.isCancelled { await engine.stop(); return }
                    self.isReconnecting = false; self.notice = "收音已恢复。中断期间未收到的声音无法补回。"; self.publishPhone(); return
                } catch is CancellationError { return }
                catch { await self.capture?.stop(); self.capture = nil; attempt += 1; self.notice = "正在重新连接（第 \(attempt) 次）：\(error.localizedDescription)" }
            }
        }
    }

    func retryPending() {
        Task {
            do {
                if let pending = jobs.first(where: { $0.deletedAt == nil && ($0.stage == .recognize || ($0.stage == .blocked && $0.original.isEmpty)) }) {
                    try await speech.authorize(language: pending.language, localOnly: settings.localRecognition, engine: settings.recognitionEngine)
                    speechAuthorized = true
                }
                for index in jobs.indices where jobs[index].deletedAt == nil && jobs[index].stage != .done {
                    if jobs[index].stage == .blocked { jobs[index].stage = jobs[index].original.isEmpty ? .recognize : .translate }
                    jobs[index].repetitionRetries = nil; jobs[index].translationRepetitionRetries = nil
                    jobs[index].recognitionEngine = settings.recognitionEngine
                    jobs[index].localRecognition = settings.localRecognition
                    jobs[index].retryAfter = .distantPast; jobs[index].attempts = 0; jobs[index].error = ""
                }
                notice = "正在重试待处理内容。"; persist(); pump()
            } catch { notice = error.localizedDescription }
        }
    }
    private func retryTranslations() {
        for index in jobs.indices where jobs[index].deletedAt == nil && jobs[index].stage == .blocked && !jobs[index].original.isEmpty {
            jobs[index].stage = .translate; jobs[index].retryAfter = .distantPast; jobs[index].attempts = 0
        }
        persist(); pump()
    }

    private func pump() {
        guard backgroundWorkEnabled, !terminating, storageHealthy, let store else { return }
        let now = Date()
        if !isRunning, !isStarting, !recognitionActive, !previewActive, now.timeIntervalSince(lastRecognitionAt) > 120 { WhisperEngine.shared.stop(); lastRecognitionAt = .distantFuture }
        if isRunning, !isReconnecting, captureSettings?.mode == .inPerson, now.timeIntervalSince(lastAudioAt) > 12 {
            lastAudioAt = now; captureFailed("麦克风超过 12 秒没有送来音频，正在重新连接。")
        }
        if isRunning, now.timeIntervalSince(lastDiskCheck) > 30 {
            lastDiskCheck = now
            if let space = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage, space < 100_000_000 {
                notice = "磁盘可用空间不足 100 MB，已停止收音，现有片段已保留。请清理空间后重新开始。"; stop()
            }
        }
        guard !isRecoveringPipeline else { return }
        if speechAuthorized, !recognitionActive, !previewActive, let job = jobs.first(where: { $0.deletedAt == nil && $0.stage == .recognize && $0.retryAfter <= now }) {
            recognitionActive = true; recognitionJobID = job.id
            let generation = pipelineGeneration
            recognitionTask = Task {
                defer { recognitionActive = false; recognitionJobID = nil; recognitionTask = nil; pump() }
                do {
                    var text = try await speech.recognize(
                        url: store.audio.appendingPathComponent(job.audioFile), language: job.language,
                        localOnly: job.localRecognition, engine: job.recognitionEngine ?? .apple,
                        retry: job.recognitionFailures > 0
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !Task.isCancelled, generation == pipelineGeneration else { return }
                    if RepeatedText.containsRun(text) {
                        failed(job.id, error: BridgeError("识别原文出现异常重复。")); return
                    }
                    if job.overlap, let previous = jobs.last(where: { $0.deletedAt == nil && $0.sessionID == job.sessionID && $0.created < job.created && !$0.original.isEmpty }) {
                        text = CaptionText.removingOverlap(previous: previous.original, current: text)
                    }
                    lastRecognitionAt = Date()
                    _ = commitRecognition(text, for: job.id, generation: generation)
                } catch { if generation == pipelineGeneration { failed(job.id, error: error) } }
            }
        }
        while translationsActive.count < (settings.provider == .indexTranslate ? 1 : 2), let job = jobs.first(where: {
            $0.deletedAt == nil && $0.stage == .translate && $0.retryAfter <= now && !translationsActive.contains($0.id) &&
                (providerKeyReady || $0.language == $0.resolvedTargetLanguage.rawValue)
        }) {
            if RepeatedText.containsRun(job.original) {
                if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].stage = .blocked; jobs[index].error = "原文包含异常重复，已停止发送；请检查并重试保留的音频。" }
                guard persist() else { return }
                publishPhone(); continue
            }
            translationsActive.insert(job.id)
            let generation = pipelineGeneration
            let client = TranslationClient(settings: settings, key: settings.provider == .googleCloud ? googleKey : customKey)
            let context = (job.translationRepetitionRetries ?? 0) == 0 && (settings.provider == .custom || settings.provider == .indexTranslate)
                ? TranslationHistory.context(before: job, in: jobs, limit: settings.effectiveTranslationContextCount)
                : []
            translationTasks[job.id] = Task {
                defer { translationsActive.remove(job.id); translationTasks.removeValue(forKey: job.id); pump() }
                do {
                    let translation = try await client.translate(job.original, language: job.language, targetLanguage: job.resolvedTargetLanguage, context: context)
                    guard !Task.isCancelled, generation == pipelineGeneration else { return }
                    _ = commitTranslation(translation, for: job.id, generation: generation)
                } catch { if generation == pipelineGeneration { failed(job.id, error: error) } }
            }
        }
    }
    func failed(_ id: UUID, error: Error) {
        guard !(error is CancellationError), !Task.isCancelled,
              let index = jobs.firstIndex(where: { $0.id == id && $0.deletedAt == nil }),
              jobs[index].stage == .recognize || jobs[index].stage == .translate else { return }
        if jobs[index].stage == .recognize {
            jobs[index].attempts = jobs[index].recognitionFailures + 1
            let canRetry = jobs[index].attempts == 1 && (error as? BridgeError)?.retryable != false
            if canRetry {
                jobs[index].retryAfter = Date().addingTimeInterval(1)
                jobs[index].error = "正在重新识别这段音频。\(error.localizedDescription)"
            } else {
                jobs[index].stage = .blocked
                jobs[index].error = "这一段识别失败，音频已保留。\(error.localizedDescription)"
            }
            notice = jobs[index].error
            persist(); publishPhone()
            return
        }
        jobs[index].attempts += 1
        jobs[index].error = error.localizedDescription
        if let bridge = error as? BridgeError, !bridge.retryable { jobs[index].stage = .blocked }
        else { jobs[index].retryAfter = Date().addingTimeInterval(min(60, pow(2, Double(min(6, jobs[index].attempts))))) }
        notice = error.localizedDescription
        persist(); publishPhone()
    }
    @discardableResult private func persist() -> Bool {
        guard storageHealthy else { return false }
        do { try store?.save(jobs); return true }
        catch {
            storageHealthy = false; notice = "会议内容保存失败，已停止继续收音。原始片段仍保留：\(error.localizedDescription)"
            if isRunning { stop() }
            return false
        }
    }
    func togglePhone() {
        if phoneEnabled {
            phoneEnabled = false; phoneURL = ""; server.stop()
        } else {
            do { phoneEnabled = true; try server.start(); publishPhone() }
            catch { phoneEnabled = false; notice = "手机服务启动失败：\(error.localizedDescription)" }
        }
    }
    func toggleBluetooth() {
        if bluetoothEnabled {
            bluetoothEnabled = false; bluetooth.stop(); bluetoothCode = ""; bluetoothConnections = 0; bluetoothStatus = "蓝牙字幕未开启"
        } else {
            bluetoothEnabled = true
            let previewCode = ProcessInfo.processInfo.environment["TINGQIAO_BLE_TEST_CODE"] ?? ""
            if CommandLine.arguments.contains("--ui-preview"), previewCode.range(of: "^[0-9]{6}$", options: .regularExpression) != nil { bluetoothCode = previewCode }
            else { bluetoothCode = UserDefaults.standard.string(forKey: "bluetooth.pairingCode") ?? String(Int.random(in: 100000...999999)); UserDefaults.standard.set(bluetoothCode, forKey: "bluetooth.pairingCode") }
            bluetoothStatus = "正在准备蓝牙…"; bluetooth.start(code: bluetoothCode); publishPhone()
        }
    }
    func forgetPhone(_ id: String) { bluetooth.forget(id) }
    private func publishPhone() {
        let phoneCaptions = captions.suffix(80).map { caption in
            // Older phone apps display this slot as the caption's second line.
            guard let recognitionStatus = caption.recognitionStatus else { return caption }
            var display = caption
            display.isDraft = false
            display.translated = recognitionStatus
            return display
        }
        let snapshot = PhoneSnapshot(status: status, running: isRunning && !isReconnecting, captions: phoneCaptions, pending: pendingCount)
        server.publish(snapshot)
        if bluetoothEnabled { bluetooth.publish(snapshot) }
    }
    func copyPhoneURL() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(phoneURL, forType: .string) }

    func askAssistant(_ action: AssistantAction) {
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        guard let request = AssistantRequest(action: action.rawValue, id: String(id)) else { return }
        assistantReply = AssistantReply(id: request.id, action: action, state: .waiting, text: "正在整理最近的对话…")
        requestAssistant(request) { [weak self] reply in
            guard self?.assistantReply?.id == reply.id else { return }
            self?.assistantReply = reply
        }
    }

    private func requestAssistant(_ request: AssistantRequest, deliver: @escaping (AssistantReply) -> Void) {
        var reasoning: String?
        func reply(_ state: AssistantReply.State, _ text: String) {
            deliver(AssistantReply(id: request.id, action: request.action, state: state, text: text, reasoning: reasoning))
        }
        guard !terminating, !assistantBusy else { reply(.error, "已有一条问答在处理，请稍后再试。"); return }
        let configuration = assistantSettings
        guard configuration.configured else { reply(.error, "请先在 Mac 的「问答大模型设置」填写并保存接口。"); return }
        let context = AssistantContext.recent(from: jobs, session: isRunning ? sessionID : nil)
        guard !context.isEmpty else { reply(.error, "等有正式字幕后，再使用会议助手。"); return }
        let language = captureSettings?.language ?? jobs.last(where: { $0.deletedAt == nil })?.language ?? settings.language
        assistantBusy = true
        reply(.waiting, "正在整理最近的对话…")
        assistantTask = Task {
            defer { assistantBusy = false; assistantTask = nil }
            do {
                let account = try configuration.keyAccountForEndpoint()
                let key = try await Task.detached { try SecretStore.read(account) }.value
                try Task.checkCancellation()
                let output = try await MeetingAssistantClient(settings: configuration, key: key).respond(to: request.action, context: context, language: language) { progress in
                    guard !Task.isCancelled, progress != reasoning else { return }
                    reasoning = progress
                    reply(.waiting, "正在等待正式回答…")
                }
                try Task.checkCancellation()
                reasoning = output.reasoning
                reply(.ready, output.text)
            } catch is CancellationError {
                reply(.error, "这次问答已取消。")
            } catch let error as BridgeError {
                reply(.error, error.localizedDescription)
            } catch {
                reply(.error, "问答暂时未完成，请检查连接后再试。")
            }
        }
    }

    func testAPI() {
        guard providerKeyReady else { apiResult = "请先完成钥匙串授权，或填写新的密钥。"; return }
        checkingAPI = true; apiResult = "正在测试…"
        let client = TranslationClient(settings: settings, key: settings.provider == .googleCloud ? googleKey : customKey)
        let source: MeetingLanguage = settings.targetLanguage == .english ? .korean : .english
        let sample = source == .korean ? "회의는 아홉 시에 시작합니다." : "The meeting starts at nine."
        Task {
            do { apiResult = "连接成功：" + (try await client.translate(sample, language: source.rawValue)) }
            catch { apiResult = error.localizedDescription }
            checkingAPI = false
        }
    }
    func checkRecognitionSupport() {
        guard settings.recognitionEngine == .apple else {
            whisperInstalled = WhisperEngine.installed
            recognitionInfo = whisperInstalled ? "所有语言共用已安装的 Whisper 模型。" : "尚未安装 Whisper 模型，请下载或导入。"
            return
        }
        let language = settings.language
        let name = MeetingLanguage.sourceName(language)
        Task {
            let info: String
            if #available(macOS 26.0, *), let status = await ModernSpeech.assetStatus(language), status != .unsupported {
                info = status == .installed ? "Apple 本机\(name)资源已安装。" : "Apple 本机\(name)资源尚未就绪，可手动下载。"
            } else {
                let local = SFSpeechRecognizer(locale: Locale(identifier: language))?.supportsOnDeviceRecognition == true
                info = local ? "Apple 旧版识别报告支持本机\(name)。" : "这台 Mac 未报告支持 Apple 本机\(name)，可使用 Whisper。"
            }
            guard settings.language == language, settings.recognitionEngine == .apple, !installingAppleLanguage else { return }
            recognitionInfo = info
        }
    }
    func selectSourceLanguage(_ language: String) {
        guard !languageSelectionLocked else { return }
        settings.language = language
        recognitionInfo = ""
        settings.save()
    }
    func selectTargetLanguage(_ language: MeetingLanguage) {
        guard !languageSelectionLocked else { return }
        settings.targetLanguage = language
        settings.save()
    }
    func openAppleLanguageSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
        if !NSWorkspace.shared.open(url) { recognitionInfo = "请手动打开「系统设置 → 键盘 → 听写」。" }
    }
    func installAppleLanguage() {
        guard #available(macOS 26.0, *), settings.recognitionEngine == .apple, !installingAppleLanguage, !isRunning, !isStarting, !isStopping else { return }
        let language = settings.language
        let name = MeetingLanguage.sourceName(language)
        installingAppleLanguage = true
        recognitionInfo = "正在准备 Apple 本机\(name)资源…"
        Task {
            defer { installingAppleLanguage = false }
            do {
                if try await ModernSpeech.installLanguage(language) {
                    recognitionInfo = "Apple 本机\(name)资源已安装。"
                } else {
                    recognitionInfo = "Apple 新版本机引擎未能准备\(name)。请检查本机语言支持。"
                }
            } catch {
                recognitionInfo = "Apple 本机\(name)资源准备失败：\(error.localizedDescription)"
            }
        }
    }
    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "听桥会议-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = TranscriptExport.render(jobs)
        do { try text.write(to: url, atomically: true, encoding: .utf8); notice = "会议记录已导出。" }
        catch { notice = "导出失败：\(error.localizedDescription)" }
    }
    func openDataFolder() { if let store { NSWorkspace.shared.open(store.root) } }
    func clearHistory() {
        guard !isClearing, !visibleJobs.isEmpty || draftCaption != nil else { return }
        Task { await clearRecords() }
    }
    func clearRecords() async {
        guard !isClearing, storageHealthy else { return }
        isClearing = true
        assistantReply = nil; assistantTask?.cancel()
        defer { isClearing = false }
        // Advance before awaiting the capture queue: old queued callbacks cannot return.
        captureEpoch = UUID(); sessionID = UUID()
        previewTask?.cancel(); draftCaption = nil; draftText = ""; draftWindowID = nil; draftStability = DraftStability()
        let ids = Set(visibleJobs.map(\.id))
        removeRecords(ids)
        await capture?.discardPendingAudio(epoch: captureEpoch)
    }
    func removeRecords(_ ids: Set<UUID>) {
        guard storageHealthy else { return }
        let old = jobs, date = Date()
        for index in jobs.indices where ids.contains(jobs[index].id) && jobs[index].deletedAt == nil {
            jobs[index].deletedAt = date
        }
        guard persist() else { jobs = old; return }
        if let id = recognitionJobID, ids.contains(id) { recognitionTask?.cancel() }
        for id in ids { translationTasks[id]?.cancel() }
        if let draftCaption, ids.contains(draftCaption.id) { self.draftCaption = nil; draftText = "" }
        stylePreview = false
        notice = "记录已清空，可点击“撤销清空”恢复。"
        publishPhone()
    }
    func undoClear() {
        guard storageHealthy, let date = jobs.compactMap(\.deletedAt).max() else { return }
        let old = jobs
        for index in jobs.indices where jobs[index].deletedAt == date {
            jobs[index].deletedAt = nil
            jobs[index].retryAfter = .distantPast
        }
        guard persist() else { jobs = old; return }
        notice = "已恢复上一次清除的记录。"; publishPhone(); pump()
    }
    func purgeDeleted() {
        guard storageHealthy, deletedCount > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "永久删除最近清除的记录？"
        alert.informativeText = "将删除 \(deletedCount) 段记录和对应音频，之后无法撤销。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "永久删除")
        guard alert.runModal() == .alertSecondButtonReturn, let store else { return }
        do {
            for job in jobs where job.deletedAt != nil { try store.permanentlyRemoveAudio(job) }
            let old = jobs; jobs.removeAll { $0.deletedAt != nil }
            guard persist() else { jobs = old; return }
            notice = "最近清除的记录已永久删除。"
        } catch { notice = "删除音频失败，记录已保留：\(error.localizedDescription)" }
    }
    func acceptWindow(_ window: SpeechWindow, epoch: UUID, settings: AppSettings) {
        guard epoch == captureEpoch else { try? FileManager.default.removeItem(at: window.url); return }
        if window.isFinal {
            finalizedWindows.insert(window.id)
            if finalizedWindows.count > 256 { finalizedWindows = [window.id] }
            let preview = draftCaption?.id == window.id ? draftCaption?.original : nil
            // Journal the same row before retiring the draft, so there is no gap.
            acceptCapturedAudio(url: window.url, date: window.date, overlap: window.overlap, epoch: epoch, settings: settings, id: window.id, preview: preview)
            if draftWindowID == window.id { draftCaption = nil; draftText = "" }
            return
        }
        // Drop superseded preview work, never final audio. Final jobs have priority.
        guard isRunning, !isRecoveringPipeline, !previewActive, !recognitionActive, Date() >= previewCooldown,
              !jobs.contains(where: { $0.deletedAt == nil && $0.stage == .recognize }) else {
            try? FileManager.default.removeItem(at: window.url); return
        }
        previewActive = true
        if draftWindowID != window.id { draftWindowID = window.id; draftStability = DraftStability() }
        let began = Date()
        let generation = pipelineGeneration
        previewTask = Task {
            defer {
                try? FileManager.default.removeItem(at: window.url)
                previewActive = false; previewTask = nil
                previewCooldown = Date().addingTimeInterval(max(1, Date().timeIntervalSince(began)))
                pump()
            }
            do {
                let text = try await speech.recognize(url: window.url, language: settings.language, localOnly: settings.localRecognition, engine: settings.recognitionEngine)
                guard !Task.isCancelled, generation == pipelineGeneration else { return }
                lastRecognitionAt = Date()
                _ = commitPreview(text, window: window, epoch: epoch)
            } catch {
                // Preview failures never block or delete the journalled final audio.
            }
        }
    }
    @discardableResult func commitPreview(_ text: String, window: SpeechWindow, epoch: UUID) -> Bool {
        guard epoch == captureEpoch, !finalizedWindows.contains(window.id), !text.isEmpty else { return false }
        guard !RepeatedText.containsRun(text) else { return false }
        if draftWindowID != window.id { draftWindowID = window.id; draftStability = DraftStability() }
        draftText = draftStability.update(text)
        draftCaption = Caption(isDraft: true, id: window.id, date: window.date, original: draftText, translated: "")
        capture?.setComplete(MeetingRules.looksComplete(text, language: captureSettings?.language ?? settings.language), id: window.id)
        publishPhone(); return true
    }
    func acceptCapturedAudio(url: URL, date: Date, overlap: Bool, epoch: UUID, settings: AppSettings, id: UUID = UUID(), preview: String? = nil) {
        guard epoch == captureEpoch else { try? FileManager.default.removeItem(at: url); return }
        jobs.append(AudioJob(id: id, sessionID: sessionID, created: date, audioFile: url.lastPathComponent, language: settings.language, localRecognition: settings.localRecognition, targetLanguage: settings.targetLanguage, recognitionEngine: settings.recognitionEngine, previewText: preview, overlap: overlap))
        persist(); publishPhone(); pump()
    }
    @discardableResult func commitRecognition(_ text: String, for id: UUID, generation: Int? = nil) -> Bool {
        guard generation == nil || generation == pipelineGeneration else { return false }
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.deletedAt == nil && $0.stage == .recognize }) else { return false }
        if RepeatedText.containsRun(text) {
            failed(id, error: BridgeError("识别原文出现异常重复。")); return false
        }
        if text.isEmpty, jobs[index].recognitionFailures > 0 || jobs[index].previewText?.isEmpty == false {
            failed(id, error: BridgeError("识别未返回可用文字。")); return false
        }
        jobs[index].original = text
        jobs[index].previewText = nil
        jobs[index].stage = text.isEmpty ? .done : .translate
        jobs[index].attempts = 0; jobs[index].repetitionRetries = nil; jobs[index].error = ""
        if persist() { store?.removeAudio(jobs[index]) }
        publishPhone(); return true
    }
    @discardableResult func commitTranslation(_ text: String, for id: UUID, generation: Int? = nil) -> Bool {
        guard generation == nil || generation == pipelineGeneration else { return false }
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.deletedAt == nil && $0.stage == .translate }) else { return false }
        if RepeatedText.containsRun(text) { recoverRepeatedTranslation(jobID: id); return false }
        jobs[index].translated = text; jobs[index].stage = .done; jobs[index].error = ""
        persist(); publishPhone(); return true
    }
    private func recoverRepeatedTranslation(jobID: UUID) {
        guard !terminating, !isRecoveringPipeline, storageHealthy,
              let index = jobs.firstIndex(where: { $0.id == jobID && $0.deletedAt == nil }) else { return }
        let retries = (jobs[index].translationRepetitionRetries ?? 0) + 1
        jobs[index].translationRepetitionRetries = retries
        jobs[index].retryAfter = Date().addingTimeInterval(2)
        jobs[index].error = "检测到译文异常重复，正在无旧上下文重试。"
        if retries > 1 {
            jobs[index].stage = .blocked
            jobs[index].error = "自动恢复后译文仍出现重复，原文已保留。可稍后点击重试待处理。"
            notice = jobs[index].error; persist(); publishPhone(); return
        }
        isRecoveringPipeline = true; pipelineGeneration += 1; pipelineRecoveryCount += 1
        let generation = pipelineGeneration
        let pendingRecognition = recognitionTask, pendingPreview = previewTask
        let pendingTranslations = Array(translationTasks.values)
        pendingRecognition?.cancel(); pendingPreview?.cancel(); pendingTranslations.forEach { $0.cancel() }
        // New audio keeps its epoch and continues to journal. Only context changes.
        sessionID = UUID()
        for index in jobs.indices where jobs[index].deletedAt == nil && (jobs[index].stage == .recognize || jobs[index].stage == .translate) {
            jobs[index].sessionID = sessionID
        }
        draftStability = DraftStability(); previewCooldown = .distantPast
        notice = "检测到译文异常重复，正在重建识别与翻译任务；收音继续，已有字幕保留。"
        persist(); publishPhone()
        pipelineRecovery = Task {
            await pendingRecognition?.value; await pendingPreview?.value
            for task in pendingTranslations { await task.value }
            guard !Task.isCancelled, !terminating, generation == pipelineGeneration else { return }
            speech.reset()
            do {
                if backgroundWorkEnabled {
                    let configuration = captureSettings ?? settings
                    try await speech.authorize(language: configuration.language, localOnly: configuration.localRecognition, engine: configuration.recognitionEngine)
                    speechAuthorized = true
                }
                guard !Task.isCancelled, !terminating else { return }
                isRecoveringPipeline = false; pipelineRecovery = nil
                notice = "识别与翻译任务已恢复，正在继续处理保留的片段。"
                persist(); publishPhone(); pump()
            } catch {
                isRecoveringPipeline = false; pipelineRecovery = nil; speechAuthorized = false
                notice = "自动恢复暂未完成，音频继续保存：\(error.localizedDescription)"; publishPhone()
            }
        }
    }
    func waitForPipelineRecovery() async { await pipelineRecovery?.value }
    func shutdown() async {
        terminating = true; isRunning = false
        assistantTask?.cancel()
        timer?.invalidate(); captureRetry?.cancel(); pipelineRecovery?.cancel()
        await capture?.stop(); capture = nil
        // Segment callbacks enqueue main-actor jobs; give those jobs a chance to journal.
        await Task.yield()
        previewTask?.cancel(); WhisperEngine.shared.stop()
        persist(); server.stop(); bluetooth.stop()
        if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity); sleepActivity = nil }
    }
    func updateFloatingAppearance() {
        floating?.alphaValue = settings.floatingOpacity
        floating?.level = settings.floatingAlwaysOnTop ? .floating : .normal
        floating?.isFloatingPanel = settings.floatingAlwaysOnTop
        settings.save()
    }
    func setFloating(_ visible: Bool) {
        floatingVisible = visible
        if visible {
            if floating == nil {
                let panel = CaptionPanel(contentRect: NSRect(x: 160, y: 120, width: 720, height: 330), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
                panel.title = "听桥 · 实时字幕"; panel.titleVisibility = .hidden
                panel.titlebarAppearsTransparent = true; panel.isMovableByWindowBackground = true
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.isReleasedWhenClosed = false; panel.minSize = NSSize(width: 560, height: 195)
                panel.contentView = NSHostingView(rootView: FloatingCaptions(model: self))
                let delegate = FloatingWindowDelegate { [weak self] in self?.floatingVisible = false }
                floatingDelegate = delegate; panel.delegate = delegate
                floating = panel
            }
            updateFloatingAppearance(); floating?.makeKeyAndOrderFront(nil)
        } else { floating?.orderOut(nil) }
    }
}
