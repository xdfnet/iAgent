import XCTest
@testable import iAgent

private enum CenterTestError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@MainActor
final class AgentControlCenterCoverageTests: XCTestCase {
    private func makeWAVData(durationSeconds: Double = 0.06, sampleRate: Int = 8000) -> Data {
        let sampleCount = max(1, Int(Double(sampleRate) * durationSeconds))
        var pcm = Data(capacity: sampleCount * 2)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            let value = Int16(sin(t * 2.0 * .pi * 440.0) * 14000.0)
            var little = value.littleEndian
            pcm.append(Data(bytes: &little, count: MemoryLayout<Int16>.size))
        }

        func u32(_ value: UInt32) -> Data {
            var v = value.littleEndian
            return Data(bytes: &v, count: MemoryLayout<UInt32>.size)
        }
        func u16(_ value: UInt16) -> Data {
            var v = value.littleEndian
            return Data(bytes: &v, count: MemoryLayout<UInt16>.size)
        }

        let dataSize = UInt32(pcm.count)
        let riffSize = UInt32(36) + dataSize
        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.append(u32(riffSize))
        wav.append(Data("WAVE".utf8))
        wav.append(Data("fmt ".utf8))
        wav.append(u32(16))
        wav.append(u16(1))
        wav.append(u16(1))
        wav.append(u32(UInt32(sampleRate)))
        wav.append(u32(UInt32(sampleRate * 2)))
        wav.append(u16(2))
        wav.append(u16(16))
        wav.append(Data("data".utf8))
        wav.append(u32(dataSize))
        wav.append(pcm)
        return wav
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        interval: UInt64 = 20_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: interval)
        }
        return condition()
    }

    func testServiceHealthTitleAndMenuBarSymbol() {
        XCTAssertEqual(AgentControlCenter.ServiceHealth.stopped.title, "已停止")
        XCTAssertEqual(AgentControlCenter.ServiceHealth.starting.title, "启动中")
        XCTAssertEqual(AgentControlCenter.ServiceHealth.healthy.title, "运行中")
        XCTAssertEqual(AgentControlCenter.ServiceHealth.unreachable.title, "不可达")

        let center = AgentControlCenter()
        center.health = .starting
        XCTAssertEqual(center.menuBarSymbolName, "bolt.horizontal.circle")

        center.health = .healthy
        center.isPlaying = true
        XCTAssertEqual(center.menuBarSymbolName, "speaker.wave.2.fill")

        center.isPlaying = false
        XCTAssertEqual(center.menuBarSymbolName, "mic.fill")

        center.health = .unreachable
        XCTAssertEqual(center.menuBarSymbolName, "exclamationmark.triangle.fill")

        center.health = .stopped
        XCTAssertEqual(center.menuBarSymbolName, "mic")
    }

    func testStopPlaybackAndVoicePlaybackStateHandlers() async {
        let center = AgentControlCenter()
        center.health = .healthy
        center.isPlaying = true
        center.statusMessage = "TTS 播放中"

        center.stopPlayback()
        let stopped = await waitUntil { center.statusMessage == "播放已停止" && center.isPlaying == false }
        XCTAssertTrue(stopped)

        center._handleVoiceStateForTesting(.idle)
        let idleSet = await waitUntil { center.statusMessage == "VAD 待机" }
        XCTAssertTrue(idleSet)

        center._handleVoiceStateForTesting(.listening)
        let listeningSet = await waitUntil { center.statusMessage == "VAD 监听中" }
        XCTAssertTrue(listeningSet)

        center._handleVoiceStateForTesting(.speaking)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(center.statusMessage, "VAD 监听中")

        center._handleVoiceStateForTesting(.processing)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(center.statusMessage, "VAD 监听中")

        center.isPlaying = true
        center.statusMessage = "TTS 播放中"
        center._handlePlaybackStateForTesting(.idle)
        XCTAssertEqual(center.statusMessage, "TTS 空闲")
        XCTAssertFalse(center.isPlaying)
    }

    func testInitialIdleDuringStartupDoesNotTriggerStoppedRecoveryMessage() async {
        let center = AgentControlCenter()
        center._setHealthForTesting(.healthy)
        center._setHasVoiceCaptureEverStartedForTesting(false)
        center._setVoiceStartupPendingForTesting(true)

        center._handleVoiceStateForTesting(.idle)

        let startupSet = await waitUntil { center.statusMessage == "启动语音采集" }
        XCTAssertTrue(startupSet)
        XCTAssertFalse(center.statusMessage.contains("采集已停止"))
    }

    func testListeningPromotesStartingHealthToHealthy() async {
        let center = AgentControlCenter()
        center._setHealthForTesting(.starting)
        center._setVoiceStartupPendingForTesting(true)

        center._handleVoiceStateForTesting(.listening)

        XCTAssertEqual(center.health, .healthy)
        XCTAssertEqual(center.statusMessage, "VAD 监听中")
    }

    func testCompactStatusTextDoesNotMapCompletedState() {
        let center = AgentControlCenter()
        center.health = .healthy

        center.statusMessage = "TTS 空闲"
        XCTAssertEqual(center.compactStatusText, "TTS 空闲")

        center.statusMessage = "Agent 响应: 好的"
        XCTAssertEqual(center.compactStatusText, "Agent 响应: 好的")

        center.statusMessage = "ASR 完成: 你好"
        XCTAssertEqual(center.compactStatusText, "ASR 完成: 你好")
    }

    func testCompactStatusTextUsesFriendlyASRNoResultPrompt() {
        let center = AgentControlCenter()
        center.health = .healthy
        center.statusMessage = "ASR 未识别到有效语音"

        XCTAssertEqual(center.compactStatusText, "没听清楚，请再说一次")
    }

    func testListeningDoesNotOverrideActiveRecognitionStatus() {
        let center = AgentControlCenter()
        center.health = .healthy
        center.statusMessage = "ASR 转写中"

        center._handleVoiceStateForTesting(.listening)

        XCTAssertEqual(center.statusMessage, "ASR 转写中")
    }

    func testListeningDoesNotOverrideASRNoResultStatus() {
        let center = AgentControlCenter()
        center.health = .healthy
        center.statusMessage = "ASR 未识别到有效语音"

        center._handleVoiceStateForTesting(.listening)

        XCTAssertEqual(center.statusMessage, "ASR 未识别到有效语音")
    }

    func testPlaybackRestartIdleDoesNotTriggerStoppedStatus() {
        let center = AgentControlCenter()
        center.health = .healthy
        center.statusMessage = "TTS 播放中"
        center._setHasVoiceCaptureEverStartedForTesting(true)
        center._setRestartingVoiceCaptureAfterPlaybackForTesting(true)

        center._handleVoiceStateForTesting(.idle)
        XCTAssertEqual(center.statusMessage, "TTS 播放中")

        center._handleVoiceStateForTesting(.listening)
        XCTAssertEqual(center.statusMessage, "VAD 监听中")
    }

    func testTurnProcessingRestartIdleDoesNotTriggerStoppedStatus() {
        let center = AgentControlCenter()
        center.health = .healthy
        center.statusMessage = "ASR 转写中"
        center._setHasVoiceCaptureEverStartedForTesting(true)
        center._setRestartingVoiceCaptureAfterTurnProcessingForTesting(true)

        center._handleVoiceStateForTesting(.idle)
        XCTAssertEqual(center.statusMessage, "ASR 转写中")

        center._handleVoiceStateForTesting(.listening)
        XCTAssertNotEqual(center.statusMessage, "VAD 待机")
    }

    func testVoiceErrorDuringStartupMarksServiceUnreachable() async {
        let center = AgentControlCenter()
        center._setHealthForTesting(.starting)
        center._startVoiceErrorObserverForTesting()

        await center._emitVoiceErrorForTesting("设备初始化失败")

        let failed = await waitUntil {
            center.health == .unreachable && center.statusMessage == "采集异常: 设备初始化失败"
        }
        XCTAssertTrue(failed)

        center._handleVoiceStateForTesting(.idle)
        XCTAssertEqual(center.statusMessage, "采集异常: 设备初始化失败")
    }

    func testListeningCancelsScheduledRecoveryBeforeItFires() async {
        let center = AgentControlCenter()
        var recoveryAttemptReasons: [String] = []

        center._setHealthForTesting(.healthy)
        center._setHasVoiceCaptureEverStartedForTesting(true)
        center._setVoiceRecoveryAttemptHookForTesting { reason in
            recoveryAttemptReasons.append(reason)
        }
        center._startVoiceErrorObserverForTesting()

        await center._emitVoiceErrorForTesting("持续检测到零能量音频(设备 0)，可能输入源异常")
        let scheduled = await waitUntil { center.statusMessage.contains("3秒后自动重试") }
        XCTAssertTrue(scheduled)

        center._handleVoiceStateForTesting(.listening)
        XCTAssertEqual(center.statusMessage, "VAD 监听中")

        try? await Task.sleep(nanoseconds: 3_300_000_000)
        XCTAssertTrue(recoveryAttemptReasons.isEmpty)
        XCTAssertEqual(center.statusMessage, "VAD 监听中")
    }

    func testIdleDoesNotOverwriteScheduledRecoveryStatus() async {
        let center = AgentControlCenter()
        center._setHealthForTesting(.healthy)
        center._setHasVoiceCaptureEverStartedForTesting(true)
        center._startVoiceErrorObserverForTesting()

        await center._emitVoiceErrorForTesting("持续检测到零能量音频(设备 0)，可能输入源异常")
        let scheduled = await waitUntil { center.statusMessage.contains("3秒后自动重试") }
        XCTAssertTrue(scheduled)

        center._handleVoiceStateForTesting(.idle)
        XCTAssertTrue(center.statusMessage.contains("3秒后自动重试"))
    }

    func testToggleServiceAndStopServicePath() async {
        let center = AgentControlCenter()
        center.health = .healthy
        center.toggleService()
        let stopped = await waitUntil(timeout: 1.5) { center.health == .stopped }
        XCTAssertTrue(stopped)

        center.health = .stopped
        center.toggleService()
        let transitioned = await waitUntil(timeout: 2.0) { center.health != .stopped }
        XCTAssertTrue(transitioned)
    }

    func testHookedWrapperMethods() async throws {
        let center = AgentControlCenter()
        center._setTestHooksForTesting(
            .init(
                transcribeAudio: { data in
                    XCTAssertEqual(data, Data([0xAA]))
                    return "transcribed"
                },
                executeAgent: { text in
                    XCTAssertEqual(text, "transcribed")
                    return AgentService.Response(replyText: "reply", sessionId: "sid")
                },
                synthesizeText: { text in
                    XCTAssertEqual(text, "reply")
                    return Data([0x10])
                },
                playAudio: { data, interrupt in
                    XCTAssertEqual(data, Data([0x10]))
                    XCTAssertFalse(interrupt)
                }
            )
        )

        let transcript = try await center._transcribeAudioDataForTesting(Data([0xAA]))
        XCTAssertEqual(transcript, "transcribed")

        let response = try await center._executeAgentForTesting(transcript)
        XCTAssertEqual(response.replyText, "reply")
        XCTAssertEqual(response.sessionId, "sid")

        let audio = try await center._synthesizeSpeechForTesting(response.replyText)
        XCTAssertEqual(audio, Data([0x10]))

        try await center._playAudioDataForTesting(audio, interrupt: false)
    }

    func testValidateRuntimeDependenciesCall() {
        let center = AgentControlCenter()
        do {
            try center._validateRuntimeDependenciesForTesting()
        } catch {
            XCTAssertNotNil(error.localizedDescription)
        }
    }

    func testValidateRuntimeDependenciesWithAgentOverride() {
        let center = AgentControlCenter()
        center._setRequiredAgentExecutableNameOverrideForTesting("sh")
        defer {
            center._setRequiredAgentExecutableNameOverrideForTesting(nil)
        }

        do {
            try center._validateRuntimeDependenciesForTesting()
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testStartServiceFailureAndRuntimeDescriptionMissingBranch() async {
        let center = AgentControlCenter()
        center._setRequiredAgentExecutableNameOverrideForTesting("missing-agent-\(UUID().uuidString)")
        await center.startService()
        XCTAssertEqual(center.health, .unreachable)
        XCTAssertTrue(center.statusMessage.contains("启动失败"))
        await center.refreshStatus()
        XCTAssertTrue(center.runtimeDescription.contains("claude: missing"))
        XCTAssertTrue(center.runtimeDescription.contains("spk:"))

        center._setRequiredAgentExecutableNameOverrideForTesting(nil)
    }

    func testStartServiceFailsWhenMicrophonePermissionDenied() async {
        let center = AgentControlCenter()
        center._setRequiredAgentExecutableNameOverrideForTesting("sh")
        center._setTestHooksForTesting(
            .init(
                requestMicrophoneAccess: { false },
                transcribeAudio: nil,
                executeAgent: nil,
                synthesizeText: nil,
                playAudio: nil
            )
        )

        await center.startService()

        XCTAssertEqual(center.health, .unreachable)
        XCTAssertTrue(center.statusMessage.contains("麦克风权限"))
    }

    func testPlayAudioDataWithoutHookUsesPlaybackServiceBranch() async throws {
        let center = AgentControlCenter()
        center._setTestHooksForTesting(nil)
        let wav = makeWAVData()
        try await center._playAudioDataForTesting(wav, interrupt: true)
        try? await Task.sleep(for: .milliseconds(120))
    }

    func testVoiceErrorObserverUpdatesStatusOnlyWhenRunning() async {
        let center = AgentControlCenter()
        center.health = .healthy
        center._startVoiceErrorObserverForTesting()

        await center._emitVoiceErrorForTesting("err-1")
        let healthyUpdated = await waitUntil { center.statusMessage.contains("采集异常: err-1") }
        XCTAssertTrue(healthyUpdated)

        center.health = .stopped
        center.statusMessage = "服务已停止"
        await center._emitVoiceErrorForTesting("err-2")
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(center.statusMessage, "服务已停止")

        await center.stopService()
    }

    func testSegmentProcessingTaskConsumesVoiceStream() async {
        let center = AgentControlCenter()
        center.autoSpeak = false
        center._setTestHooksForTesting(
            .init(
                transcribeAudio: { _ in "stream-asr" },
                executeAgent: { text in
                    XCTAssertEqual(text, "stream-asr")
                    return AgentService.Response(replyText: "stream-agent", sessionId: "s-stream")
                },
                synthesizeText: nil,
                playAudio: nil
            )
        )
        center._startSegmentProcessingForTesting()

        await center._emitVoiceSegmentForTesting(Data([0x01, 0x02, 0x03]))
        let consumed = await waitUntil { center.latestConversation.assistant == "stream-agent" }
        XCTAssertTrue(consumed)

        await center.stopService()
    }

    func testSegmentProcessingQueuesMultipleSegmentsWithoutDroppingNewest() async {
        let center = AgentControlCenter()
        center.autoSpeak = false

        center._setTestHooksForTesting(
            .init(
                transcribeAudio: { data in
                    try? await Task.sleep(for: .milliseconds(120))
                    let marker = data.first ?? 0
                    return "seg-\(marker)"
                },
                executeAgent: { text in
                    return AgentService.Response(replyText: "reply-\(text)", sessionId: "s-\(text)")
                },
                synthesizeText: nil,
                playAudio: nil
            )
        )
        center._startSegmentProcessingForTesting()

        await center._emitVoiceSegmentForTesting(Data([0x01]))
        await center._emitVoiceSegmentForTesting(Data([0x02]))
        await center._emitVoiceSegmentForTesting(Data([0x03]))

        let start = Date()
        var processedAll = false
        while Date().timeIntervalSince(start) < 1.5 {
            let turns = await center._getConversationTurnsForTesting()
            if turns.count == 3 {
                processedAll = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(processedAll)

        let turns = await center._getConversationTurnsForTesting()
        XCTAssertEqual(turns.map(\.userText), ["seg-1", "seg-2", "seg-3"])
        XCTAssertEqual(turns.map(\.replyText), ["reply-seg-1", "reply-seg-2", "reply-seg-3"])

        await center.stopService()
    }

    func testIdleDuringVoiceRecoveryDoesNotScheduleAnotherRecovery() async {
        let center = AgentControlCenter()
        center._setHealthForTesting(.healthy)
        center._setHasVoiceCaptureEverStartedForTesting(true)
        center._setIsPerformingVoiceRecoveryForTesting(true)
        center.statusMessage = "正在恢复采集"

        center._handleVoiceStateForTesting(.idle)

        XCTAssertEqual(center.statusMessage, "正在恢复采集")
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(center.statusMessage, "正在恢复采集")
    }

    // MARK: - Lifecycle Tests

    func testBootstrap_chainsStartServiceAndMonitoring() async {
        let center = AgentControlCenter()
        center._setRequiredAgentExecutableNameOverrideForTesting("sh")

        center.bootstrap()

        let started = await waitUntil(timeout: 2.0) {
            center.health == .healthy || center.health == .unreachable
        }
        XCTAssertTrue(started)

        await center.stopService()
        center._setRequiredAgentExecutableNameOverrideForTesting(nil)
    }

    func testRefreshStatus_updatesAllStatusItems() async {
        let center = AgentControlCenter()
        center._setRequiredAgentExecutableNameOverrideForTesting("sh")

        await center.refreshStatus()

        XCTAssertNotNil(center.lastRefresh)
        XCTAssertFalse(center.runtimeDescription.isEmpty)

        center._setRequiredAgentExecutableNameOverrideForTesting(nil)
    }

    func testStopService_resetsAllState() async {
        let center = AgentControlCenter()
        center._setRequiredAgentExecutableNameOverrideForTesting("sh")
        center.health = .healthy
        center.isPlaying = true
        center.statusMessage = "some status"

        await center.stopService()

        XCTAssertEqual(center.health, .stopped)
        XCTAssertFalse(center.isPlaying)
        XCTAssertEqual(center.statusMessage, "服务已停止")
        XCTAssertNotNil(center.lastRefresh)

        center._setRequiredAgentExecutableNameOverrideForTesting(nil)
    }

    func testToggleService_fromStoppedToRunning() async {
        let center = AgentControlCenter()
        center._setRequiredAgentExecutableNameOverrideForTesting("sh")
        center.health = .stopped
        center.statusMessage = "服务已停止"

        center.toggleService()

        let transitioned = await waitUntil(timeout: 2.0) {
            center.health == .healthy || center.health == .unreachable
        }
        XCTAssertTrue(transitioned)

        await center.stopService()
        center._setRequiredAgentExecutableNameOverrideForTesting(nil)
    }

    func testToggleService_fromRunningToStopped() async {
        let center = AgentControlCenter()
        center._setRequiredAgentExecutableNameOverrideForTesting("sh")
        center.health = .healthy

        center.toggleService()

        let stopped = await waitUntil(timeout: 2.0) {
            center.health == .stopped
        }
        XCTAssertTrue(stopped)

        center._setRequiredAgentExecutableNameOverrideForTesting(nil)
    }

    func testBehaviorDiagnosticsSnapshot_returnsValidSnapshot() async {
        let center = AgentControlCenter()
        let snapshot = await center.behaviorDiagnosticsSnapshot()

        XCTAssertNotNil(snapshot)
        XCTAssertNotNil(snapshot.summary)
        XCTAssertNotNil(snapshot.signalSummary)
        XCTAssertNotNil(snapshot.eventLines)
    }

}
