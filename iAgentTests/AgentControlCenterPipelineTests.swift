import XCTest
@testable import iAgent

private actor AsyncCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func get() -> Int {
        value
    }
}

@MainActor
final class AgentControlCenterPipelineTests: XCTestCase {
    func testProcessTranscriptUpdatesConversation() async throws {
        let center = AgentControlCenter()
        let executeCount = AsyncCounter()

        center._setTestHooksForTesting(
            .init(
                transcribeAudio: nil,
                executeAgent: { text in
                    await executeCount.increment()
                    return AgentService.Response(replyText: "收到: \(text)", sessionId: nil)
                },
                synthesizeText: nil,
                playAudio: nil
            )
        )

        try await center._processTranscriptForTesting("测试输入", shouldAutoSpeak: false)

        let executeCountValue = await executeCount.get()
        XCTAssertEqual(executeCountValue, 1)
        XCTAssertEqual(center.latestConversation.user, "测试输入")
        XCTAssertEqual(center.latestConversation.assistant, "收到: 测试输入")
    }

    func testProcessTranscriptAutoSpeakRunsSynthesizeAndPlay() async throws {
        let center = AgentControlCenter()
        let synthCount = AsyncCounter()
        let playCount = AsyncCounter()

        center._setTestHooksForTesting(
            .init(
                transcribeAudio: nil,
                executeAgent: { text in
                    AgentService.Response(replyText: "答复: \(text)", sessionId: nil)
                },
                synthesizeText: { _ in
                    await synthCount.increment()
                    return Data([0x00, 0x01, 0x02])
                },
                playAudio: { _, interrupt in
                    XCTAssertTrue(interrupt)
                    await playCount.increment()
                }
            )
        )

        try await center._processTranscriptForTesting("自动播报", shouldAutoSpeak: true)

        let synthCountValue = await synthCount.get()
        let playCountValue = await playCount.get()
        XCTAssertEqual(synthCountValue, 1)
        XCTAssertEqual(playCountValue, 1)
        XCTAssertEqual(center.latestConversation.assistant, "答复: 自动播报")
    }

    func testBehaviorContextIsInjectedIntoPromptOnce() async {
        let center = AgentControlCenter()

        await center._setBehaviorContextMessageForTesting("飞哥回来了，和他打个招呼")
        let firstPrompt = await center._buildPromptForTesting("我回来了")
        XCTAssertTrue(firstPrompt.contains("飞哥回来了，和他打个招呼"))
        XCTAssertTrue(firstPrompt.contains("我回来了"))

        let secondPrompt = await center._buildPromptForTesting("再来一次")
        XCTAssertFalse(secondPrompt.contains("飞哥回来了，和他打个招呼"))
        XCTAssertTrue(secondPrompt.contains("再来一次"))
    }

    func testArrivedHomeTriggerRunsAgentAndPlaybackImmediately() async throws {
        let center = AgentControlCenter()
        let synthCount = AsyncCounter()
        let playCount = AsyncCounter()

        center._setHealthForTesting(.healthy)
        center._setTestHooksForTesting(
            .init(
                transcribeAudio: nil,
                executeAgent: { text in
                    XCTAssertEqual(text, "请主动和飞哥打个招呼，欢迎他回家。")
                    return AgentService.Response(replyText: "飞哥，欢迎回家。", sessionId: nil)
                },
                synthesizeText: { text in
                    XCTAssertEqual(text, "飞哥，欢迎回家。")
                    await synthCount.increment()
                    return Data([0x01, 0x02])
                },
                playAudio: { _, interrupt in
                    XCTAssertTrue(interrupt)
                    await playCount.increment()
                },
                pauseVoiceCaptureForPlayback: {},
                resumeVoiceCaptureAfterPlayback: {}
            )
        )

        try await center._simulateBehaviorTriggerForTesting("飞哥回来了，和他打个招呼")

        XCTAssertEqual(center.latestConversation.user, "飞哥回来了")
        XCTAssertEqual(center.latestConversation.assistant, "飞哥，欢迎回家。")
        XCTAssertEqual(center.statusMessage, "TTS 空闲")
        let synthCountValue = await synthCount.get()
        let playCountValue = await playCount.get()
        XCTAssertEqual(synthCountValue, 1)
        XCTAssertEqual(playCountValue, 1)
    }
}
