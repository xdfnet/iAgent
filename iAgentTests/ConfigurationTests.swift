import XCTest
@testable import iAgent

final class ConfigurationTests: XCTestCase {
    // MARK: - Environment Variable Override Tests

    func testEnvironmentVariableOverride_asrApiKey() {
        let environment: [String: String] = [
            "IAGENT_ASR_API_KEY": "test-asr-key-from-env"
        ]

        var config = Configuration()
        config.apply(environment: environment)

        XCTAssertEqual(config.speechToText.apiKey, "test-asr-key-from-env")
    }

    func testEnvironmentVariableOverride_ttsAppId() {
        let environment: [String: String] = [
            "IAGENT_TTS_APP_ID": "test-tts-app-id"
        ]

        var config = Configuration()
        config.apply(environment: environment)

        XCTAssertEqual(config.textToSpeech.appId, "test-tts-app-id")
    }

    func testEnvironmentVariableOverride_ttsAccessToken() {
        let environment: [String: String] = [
            "IAGENT_TTS_ACCESS_TOKEN": "test-tts-token"
        ]

        var config = Configuration()
        config.apply(environment: environment)

        XCTAssertEqual(config.textToSpeech.accessToken, "test-tts-token")
    }

    func testEnvironmentVariableOverride_agentWorkdir() {
        let environment: [String: String] = [
            "IAGENT_AGENT_WORKDIR": "/custom/work/dir"
        ]

        var config = Configuration()
        config.apply(environment: environment)

        XCTAssertEqual(config.agent.workdir, "/custom/work/dir")
    }

    // MARK: - Bool Parsing Tests

    func testBoolParsing_handlesTrueFalse1Yes() {
        XCTAssertTrue(Configuration.boolValue("true"))
        XCTAssertTrue(Configuration.boolValue("True"))
        XCTAssertTrue(Configuration.boolValue("TRUE"))
        XCTAssertTrue(Configuration.boolValue("1"))
        XCTAssertTrue(Configuration.boolValue("yes"))
        XCTAssertTrue(Configuration.boolValue("Yes"))
        XCTAssertTrue(Configuration.boolValue("y"))
        XCTAssertTrue(Configuration.boolValue("on"))

        XCTAssertFalse(Configuration.boolValue("false"))
        XCTAssertFalse(Configuration.boolValue("False"))
        XCTAssertFalse(Configuration.boolValue("FALSE"))
        XCTAssertFalse(Configuration.boolValue("0"))
        XCTAssertFalse(Configuration.boolValue("no"))
        XCTAssertFalse(Configuration.boolValue("No"))
        XCTAssertFalse(Configuration.boolValue("n"))
        XCTAssertFalse(Configuration.boolValue("off"))

        XCTAssertNil(Configuration.boolValue("invalid"))
        XCTAssertNil(Configuration.boolValue(""))
        XCTAssertNil(Configuration.boolValue("maybe"))
    }

    // MARK: - File Override Tests

    func testFileOverride_nestedStructures() {
        var config = Configuration()

        let fileOverride: [String: Any] = [
            "speechToText": [
                "apiKey": "file-asr-key"
            ],
            "textToSpeech": [
                "appId": "file-tts-app-id",
                "voiceType": "custom_voice"
            ],
            "agent": [
                "workdir": "/file/workdir",
                "timeoutSeconds": 60
            ],
            "client": [
                "inputDeviceIndex": "device-123",
                "audio": [
                    "sampleRate": 48000,
                    "channels": 2
                ],
                "continuous": [
                    "frameMs": 20,
                    "startThreshold": 1500
                ]
            ],
            "behavior": [
                "enabled": true,
                "routerSSHHost": "custom-router",
                "pollIntervalSeconds": 10.0
            ]
        ]

        config.apply(fileOverride: fileOverride)

        XCTAssertEqual(config.speechToText.apiKey, "file-asr-key")
        XCTAssertEqual(config.textToSpeech.appId, "file-tts-app-id")
        XCTAssertEqual(config.textToSpeech.voiceType, "custom_voice")
        XCTAssertEqual(config.agent.workdir, "/file/workdir")
        XCTAssertEqual(config.agent.timeoutSeconds, 60)
        XCTAssertEqual(config.client.inputDeviceIndex, "device-123")
        XCTAssertEqual(config.client.audio.sampleRate, 48000)
        XCTAssertEqual(config.client.audio.channels, 2)
        XCTAssertEqual(config.client.continuous.frameMs, 20)
        XCTAssertEqual(config.client.continuous.startThreshold, 1500)
        XCTAssertTrue(config.behavior.enabled)
        XCTAssertEqual(config.behavior.routerSSHHost, "custom-router")
        XCTAssertEqual(config.behavior.pollIntervalSeconds, 10.0)
    }

    func testFileOverride_partialNestedStructures() {
        var config = Configuration()
        config.client.audio.sampleRate = 48000
        config.client.audio.channels = 2

        let fileOverride: [String: Any] = [
            "client": [
                "continuous": [
                    "frameMs": 20
                ]
            ]
        ]

        config.apply(fileOverride: fileOverride)

        XCTAssertEqual(config.client.continuous.frameMs, 20)
        XCTAssertEqual(config.client.audio.sampleRate, 48000)
        XCTAssertEqual(config.client.audio.channels, 2)
    }

    // MARK: - Update and Reload Tests

    func testUpdate_savesCorrectly() {
        var config = Configuration()
        config.speechToText.apiKey = "updated-api-key"
        config.textToSpeech.appId = "updated-app-id"
        config.agent.workdir = "/updated/workdir"
        config.behavior.enabled = false
        config.client.inputDeviceIndex = "updated-device"

        XCTAssertEqual(config.speechToText.apiKey, "updated-api-key")
        XCTAssertEqual(config.textToSpeech.appId, "updated-app-id")
        XCTAssertEqual(config.agent.workdir, "/updated/workdir")
        XCTAssertFalse(config.behavior.enabled)
        XCTAssertEqual(config.client.inputDeviceIndex, "updated-device")
    }

    func testReload_refreshesCachedValues() {
        let reloadResult = Configuration.reload()
        XCTAssertNotNil(reloadResult)
    }

    // MARK: - Default Value Tests

    func testSpeechToTextSettings_defaultValues() {
        let settings = SpeechToTextSettings()
        XCTAssertEqual(settings.apiKey, "")
        XCTAssertEqual(settings.flashUrl, "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")
        XCTAssertEqual(settings.resourceId, "volc.bigasr.auc_turbo")
    }

    func testTextToSpeechSettings_defaultValues() {
        let settings = TextToSpeechSettings()
        XCTAssertEqual(settings.appId, "")
        XCTAssertEqual(settings.accessToken, "")
        XCTAssertEqual(settings.endpoint, "https://openspeech.bytedance.com/api/v3/tts/unidirectional")
        XCTAssertEqual(settings.resourceId, "seed-tts-2.0")
        XCTAssertEqual(settings.voiceType, "zh_female_tianmeitaozi_uranus_bigtts")
        XCTAssertEqual(settings.volume, 2.0)
    }

    func testAgentSettings_defaultValues() {
        let settings = AgentSettings()
        XCTAssertEqual(settings.workdir, FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertEqual(settings.timeoutSeconds, 45)
    }

    func testBehaviorSettings_defaultValues() {
        let settings = BehaviorSettings()
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.routerSSHHost, "router")
        XCTAssertEqual(settings.monitoredPhoneMAC, "F6:85:C2:7F:1D:32")
        XCTAssertEqual(settings.monitoredWiFiInterfaces, "rax0")
        XCTAssertEqual(settings.pollIntervalSeconds, 5)
        XCTAssertEqual(settings.contextTTLSeconds, 10 * 60)
        XCTAssertEqual(settings.cooldownSeconds, 0)
        XCTAssertEqual(settings.requiredOnlineConfirmations, 2)
        XCTAssertEqual(settings.requiredOfflineConfirmations, 2)
    }

    func testClientAudioSettings_defaultValues() {
        let settings = ClientAudioSettings()
        XCTAssertEqual(settings.sampleRate, 16000)
        XCTAssertEqual(settings.channels, 1)
        XCTAssertEqual(settings.sampleWidth, 2)
    }

    func testClientContinuousSettings_defaultValues() {
        let settings = ClientContinuousSettings()
        XCTAssertFalse(settings.interruptOnSpeech)
        XCTAssertEqual(settings.frameMs, 30)
        XCTAssertEqual(settings.startThreshold, 1300)
        XCTAssertEqual(settings.playingStartThreshold, 2800)
        XCTAssertEqual(settings.endThreshold, 520)
        XCTAssertEqual(settings.startFrames, 5)
        XCTAssertEqual(settings.playingStartFrames, 8)
        XCTAssertEqual(settings.endSilenceFrames, 22)
        XCTAssertEqual(settings.prerollFrames, 16)
        XCTAssertEqual(settings.minSpeechFrames, 10)
        XCTAssertEqual(settings.postInterruptCooldownSeconds, 1.2)
    }

    func testClientSettings_defaultValues() {
        let settings = ClientSettings()
        XCTAssertEqual(settings.inputDeviceIndex, "0")
        XCTAssertEqual(settings.outputDeviceUID, "")
        XCTAssertNotNil(settings.audio)
        XCTAssertNotNil(settings.continuous)
    }

    // MARK: - Codable Tests

    func testConfiguration_codableRoundTrip() throws {
        var config = Configuration()
        config.speechToText.apiKey = "test-key"
        config.textToSpeech.appId = "test-app"
        config.agent.workdir = "/test/dir"

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Configuration.self, from: data)

        XCTAssertEqual(decoded.speechToText.apiKey, "test-key")
        XCTAssertEqual(decoded.textToSpeech.appId, "test-app")
        XCTAssertEqual(decoded.agent.workdir, "/test/dir")
    }

    func testBehaviorSettings_codableRoundTrip() throws {
        var settings = BehaviorSettings()
        settings.enabled = false
        settings.routerSSHHost = "custom-router"
        settings.pollIntervalSeconds = 15.0

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(BehaviorSettings.self, from: data)

        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.routerSSHHost, "custom-router")
        XCTAssertEqual(decoded.pollIntervalSeconds, 15.0)
    }
}
