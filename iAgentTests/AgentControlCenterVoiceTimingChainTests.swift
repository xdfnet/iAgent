import XCTest
@testable import iAgent

private actor TimingTrace {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor AttemptCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }

    func current() -> Int {
        value
    }
}

private enum TestPipelineError: LocalizedError {
    case asrFailed
    case agentTimeout
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .asrFailed:
            return "模拟ASR失败"
        case .agentTimeout:
            return "模拟Agent超时"
        case .playbackFailed:
            return "模拟播放失败"
        }
    }
}

@MainActor
final class AgentControlCenterVoiceTimingChainTests: XCTestCase {
    func testVoiceSegmentFullChainWithAutoSpeak() async throws {
        let center = AgentControlCenter()
        let trace = TimingTrace()
        let inputAudio = Data([0x11, 0x22, 0x33, 0x44])
        let outputAudio = Data([0xAA, 0xBB, 0xCC])

        center.autoSpeak = true
        center._setTestHooksForTesting(
            .init(
                transcribeAudio: { audioData in
                    XCTAssertEqual(audioData, inputAudio)
                    await trace.record("asr")
                    return "你好，链路测试"
                },
                executeAgent: { text in
                    XCTAssertEqual(text, "你好，链路测试")
                    await trace.record("agent")
                    return AgentService.Response(replyText: "收到，开始播报", sessionId: "sess-1")
                },
                synthesizeText: { text in
                    XCTAssertEqual(text, "收到，开始播报")
                    await trace.record("tts")
                    return outputAudio
                },
                playAudio: { audioData, interrupt in
                    XCTAssertEqual(audioData, outputAudio)
                    XCTAssertTrue(interrupt)
                    await trace.record("play")
                }
            )
        )

        await center._processVoiceSegmentForTesting(inputAudio)

        let events = await trace.snapshot()
        XCTAssertEqual(events, ["asr", "agent", "tts", "play"])
        XCTAssertEqual(center.latestConversation.user, "你好，链路测试")
        XCTAssertEqual(center.latestConversation.assistant, "收到，开始播报")
        let turns = await center._getConversationTurnsForTesting()
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.userText, "你好，链路测试")
        XCTAssertEqual(turns.first?.replyText, "收到，开始播报")
    }

    func testVoiceSegmentWithoutAutoSpeakSkipsTTSAndPlayback() async throws {
        let center = AgentControlCenter()
        let trace = TimingTrace()
        center.autoSpeak = false

        center._setTestHooksForTesting(
            .init(
                transcribeAudio: { _ in
                    await trace.record("asr")
                    return "只做文本回复"
                },
                executeAgent: { text in
                    XCTAssertEqual(text, "只做文本回复")
                    await trace.record("agent")
                    return AgentService.Response(replyText: "文本回复完成", sessionId: "sess-2")
                },
                synthesizeText: { _ in
                    XCTFail("autoSpeak=false 时不应走 TTS")
                    return Data()
                },
                playAudio: { _, _ in
                    XCTFail("autoSpeak=false 时不应播放音频")
                }
            )
        )

        await center._processVoiceSegmentForTesting(Data([0x01, 0x02]))

        let events = await trace.snapshot()
        XCTAssertEqual(events, ["asr", "agent"])
        XCTAssertEqual(center.latestConversation.user, "只做文本回复")
        XCTAssertEqual(center.latestConversation.assistant, "文本回复完成")
        XCTAssertEqual(center.statusMessage, "回复: 文本回复完成")
    }

    func testVoiceSegmentASRFailureStopsDownstream() async throws {
        let center = AgentControlCenter()
        let trace = TimingTrace()

        center._setTestHooksForTesting(
            .init(
                transcribeAudio: { _ in
                    await trace.record("asr")
                    throw TestPipelineError.asrFailed
                },
                executeAgent: { _ in
                    XCTFail("ASR 失败后不应调用 Agent")
                    return AgentService.Response(replyText: "", sessionId: nil)
                },
                synthesizeText: { _ in
                    XCTFail("ASR 失败后不应调用 TTS")
                    return Data()
                },
                playAudio: { _, _ in
                    XCTFail("ASR 失败后不应播放")
                }
            )
        )

        await center._processVoiceSegmentForTesting(Data([0x99]))

        let events = await trace.snapshot()
        XCTAssertEqual(events, ["asr"])
        XCTAssertTrue(center.statusMessage.contains("处理失败"))
        let turns = await center._getConversationTurnsForTesting()
        XCTAssertTrue(turns.isEmpty)
    }

    func testSecondVoiceTurnStillWorksAfterAgentFailure() async throws {
        let center = AgentControlCenter()
        let trace = TimingTrace()
        let attemptCounter = AttemptCounter()

        center.autoSpeak = false
        center._setTestHooksForTesting(
            .init(
                transcribeAudio: { _ in
                    let attempt = await attemptCounter.next()
                    await trace.record("asr-\(attempt)")
                    return "第\(attempt)轮"
                },
                executeAgent: { text in
                    await trace.record("agent-\(text)")
                    if text == "第1轮" {
                        throw TestPipelineError.agentTimeout
                    }
                    return AgentService.Response(replyText: "恢复成功", sessionId: nil)
                }
            )
        )

        await center._processVoiceSegmentForTesting(Data([0x01]))
        XCTAssertTrue(center.statusMessage.contains("处理失败") || center.statusMessage.contains("Agent失败"))

        await center._processVoiceSegmentForTesting(Data([0x02]))

        let events = await trace.snapshot()
        XCTAssertEqual(events, ["asr-1", "agent-第1轮", "asr-2", "agent-第2轮"])
        XCTAssertEqual(center.latestConversation.user, "第2轮")
        XCTAssertEqual(center.latestConversation.assistant, "恢复成功")
    }

    func testSecondVoiceTurnStillWorksAfterPlaybackFailure() async throws {
        let center = AgentControlCenter()
        let playAttemptCounter = AttemptCounter()

        center.autoSpeak = true
        center._setTestHooksForTesting(
            .init(
                transcribeAudio: { _ in "播放测试" },
                executeAgent: { text in
                    AgentService.Response(replyText: "\(text)-reply", sessionId: nil)
                },
                synthesizeText: { text in
                    Data(text.utf8)
                },
                playAudio: { _, _ in
                    let playAttempts = await playAttemptCounter.next()
                    if playAttempts == 1 {
                        throw TestPipelineError.playbackFailed
                    }
                }
            )
        )

        await center._processVoiceSegmentForTesting(Data([0x10]))
        XCTAssertTrue(center.statusMessage.contains("播报失败"))

        await center._processVoiceSegmentForTesting(Data([0x11]))

        let finalPlayAttempts = await playAttemptCounter.current()
        XCTAssertEqual(finalPlayAttempts, 2)
        XCTAssertEqual(center.latestConversation.assistant, "播放测试-reply")
    }
}
