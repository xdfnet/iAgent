import XCTest
@testable import iAgent

final class CoreUtilitiesCoverageTests: XCTestCase {
    func testAudioProcessorHelpers() throws {
        let frame1 = Data([0x01, 0x00, 0x02, 0x00])
        let frame2 = Data([0x03, 0x00, 0x04, 0x00])
        let merged = AudioProcessor.concatenateFrames([frame1, frame2])
        XCTAssertEqual(merged, frame1 + frame2)

        let tempDir = AudioProcessor.tempDirectory
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        let url = AudioProcessor.tempFileURL(prefix: "unit", ext: "pcm")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("unit-"))
        XCTAssertEqual(url.pathExtension, "pcm")
    }

    func testAudioFormatHelpers() {
        XCTAssertEqual(AudioFormat.wav.mimeType, "audio/wav")
        XCTAssertEqual(AudioFormat.mp3.mimeType, "audio/mpeg")
        XCTAssertEqual(AudioFormat.ogg.mimeType, "audio/ogg")
        XCTAssertEqual(AudioFormat.pcm.mimeType, "audio/raw")

        XCTAssertEqual(AudioFormat.wav.ffmpegCodec, "pcm_s16le")
        XCTAssertEqual(AudioFormat.mp3.ffmpegCodec, "libmp3lame")
        XCTAssertEqual(AudioFormat.ogg.ffmpegCodec, "libopus")
        XCTAssertEqual(AudioFormat.pcm.ffmpegCodec, "copy")
    }

    func testExecutableLocatorAndEnvironment() throws {
        XCTAssertNotNil(ExecutableLocator.find("/bin/sh"))
        XCTAssertNotNil(ExecutableLocator.find("sh"))
        XCTAssertNil(ExecutableLocator.find("/tmp/no-such-executable-\(UUID().uuidString)"))
        XCTAssertNotNil(ExecutableLocator.find("sleep"))
        XCTAssertNil(ExecutableLocator.find("definitely_missing_command_\(UUID().uuidString)"))
        XCTAssertNil(ExecutableLocator._resolveViaShellForTesting("sh", shell: "/tmp/missing-shell-\(UUID().uuidString)"))
        XCTAssertNotNil(ExecutableLocator._resolveViaShellForTesting("sh", shell: "/bin/zsh"))
        XCTAssertNil(ExecutableLocator._resolveViaShellForTesting("definitely_missing_command_\(UUID().uuidString)", shell: "/bin/zsh"))
        XCTAssertEqual(ExecutableLocator.shellQuote("a'b"), "'a'\\''b'")

        let env = ExecutableLocator.runtimeEnvironment()
        XCTAssertNotNil(env["HOME"])
        XCTAssertNotNil(env["PATH"])
        XCTAssertTrue(ExecutableLocator.isAvailable("sh"))
    }

    func testErrorDescriptions() {
        XCTAssertEqual(ASRError.invalidURL.errorDescription, "无效的 ASR URL")
        XCTAssertEqual(ASRError.invalidResponse.errorDescription, "无效的响应")
        XCTAssertEqual(ASRError.noResult.errorDescription, "ASR 未返回结果")
        XCTAssertEqual(ASRError.decodingError.errorDescription, "响应解析失败")
        XCTAssertTrue((ASRError.httpError(statusCode: 500, message: "boom").errorDescription ?? "").contains("500"))

        XCTAssertEqual(TTSError.invalidResponse.errorDescription, "无效的 TTS 响应")
        XCTAssertEqual(TTSError.invalidURL.errorDescription, "无效的 TTS URL")
        XCTAssertEqual(TTSError.httpError(statusCode: 503).errorDescription, "TTS HTTP 错误: 503")
        XCTAssertEqual(TTSError.noAudioData.errorDescription, "TTS 未返回音频数据")
        XCTAssertTrue((TTSError.synthesisFailed("bad").errorDescription ?? "").contains("bad"))

        XCTAssertTrue((AgentError.executableNotFound("claude").errorDescription ?? "").contains("claude"))
        XCTAssertTrue((AgentError.launchFailed("x").errorDescription ?? "").contains("x"))
        XCTAssertTrue((AgentError.executionFailed(statusCode: 2, output: "", error: "stderr").errorDescription ?? "").contains("2"))
        XCTAssertTrue((AgentError.parseError("bad").errorDescription ?? "").contains("bad"))
        XCTAssertEqual(AgentError.timeout.errorDescription, "执行超时")
    }

    func testASRAndSSEModelInitializers() throws {
        let utterance = ASRResponse.ASRResult.Utterance(text: "u1")
        let result = ASRResponse.ASRResult(text: "text1", utterances: [utterance])
        let response = ASRResponse(result: result)
        XCTAssertEqual(response.result?.text, "text1")
        XCTAssertEqual(response.result?.utterances?.first?.text, "u1")

        let decodedUtterance = try JSONDecoder().decode(
            ASRResponse.ASRResult.Utterance.self,
            from: Data(#"{"text":"decoded"}"#.utf8)
        )
        XCTAssertEqual(decodedUtterance.text, "decoded")

        let decodedResult = try JSONDecoder().decode(
            ASRResponse.ASRResult.self,
            from: Data(#"{"text":"r","utterances":[{"text":"u"}]}"#.utf8)
        )
        XCTAssertEqual(decodedResult.text, "r")
        XCTAssertEqual(decodedResult.utterances?.first?.text, "u")

        let event = SSEvent(data: "ZGF0YQ==", code: 0, message: "ok")
        XCTAssertEqual(event.data, "ZGF0YQ==")
        XCTAssertEqual(event.code, 0)
        XCTAssertEqual(event.message, "ok")

        let decodedEvent = try JSONDecoder().decode(
            SSEvent.self,
            from: Data(#"{"data":"YWI=","code":200,"message":"ok"}"#.utf8)
        )
        XCTAssertEqual(decodedEvent.data, "YWI=")
        XCTAssertEqual(decodedEvent.code, 200)
    }

    func testBuildAgentPromptContainsUserInput() {
        let prompt = buildAgentPrompt(userText: "今天天气如何")
        XCTAssertTrue(prompt.contains("今天天气如何"))
        XCTAssertTrue(prompt.contains("豆包"))
        XCTAssertTrue(prompt.contains("飞哥"))

        let promptWithBehavior = buildAgentPrompt(
            userText: "我回来了",
            behaviorContext: "飞哥回来了，和他打个招呼"
        )
        XCTAssertTrue(promptWithBehavior.contains("飞哥回来了，和他打个招呼"))
        XCTAssertTrue(promptWithBehavior.contains("我回来了"))
    }

    func testConversationMemoryTrimAndClear() async {
        let memory = ConversationMemory(maxTurns: 2)
        await memory.addTurn(user: "u1", assistant: "a1")
        await memory.addTurn(user: "u2", assistant: "a2")
        await memory.addTurn(user: "u3", assistant: "a3")

        let turns = await memory.getTurns()
        XCTAssertEqual(turns.count, 2)
        let latestTurn = await memory.getLatestTurn()

        let firstUserMatches = await MainActor.run { turns.first?.userText == "u2" }
        let lastReplyMatches = await MainActor.run { turns.last?.replyText == "a3" }
        let latestUserMatches = await MainActor.run { latestTurn?.userText == "u3" }

        XCTAssertTrue(firstUserMatches)
        XCTAssertTrue(lastReplyMatches)
        XCTAssertTrue(latestUserMatches)

        await memory.clear()
        let cleared = await memory.getTurns()
        XCTAssertTrue(cleared.isEmpty)
    }

    func testConfigurationDefaults() throws {
        var configured = Configuration()
        configured.speechToText.apiKey = "asr-key"
        configured.speechToText.resourceId = "asr-resource"
        configured.textToSpeech.appId = "app-id"
        configured.textToSpeech.accessToken = "tts-token"
        configured.textToSpeech.resourceId = "tts-resource"
        XCTAssertFalse(configured.speechToText.apiKey.isEmpty)
    }
}
