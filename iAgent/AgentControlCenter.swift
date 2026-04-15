//
//  AgentControlCenter.swift
//  iAgent
//
//  核心协调器，管理所有服务
//  重构后不再依赖 HTTP 服务器，直接协调各 Service
//

import AVFoundation
import Foundation
import Observation

struct AgentConversation: Sendable {
    var user: String
    var assistant: String

    static let empty = AgentConversation(user: "", assistant: "")
}

private enum MicrophonePermissionError: LocalizedError {
    case denied
    case restricted

    var errorDescription: String? {
        switch self {
        case .denied:
            return "未获得麦克风权限，请在系统设置 -> 隐私与安全性 -> 麦克风 中允许 iAgent 访问麦克风"
        case .restricted:
            return "当前设备限制了麦克风访问，iAgent 无法启动语音采集"
        }
    }
}

@MainActor
private final class VoiceCaptureRecoveryController {
    private(set) var hasVoiceCaptureEverStarted = false
    private var isPerformingRecovery = false
    private var isAwaitingFirstListening = false
    private var scheduledRecoveryTask: Task<Void, Never>?
    private let recoveryDelaySeconds: Double

    init(recoveryDelaySeconds: Double = 3) {
        self.recoveryDelaySeconds = recoveryDelaySeconds
    }

    func cancel() {
        scheduledRecoveryTask?.cancel()
        scheduledRecoveryTask = nil
        hasVoiceCaptureEverStarted = false
        isPerformingRecovery = false
        isAwaitingFirstListening = false
    }

    func beginStartup() {
        isAwaitingFirstListening = true
    }

    func cancelScheduledRecovery() {
        scheduledRecoveryTask?.cancel()
        scheduledRecoveryTask = nil
    }

    private var hasScheduledRecovery: Bool {
        scheduledRecoveryTask != nil
    }

    func setTestingState(
        hasCaptureStarted: Bool? = nil,
        isPerformingRecovery: Bool? = nil,
        isAwaitingFirstListening: Bool? = nil
    ) {
        if let hasCaptureStarted {
            self.hasVoiceCaptureEverStarted = hasCaptureStarted
        }
        if let isPerformingRecovery {
            self.isPerformingRecovery = isPerformingRecovery
        }
        if let isAwaitingFirstListening {
            self.isAwaitingFirstListening = isAwaitingFirstListening
        }
    }

    func statusMessage(for state: VoiceService.State) -> String {
        switch state {
        case .idle:
            return "VAD 待机"
        case .listening:
            return "VAD 监听中"
        case .speaking:
            return "VAD 语音检测"
        case .processing:
            return "VAD 处理中"
        }
    }

    func handleVoiceState(
        _ state: VoiceService.State,
        health: AgentControlCenter.ServiceHealth,
        statusUpdater: (String) -> Void,
        recoveryTrigger: @escaping @MainActor (String) async -> Void
    ) {
        switch state {
        case .idle:
            if isAwaitingFirstListening {
                statusUpdater("启动语音采集")
                return
            }
            if isPerformingRecovery || hasScheduledRecovery {
                return
            }
            statusUpdater(statusMessage(for: state))
            if health == .healthy, hasVoiceCaptureEverStarted, !isPerformingRecovery {
                scheduleRecovery(reason: "采集已停止", health: health, statusUpdater: statusUpdater, recoveryTrigger: recoveryTrigger)
            }
        case .listening, .speaking, .processing:
            cancelScheduledRecovery()
            isAwaitingFirstListening = false
            hasVoiceCaptureEverStarted = true
            statusUpdater(statusMessage(for: state))
        }
    }

    func handleVoiceError(
        _ message: String,
        health: AgentControlCenter.ServiceHealth,
        statusUpdater: (String) -> Void,
        recoveryTrigger: @escaping @MainActor (String) async -> Void
    ) {
        guard health == .healthy || health == .starting else { return }
        statusUpdater("采集异常: \(message)")
        guard shouldAutoRecover(from: message) else { return }
        scheduleRecovery(reason: "采集异常", health: health, statusUpdater: statusUpdater, recoveryTrigger: recoveryTrigger)
    }

    func scheduleRetry(
        reason: String,
        health: AgentControlCenter.ServiceHealth,
        statusUpdater: (String) -> Void,
        recoveryTrigger: @escaping @MainActor (String) async -> Void
    ) {
        scheduleRecovery(reason: reason, health: health, statusUpdater: statusUpdater, recoveryTrigger: recoveryTrigger)
    }

    func performRecovery(
        reason: String,
        body: @escaping @MainActor () async throws -> Void,
        statusUpdater: (String) -> Void,
        retryTrigger: @escaping @MainActor (String) -> Void
    ) async {
        scheduledRecoveryTask = nil
        isPerformingRecovery = true
        defer { isPerformingRecovery = false }

        isAwaitingFirstListening = true
        statusUpdater("恢复语音采集")

        do {
            try await body()
            statusUpdater("启动语音采集")
        } catch {
            isAwaitingFirstListening = false
            statusUpdater("采集恢复失败: \(error.localizedDescription)")
            retryTrigger("采集恢复失败")
        }
    }

    private func shouldAutoRecover(from message: String) -> Bool {
        let recoverableSignals = [
            "持续检测到零能量音频",
            "ffmpeg 启动失败",
            "ffmpeg 进程意外退出",
            "读取音频帧失败",
            "未找到 ffmpeg"
        ]
        return recoverableSignals.contains { message.contains($0) }
    }

    private func scheduleRecovery(
        reason: String,
        health: AgentControlCenter.ServiceHealth,
        statusUpdater: (String) -> Void,
        recoveryTrigger: @escaping @MainActor (String) async -> Void
    ) {
        guard health == .healthy else { return }
        guard scheduledRecoveryTask == nil else { return }

        statusUpdater("\(reason)，\(Int(recoveryDelaySeconds))秒后自动重试")
        print("[VoiceCaptureRecoveryController] \(reason)，计划自动恢复采集")

        scheduledRecoveryTask = Task { [recoveryDelaySeconds] in
            do {
                try await Task.sleep(for: .seconds(recoveryDelaySeconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await recoveryTrigger(reason)
        }
    }
}

@MainActor
@Observable
final class AgentControlCenter {
    static let shared = AgentControlCenter()

    // MARK: - 状态枚举

    enum ServiceHealth: String, Sendable {
        case stopped
        case starting
        case healthy
        case unreachable

        var title: String {
            switch self {
            case .stopped: return "已停止"
            case .starting: return "启动中"
            case .healthy: return "运行中"
            case .unreachable: return "不可达"
            }
        }
    }

    struct TestHooks {
        var requestMicrophoneAccess: (@Sendable () async -> Bool)? = nil
        var transcribeAudio: (@Sendable (Data) async throws -> String)?
        var executeAgent: (@Sendable (String) async throws -> AgentService.Response)?
        var synthesizeText: (@Sendable (String) async throws -> Data)?
        var playAudio: (@Sendable (Data, Bool) async throws -> Void)?
        var pauseVoiceCaptureForTurnProcessing: (@Sendable () async -> Void)? = nil
        var resumeVoiceCaptureAfterTurnProcessing: (@Sendable () async throws -> Void)? = nil
        var pauseVoiceCaptureForPlayback: (@Sendable () async -> Void)? = nil
        var resumeVoiceCaptureAfterPlayback: (@Sendable () async throws -> Void)? = nil
    }

    // MARK: - UI 绑定属性

    var health: ServiceHealth = .stopped
    var isPlaying = false
    var latestConversation = AgentConversation.empty
    var runtimeDescription = "本地服务"
    var statusMessage = "等待启动"
    var autoSpeak = true
    var lastRefresh: Date?

    // MARK: - 服务实例

    private let voiceService = VoiceService()
    private let asrService = ASRService()
    private let ttsService = TTSService()
    private let agentService = AgentService()
    private let behaviorService = BehaviorService()
    private let playbackService = PlaybackService()
    private let conversationMemory = ConversationMemory()

    // MARK: - 内部状态

    private var voiceTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var stateObserverTask: Task<Void, Never>?
    private var playbackObserverTask: Task<Void, Never>?
    private var voiceErrorObserverTask: Task<Void, Never>?
    private var behaviorObserverTask: Task<Void, Never>?
    private let voiceRecoveryController = VoiceCaptureRecoveryController()
    private var isProcessingVoiceTurn = false
    private var isProcessingBehaviorTurn = false
    private var isRestartingVoiceCaptureAfterTurnProcessing = false
    private var isRestartingVoiceCaptureAfterPlayback = false
    private var deviceSwitchStatusResetTask: Task<Void, Never>?
    var testHooks: TestHooks?
#if DEBUG
    private var requiredAgentExecutableNameOverrideForTesting: String?
    private var voiceRecoveryAttemptHookForTesting: ((String) -> Void)?
#endif

    // MARK: - 计算属性

    var isServiceRunning: Bool {
        health == .healthy || health == .starting
    }

    var menuBarSymbolName: String {
        if health == .starting {
            return "bolt.horizontal.circle"
        }
        if isPlaying {
            return "speaker.wave.2.fill"
        }
        switch health {
        case .healthy:
            return "mic.fill"
        case .unreachable:
            return "exclamationmark.triangle.fill"
        case .stopped:
            return "mic"
        case .starting:
            return "bolt.horizontal.circle"
        }
    }

    var compactStatusText: String {
        if health == .starting { return "启动中" }
        if health == .stopped { return "已停止" }

        let status = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.isEmpty {
            return health == .healthy ? "待命中" : "待机"
        }

        // 只有真正在恢复时才显示"恢复中"，预告重试不显示
        if status == "恢复语音采集" || status.hasPrefix("采集恢复失败") {
            return "恢复中"
        }
        if isPlaying {
            return "播报中"
        }

        // 前缀 → 显示文本 映射表
        let prefixMap: [(prefix: String, display: String)] = [
            ("启动失败", "启动失败"),
            ("ASR 未识别", "没听清楚，请再说一次"),
            ("ASR 转写失败", "异常"),
            ("Agent 执行失败", "异常"),
            ("TTS 播放失败", "异常"),
            ("处理失败", "异常"),
            ("采集异常", "异常"),
            ("采集设备未就绪", "设备未就绪"),
            ("TTS 播放中", "播报中"),
            ("Agent 处理中", "AI思考中"),
            ("ASR 设备识别中", "语音识别中"),
            ("ASR 转写中", "语音识别中"),
            ("VAD 语音检测", "语音识别中"),
            ("VAD 处理中", "语音识别中"),
            ("VAD 监听中", "倾听中"),
            ("VAD 待机", "倾听中"),
        ]

        for (prefix, display) in prefixMap {
            if status.hasPrefix(prefix) { return display }
        }

        return status  // Fallback
    }

    // MARK: - 生命周期

    func bootstrap() {
        _ = Configuration.reload()
        updateRuntimeDescription()
        // 默认自动启动服务
        Task {
            await startService()
            startMonitoring()
            await refreshStatus()
        }
    }

    func startService() async {
        guard health != .healthy && health != .starting else { return }
        voiceRecoveryController.cancel()
        voiceRecoveryController.beginStartup()

        health = .starting
        statusMessage = "服务启动中"
        updateRuntimeDescription()
        print("[AgentControlCenter] 开始启动服务...")

        do {
            _ = Configuration.reload()
            try await ensureMicrophoneAccess()
            try validateRuntimeDependencies()
            try applyConfiguredAudioDevicePreferencesIfNeeded()
            await behaviorService.stopMonitoring(clearContext: false)
            await behaviorService.startMonitoring()
            print("[AgentControlCenter] 依赖验证通过")

            // 先订阅状态流，避免错过 startListening 触发的首个 listening 事件
            startStateObserver()
            startPlaybackObserver()
            startVoiceErrorObserver()
            startBehaviorObserver()

            // 启动语音监听
            try await voiceService.startListening()
            print("[AgentControlCenter] 语音采集任务已提交，等待设备就绪")

            // 启动片段处理任务
            startSegmentProcessing()

            print("[AgentControlCenter] 服务启动完成，等待首个监听状态")
        } catch {
            health = .unreachable
            statusMessage = "启动失败: \(error.localizedDescription)"
            print("[AgentControlCenter] 启动失败: \(error)")
        }

        lastRefresh = Date()
    }

    func stopService() async {
        voiceRecoveryController.cancel()
        monitoringTask?.cancel()
        monitoringTask = nil
        stateObserverTask?.cancel()
        stateObserverTask = nil
        playbackObserverTask?.cancel()
        playbackObserverTask = nil
        voiceErrorObserverTask?.cancel()
        voiceErrorObserverTask = nil
        behaviorObserverTask?.cancel()
        behaviorObserverTask = nil
        voiceTask?.cancel()
        voiceTask = nil

        await behaviorService.stopMonitoring(clearContext: true)
        await voiceService.stopListening()
        await playbackService.stop()

        health = .stopped
        isPlaying = false
        statusMessage = "服务已停止"
        lastRefresh = Date()
    }

    func toggleService() {
        Task {
            if isServiceRunning {
                await stopService()
            } else {
                await startService()
            }
        }
    }

    func behaviorDiagnosticsSnapshot() async -> BehaviorService.DiagnosticsSnapshot {
        await behaviorService.diagnosticsSnapshot()
    }

    func availableInputDevices() -> [AudioInputDeviceManager.InputDevice] {
        (try? AudioInputDeviceManager.inputDevices()) ?? []
    }

    func availableOutputDevices() -> [AudioInputDeviceManager.OutputDevice] {
        (try? AudioInputDeviceManager.outputDevices()) ?? []
    }

    func selectInputDevice(uid: String) async throws {
        let devices = try AudioInputDeviceManager.inputDevices()
        guard let target = devices.first(where: { $0.uid == uid }) else {
            throw AudioInputDeviceManager.DeviceError.deviceNotFound(uid)
        }

        try AudioInputDeviceManager.setDefaultInputDevice(uid: uid)
        Configuration.updateClientInputDeviceIndex(uid)
        _ = Configuration.reload()
        updateRuntimeDescription()

        try await rebuildAudioDevicesIfNeeded()

        statusMessage = "麦克风已切换: \(target.name)"
        scheduleDeviceSwitchStatusReset()
        print("[AgentControlCenter] 麦克风已切换: \(target.name), uid=\(uid)")
    }

    func selectOutputDevice(uid: String) async throws {
        let devices = try AudioInputDeviceManager.outputDevices()
        guard let target = devices.first(where: { $0.uid == uid }) else {
            throw AudioInputDeviceManager.DeviceError.outputDeviceNotFound(uid)
        }

        try AudioInputDeviceManager.setDefaultOutputDevice(uid: uid)
        Configuration.updateClientOutputDeviceUID(uid)
        _ = Configuration.reload()
        updateRuntimeDescription()

        try await rebuildAudioDevicesIfNeeded()

        statusMessage = "扬声器已切换: \(target.name)"
        scheduleDeviceSwitchStatusReset()
        print("[AgentControlCenter] 扬声器已切换: \(target.name), uid=\(uid)")
    }

    func stopPlayback() {
        Task {
            await playbackService.stop()
            isPlaying = false
            statusMessage = "播放已停止"
        }
    }

    func refreshStatus() async {
        // 播放状态由 playbackService.stateStream 事件驱动更新
        updateRuntimeDescription()
        lastRefresh = Date()
    }

    // MARK: - 私有方法

    func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func validateRuntimeDependencies() throws {
        let agentExecutableName = requiredAgentExecutableName
        guard ExecutableLocator.isAvailable(agentExecutableName) else {
            throw AgentError.executableNotFound(agentExecutableName)
        }
    }

    private func ensureMicrophoneAccess() async throws {
#if DEBUG
        if let requestMicrophoneAccess = testHooks?.requestMicrophoneAccess {
            guard await requestMicrophoneAccess() else {
                throw MicrophonePermissionError.denied
            }
            return
        }
#endif

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
            guard granted else {
                throw MicrophonePermissionError.denied
            }
        case .denied:
            throw MicrophonePermissionError.denied
        case .restricted:
            throw MicrophonePermissionError.restricted
        @unknown default:
            throw MicrophonePermissionError.denied
        }
    }

    private func updateRuntimeDescription() {
        let agentPath = ExecutableLocator.find(requiredAgentExecutableName) ?? "missing"
        let microphoneName = ((try? AudioInputDeviceManager.inputDevices())?
            .first(where: \.isDefault)?
            .name) ?? "系统默认"
        let speakerName = ((try? AudioInputDeviceManager.outputDevices())?
            .first(where: \.isDefault)?
            .name) ?? "系统默认"
        runtimeDescription = "claude: \(agentPath) | mic: \(microphoneName) | spk: \(speakerName)"
    }

    private func applyConfiguredAudioDevicePreferencesIfNeeded() throws {
        let configuredValue = Configuration.shared.client.inputDeviceIndex
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredValue.isEmpty, configuredValue != "0", configuredValue.lowercased() != "auto" {
            let currentDefaultUID = try AudioInputDeviceManager.defaultInputDeviceUID()
            if currentDefaultUID != configuredValue {
                try AudioInputDeviceManager.setDefaultInputDevice(uid: configuredValue)
            }
        }

        let configuredOutputUID = Configuration.shared.client.outputDeviceUID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredOutputUID.isEmpty {
            let currentOutputUID = try AudioInputDeviceManager.defaultOutputDeviceUID()
            if currentOutputUID != configuredOutputUID {
                try AudioInputDeviceManager.setDefaultOutputDevice(uid: configuredOutputUID)
            }
        }
    }

    private func rebuildAudioDevicesIfNeeded() async throws {
        guard isServiceRunning else { return }

        await playbackService.stop()
        await voiceService.stopListening()
        try await voiceService.startListening()
    }

    private func scheduleDeviceSwitchStatusReset() {
        deviceSwitchStatusResetTask?.cancel()
        deviceSwitchStatusResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // 只有当前状态仍是设备切换消息时才重置，避免覆盖其他状态
                let current = self?.statusMessage ?? ""
                if current.hasPrefix("麦克风已切换") || current.hasPrefix("扬声器已切换") {
                    self?.statusMessage = "VAD 监听中"
                }
            }
        }
    }

    private var requiredAgentExecutableName: String {
#if DEBUG
        if let override = requiredAgentExecutableNameOverrideForTesting {
            return override
        }
#endif
        return AgentService.executableName
    }

    private func startStateObserver() {
        stateObserverTask?.cancel()
        stateObserverTask = Task { [weak self] in
            guard let self = self else { return }
            for await state in voiceService.stateStream {
                self.handleVoiceState(state)
            }
        }
    }

    private func startPlaybackObserver() {
        playbackObserverTask?.cancel()
        playbackObserverTask = Task { [weak self] in
            guard let self = self else { return }
            for await state in playbackService.stateStream {
                await self.voiceService.setPlaybackActive(state == .playing)
                await MainActor.run {
                    self.handlePlaybackState(state)
                }
            }
        }
    }

    private func startVoiceErrorObserver() {
        voiceErrorObserverTask?.cancel()
        voiceErrorObserverTask = Task { [weak self] in
            guard let self = self else { return }
            for await message in voiceService.errorStream {
                if self.health == .starting {
                    self.voiceRecoveryController.cancel()
                    self.health = .unreachable
                    self.statusMessage = "采集异常: \(message)"
                    print("[AgentControlCenter] 采集启动失败: \(message)")
                    await self.voiceService.stopListening()
                    continue
                }
                self.voiceRecoveryController.handleVoiceError(
                    message,
                    health: self.health,
                    statusUpdater: { self.statusMessage = $0 },
                    recoveryTrigger: { [weak self] reason in
                        await self?.attemptVoiceRecovery(reason: reason)
                    }
                )
            }
        }
    }

    private func startBehaviorObserver() {
        behaviorObserverTask?.cancel()
        behaviorObserverTask = Task { [weak self] in
            guard let self else { return }
            let stream = await behaviorService.contextEventStream()
            for await context in stream {
                guard !Task.isCancelled else { return }
                try? await self.handleBehaviorContextTrigger(context)
            }
        }
    }

    private func startSegmentProcessing() {
        voiceTask?.cancel()
        voiceTask = Task { [weak self] in
            guard let self = self else { return }
            for await segment in voiceService.segmentStream {
                await self.processVoiceSegment(segment)
            }
        }
    }

    private func handleVoiceState(_ state: VoiceService.State) {
        print("[AgentControlCenter] 收到语音状态: \(state)")
        guard health != .unreachable else { return }
        if health == .starting, state != .idle {
            health = .healthy
        }
        if (isRestartingVoiceCaptureAfterPlayback || isRestartingVoiceCaptureAfterTurnProcessing),
           state == .idle
        {
            let reason = isRestartingVoiceCaptureAfterPlayback ? "播报后" : "处理完成后"
            print("[AgentControlCenter] 忽略\(reason)重启采集产生的 idle 状态")
            return
        }
        let shouldPublishStatus = shouldPublishCaptureStatus(for: state)
        voiceRecoveryController.handleVoiceState(
            state,
            health: health,
            statusUpdater: { [weak self] message in
                guard let self else { return }
                if shouldPublishStatus {
                    self.statusMessage = message
                }
            },
            recoveryTrigger: { [weak self] reason in
                await self?.attemptVoiceRecovery(reason: reason)
            }
        )

        if isRestartingVoiceCaptureAfterTurnProcessing, state == .listening {
            isRestartingVoiceCaptureAfterTurnProcessing = false
            print("[AgentControlCenter] 处理完成后采集已恢复")
        }
        if isRestartingVoiceCaptureAfterPlayback, state == .listening {
            isRestartingVoiceCaptureAfterPlayback = false
            print("[AgentControlCenter] 播报后采集已恢复")
        }
    }

    private func attemptVoiceRecovery(reason: String) async {
        guard health == .healthy else { return }

        print("[AgentControlCenter] 开始恢复采集，原因: \(reason)")
#if DEBUG
        voiceRecoveryAttemptHookForTesting?(reason)
#endif

        await voiceRecoveryController.performRecovery(
            reason: reason,
            body: { [voiceService] in
                await voiceService.stopListening()
                try await voiceService.startListening()
            },
            statusUpdater: { self.statusMessage = $0 },
            retryTrigger: { [weak self] retryReason in
                self?.voiceRecoveryController.scheduleRetry(
                    reason: retryReason,
                    health: self?.health ?? .stopped,
                    statusUpdater: { self?.statusMessage = $0 },
                    recoveryTrigger: { [weak self] reason in
                        await self?.attemptVoiceRecovery(reason: reason)
                    }
                )
            }
        )
        if statusMessage == "麦克风监听中" {
            print("[AgentControlCenter] 采集恢复成功")
        }
    }

    private func handlePlaybackState(_ state: PlaybackService.State) {
        let wasPlaying = isPlaying
        isPlaying = (state == .playing)

        if state == .idle, wasPlaying, health == .healthy, statusMessage == "TTS 播放中" {
            statusMessage = "TTS 空闲"
        }
    }

    private func processVoiceSegment(_ segment: VoiceService.VoiceSegment) async {
        let segmentStart = Date()
        let audioData = segment.audioData
        print("[AgentControlCenter] 收到语音片段，bytes=\(audioData.count)")
        isProcessingVoiceTurn = true
        await voiceService.setSpeechDetectionSuspended(true)
        var turnDidThrow = false
        defer {
            Task { [weak self] in
                await self?.voiceService.setSpeechDetectionSuspended(false, cooldownSeconds: 0.8)
            }
            isProcessingVoiceTurn = false
            if !turnDidThrow {
                self.statusMessage = "VAD 监听中"
            }
        }
        statusMessage = "ASR 设备识别中"

        do {
            let inputDevice = segment.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inputDevice.isEmpty else {
                statusMessage = "采集设备未就绪"
                voiceRecoveryController.scheduleRetry(
                    reason: "采集设备未就绪",
                    health: health,
                    statusUpdater: { self.statusMessage = $0 },
                    recoveryTrigger: { [weak self] reason in
                        await self?.attemptVoiceRecovery(reason: reason)
                    }
                )
                print("[AgentControlCenter] 跳过ASR：采集设备未就绪")
                return
            }
            print("[AgentControlCenter] 设备识别完成，当前采集设备: \(inputDevice)")

            statusMessage = "ASR 转写中"
            let asrStart = Date()
            let transcript = try await transcribeAudioData(audioData)
            let asrElapsed = Date().timeIntervalSince(asrStart)
            print(
                "[AgentControlCenter] ASR 完成，耗时=\(String(format: "%.2f", asrElapsed))s, " +
                "text_len=\(transcript.count), text=\(formatLogText(transcript))"
            )

            try await processTranscript(
                transcript,
                shouldAutoSpeak: autoSpeak
            )
            let totalElapsed = Date().timeIntervalSince(segmentStart)
            print("[AgentControlCenter] 语音片段处理完成，总耗时=\(String(format: "%.2f", totalElapsed))s")
        } catch {
            turnDidThrow = true
            if !statusMessage.hasPrefix("ASR 转写失败")
                && !statusMessage.hasPrefix("ASR 未识别")
                && !statusMessage.hasPrefix("Agent 执行失败")
                && !statusMessage.hasPrefix("TTS 播放失败") {
                statusMessage = "处理失败: \(error.localizedDescription)"
            }
            print("[AgentControlCenter] 语音片段处理失败: \(error)")
        }
    }

    private func processTranscript(
        _ transcript: String,
        shouldAutoSpeak: Bool
    ) async throws {
        latestConversation = AgentConversation(user: transcript, assistant: "")
        statusMessage = "Agent 处理中"
        let agentStart = Date()
        let response: AgentService.Response
        do {
            response = try await executeAgent(text: transcript)
        } catch {
            statusMessage = "Agent 执行失败: \(error.localizedDescription)"
            throw error
        }
        let agentElapsed = Date().timeIntervalSince(agentStart)
        print(
            "[AgentControlCenter] Agent 完成，耗时=\(String(format: "%.2f", agentElapsed))s, " +
            "reply_len=\(response.replyText.count), reply=\(formatLogText(response.replyText))"
        )

        latestConversation = AgentConversation(user: transcript, assistant: response.replyText)
        await conversationMemory.addTurn(user: transcript, assistant: response.replyText)

        if shouldAutoSpeak {
            do {
                try await speakTextInternal(response.replyText)
            } catch {
                statusMessage = "TTS 播放失败: \(error.localizedDescription)"
                throw error
            }
        }
    }

    private func handleBehaviorContextTrigger(_ context: BehaviorService.Context) async throws {
        guard health == .healthy else { return }
        guard !isProcessingVoiceTurn else { return }
        guard !isProcessingBehaviorTurn else { return }

        let behaviorContext = await behaviorService.consumePromptContextIfAvailable()
        guard let behaviorContext else { return }

        isProcessingBehaviorTurn = true
        await voiceService.setSpeechDetectionSuspended(true)
        defer {
            Task { [weak self] in
                await self?.voiceService.setSpeechDetectionSuspended(false, cooldownSeconds: 2.5)
            }
            isProcessingBehaviorTurn = false
            // 取消任何待处理的恢复，确保状态不会被恢复逻辑覆盖
            voiceRecoveryController.cancel()
            // 播报完成后直接重置为倾听中
            self.statusMessage = "VAD 监听中"
        }

        let displayText = "飞哥回来了"
        let proactivePrompt = "请主动和飞哥打个招呼，欢迎他回家。"

        latestConversation = AgentConversation(user: displayText, assistant: "")
        statusMessage = "Agent 处理中"

        let response: AgentService.Response
        do {
            response = try await executeAgent(text: proactivePrompt, behaviorContextOverride: behaviorContext)
        } catch {
            statusMessage = "Agent 执行失败: \(error.localizedDescription)"
            throw error
        }

        latestConversation = AgentConversation(user: displayText, assistant: response.replyText)
        await conversationMemory.addTurn(user: displayText, assistant: response.replyText)

        do {
            try await speakTextInternal(response.replyText)
        } catch {
            statusMessage = "TTS 播放失败: \(error.localizedDescription)"
            throw error
        }

        print("[AgentControlCenter] 行为触发播报完成，scene=\(context.scene.rawValue), source=\(context.source)")
    }

    private func speakTextInternal(_ text: String) async throws {
        statusMessage = "TTS 播放中"
        print("[AgentControlCenter] 开始播报，text=\(formatLogText(text))")

        let ttsStart = Date()
        let audioData = try await synthesizeSpeech(text)
        let ttsElapsed = Date().timeIntervalSince(ttsStart)
        print("[AgentControlCenter] TTS 完成，耗时=\(String(format: "%.2f", ttsElapsed))s, bytes=\(audioData.count)")

        let playStart = Date()
        try await playAudioData(audioData, interrupt: true)
        try await playbackService.waitUntilFinished()
        let playElapsed = Date().timeIntervalSince(playStart)
        print("[AgentControlCenter] Playback 请求完成，耗时=\(String(format: "%.2f", playElapsed))s")

        let stillPlaying = await playbackService.isPlaying
        if !stillPlaying {
            statusMessage = "TTS 空闲"
        }
    }

    private func pauseVoiceCaptureForTurnProcessing() async {
        if let handler = testHooks?.pauseVoiceCaptureForTurnProcessing {
            isRestartingVoiceCaptureAfterTurnProcessing = true
            await handler()
            return
        }
        isRestartingVoiceCaptureAfterTurnProcessing = true
        await voiceService.setSpeechDetectionSuspended(true)
    }

    private func resumeVoiceCaptureAfterTurnProcessing() async throws {
        if let handler = testHooks?.resumeVoiceCaptureAfterTurnProcessing {
            try await handler()
            isRestartingVoiceCaptureAfterTurnProcessing = false
            return
        }
        isRestartingVoiceCaptureAfterTurnProcessing = false
        await voiceService.setSpeechDetectionSuspended(false, cooldownSeconds: 0.8)
    }

    private func pauseVoiceCaptureForPlayback() async {
        if let handler = testHooks?.pauseVoiceCaptureForPlayback {
            isRestartingVoiceCaptureAfterPlayback = true
            await handler()
            return
        }
        isRestartingVoiceCaptureAfterPlayback = true
        await voiceService.setSpeechDetectionSuspended(true)
    }

    private func resumeVoiceCaptureAfterPlayback() async throws {
        if let handler = testHooks?.resumeVoiceCaptureAfterPlayback {
            try await handler()
            isRestartingVoiceCaptureAfterPlayback = false
            return
        }
        isRestartingVoiceCaptureAfterPlayback = false
        await voiceService.setSpeechDetectionSuspended(false, cooldownSeconds: 2.5)
    }

    private func transcribeAudioData(_ audioData: Data) async throws -> String {
        do {
            if let handler = testHooks?.transcribeAudio {
                return try await handler(audioData)
            }
            return try await asrService.transcribe(audioData: audioData, format: .pcm)
        } catch let error as ASRError {
            switch error {
            case .noResult:
                await voiceService.setSpeechDetectionSuspended(false, cooldownSeconds: 2.0)
                statusMessage = "ASR 未识别到有效语音"
            default:
                statusMessage = "ASR 转写失败: \(error.localizedDescription)"
            }
            throw error
        } catch {
            statusMessage = "ASR 转写失败: \(error.localizedDescription)"
            throw error
        }
    }

    private func executeAgent(
        text: String,
        behaviorContextOverride: String? = nil
    ) async throws -> AgentService.Response {
        if let handler = testHooks?.executeAgent {
            return try await handler(text)
        }
        let behaviorContext: String?
        if let behaviorContextOverride {
            behaviorContext = behaviorContextOverride
        } else {
            behaviorContext = await behaviorService.consumePromptContextIfAvailable()
        }
        return try await agentService.execute(
            prompt: buildAgentPrompt(userText: text, behaviorContext: behaviorContext)
        )
    }

    private func synthesizeSpeech(_ text: String) async throws -> Data {
        if let handler = testHooks?.synthesizeText {
            return try await handler(text)
        }
        return try await ttsService.synthesize(text: text)
    }

    private func playAudioData(_ data: Data, interrupt: Bool) async throws {
        if let handler = testHooks?.playAudio {
            try await handler(data, interrupt)
            return
        }
        try await playbackService.play(data: data, interrupt: interrupt)
    }

    private func shouldPublishCaptureStatus(for state: VoiceService.State) -> Bool {
        switch state {
        case .processing, .speaking:
            return false
        case .listening:
            if isProcessingVoiceTurn || isProcessingBehaviorTurn {
                return false
            }
            let currentStatus = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            let blockedPrefixes = [
                "VAD 语音检测",
                "ASR 设备识别中",
                "ASR 转写中",
                "ASR 未识别",
                "ASR 转写失败",
                "处理失败",
                "Agent 处理中",
                "Agent 响应:"
            ]
            return !blockedPrefixes.contains { currentStatus.hasPrefix($0) }
        case .idle:
            return true
        }
    }

    private func formatLogText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

#if DEBUG
    func _setTestHooksForTesting(_ hooks: TestHooks?) {
        testHooks = hooks
    }

    func _processTranscriptForTesting(_ transcript: String, shouldAutoSpeak: Bool) async throws {
        try await processTranscript(
            transcript,
            shouldAutoSpeak: shouldAutoSpeak
        )
    }

    func _processVoiceSegmentForTesting(_ segment: VoiceService.VoiceSegment) async {
        await processVoiceSegment(segment)
    }

    func _processVoiceSegmentForTesting(_ audioData: Data) async {
        let segment = VoiceService.VoiceSegment(
            deviceID: "test-device",
            audioData: audioData,
            capturedAt: Date()
        )
        await processVoiceSegment(segment)
    }

    func _getConversationTurnsForTesting() async -> [Turn] {
        await conversationMemory.getTurns()
    }

    func _validateRuntimeDependenciesForTesting() throws {
        try validateRuntimeDependencies()
    }

    func _handleVoiceStateForTesting(_ state: VoiceService.State) {
        handleVoiceState(state)
    }

    func _handlePlaybackStateForTesting(_ state: PlaybackService.State) {
        handlePlaybackState(state)
    }

    func _transcribeAudioDataForTesting(_ data: Data) async throws -> String {
        try await transcribeAudioData(data)
    }

    func _executeAgentForTesting(_ text: String) async throws -> AgentService.Response {
        try await executeAgent(text: text)
    }

    func _simulateBehaviorTriggerForTesting(_ message: String) async throws {
        let now = Date()
        await behaviorService._setActiveContextForTesting(
            .init(
                scene: .arrivedHome,
                message: message,
                source: "testing",
                detectedAt: now,
                expiresAt: now.addingTimeInterval(600)
            )
        )
        try await handleBehaviorContextTrigger(
            .init(
                scene: .arrivedHome,
                message: message,
                source: "testing",
                detectedAt: now,
                expiresAt: now.addingTimeInterval(600)
            )
        )
    }

    func _synthesizeSpeechForTesting(_ text: String) async throws -> Data {
        try await synthesizeSpeech(text)
    }

    func _playAudioDataForTesting(_ data: Data, interrupt: Bool) async throws {
        try await playAudioData(data, interrupt: interrupt)
    }

    func _setRequiredAgentExecutableNameOverrideForTesting(_ name: String?) {
        requiredAgentExecutableNameOverrideForTesting = name
    }

    func _setVoiceRecoveryAttemptHookForTesting(_ hook: ((String) -> Void)?) {
        voiceRecoveryAttemptHookForTesting = hook
    }

    func _setRestartingVoiceCaptureAfterPlaybackForTesting(_ value: Bool) {
        isRestartingVoiceCaptureAfterPlayback = value
    }

    func _setRestartingVoiceCaptureAfterTurnProcessingForTesting(_ value: Bool) {
        isRestartingVoiceCaptureAfterTurnProcessing = value
    }

    func _setBehaviorContextMessageForTesting(_ message: String?) async {
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let now = Date()
            await behaviorService._setActiveContextForTesting(
                .init(
                    scene: .arrivedHome,
                    message: message,
                    source: "testing",
                    detectedAt: now,
                    expiresAt: now.addingTimeInterval(600)
                )
            )
        } else {
            await behaviorService._setActiveContextForTesting(nil)
        }
    }

    func _buildPromptForTesting(_ text: String) async -> String {
        let behaviorContext = await behaviorService.consumePromptContextIfAvailable()
        return buildAgentPrompt(userText: text, behaviorContext: behaviorContext)
    }

    func _setBehaviorDiagnosticsForTesting(summary: String, signalSummary: String, eventLines: [String]) async {
        await behaviorService._setDiagnosticsForTesting(
            summary: summary,
            signalSummary: signalSummary,
            eventLines: eventLines
        )
    }

    func _startVoiceErrorObserverForTesting() {
        startVoiceErrorObserver()
    }

    func _startSegmentProcessingForTesting() {
        startSegmentProcessing()
    }

    func _emitVoiceErrorForTesting(_ message: String) async {
        await voiceService._emitErrorForTesting(message)
    }

    func _emitVoiceSegmentForTesting(_ audioData: Data) async {
        let segment = VoiceService.VoiceSegment(
            deviceID: "test-device",
            audioData: audioData,
            capturedAt: Date()
        )
        await voiceService._emitSegmentForTesting(segment)
    }

    func _setHealthForTesting(_ health: ServiceHealth) {
        self.health = health
    }

    func _setHasVoiceCaptureEverStartedForTesting(_ hasStarted: Bool) {
        voiceRecoveryController.setTestingState(hasCaptureStarted: hasStarted)
    }

    func _setVoiceStartupPendingForTesting(_ isPending: Bool) {
        voiceRecoveryController.setTestingState(isAwaitingFirstListening: isPending)
    }

    func _setIsPerformingVoiceRecoveryForTesting(_ isPerforming: Bool) {
        voiceRecoveryController.setTestingState(isPerformingRecovery: isPerforming)
    }
#endif
}
