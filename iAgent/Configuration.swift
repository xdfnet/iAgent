//
//  Configuration.swift
//  iAgent
//
//  运行时配置加载与默认值
//

import Foundation

// MARK: - 根配置

struct Configuration: Codable, Sendable {
    var speechToText = SpeechToTextSettings()
    var textToSpeech = TextToSpeechSettings()
    var agent = AgentSettings()
    var behavior = BehaviorSettings()
    var client = ClientSettings()

    nonisolated private static let store = ConfigurationStore()

    nonisolated static var shared: Configuration {
        store.current
    }

    nonisolated init() {}

    @discardableResult
    nonisolated static func reload() -> Configuration {
        store.reload()
    }

    nonisolated static func updateClientInputDeviceIndex(_ inputDeviceIndex: String) {
        store.update {
            $0.client.inputDeviceIndex = inputDeviceIndex
        }
    }

    nonisolated static func updateClientOutputDeviceUID(_ outputDeviceUID: String) {
        store.update {
            $0.client.outputDeviceUID = outputDeviceUID
        }
    }
}

enum ConfigurationError: Error, LocalizedError {
    case invalidConfigFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfigFile(let message):
            return "配置文件解析失败: \(message)"
        }
    }
}

// MARK: - 语音识别 (ASR) 配置

struct SpeechToTextSettings: Codable, Sendable {
    var apiKey: String
    var flashUrl: String
    var resourceId: String

    nonisolated init(
        apiKey: String = "",
        flashUrl: String = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash",
        resourceId: String = "volc.bigasr.auc_turbo"
    ) {
        self.apiKey = apiKey
        self.flashUrl = flashUrl
        self.resourceId = resourceId
    }
}

// MARK: - 语音合成 (TTS) 配置

struct TextToSpeechSettings: Codable, Sendable {
    var appId: String
    var accessToken: String
    var endpoint: String
    var resourceId: String
    var voiceType: String
    var volume: Float  // 播放音量 0.0 - 6.0 (afplay -v 参数)

    nonisolated init(
        appId: String = "",
        accessToken: String = "",
        endpoint: String = "https://openspeech.bytedance.com/api/v3/tts/unidirectional",
        resourceId: String = "seed-tts-2.0",
        voiceType: String = "zh_female_tianmeitaozi_uranus_bigtts",
        volume: Float = 2.0
    ) {
        self.appId = appId
        self.accessToken = accessToken
        self.endpoint = endpoint
        self.resourceId = resourceId
        self.voiceType = voiceType
        self.volume = volume
    }
}

// MARK: - Agent 执行器配置

struct AgentSettings: Codable, Sendable {
    var workdir: String
    var timeoutSeconds: Int

    nonisolated init(
        workdir: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeoutSeconds: Int = 45
    ) {
        self.workdir = workdir
        self.timeoutSeconds = timeoutSeconds
    }
}

// MARK: - 行为驱动配置

struct BehaviorSettings: Codable, Sendable {
    var enabled: Bool
    var routerSSHHost: String
    var monitoredPhoneMAC: String
    var monitoredWiFiInterfaces: String
    var pollIntervalSeconds: Double
    var contextTTLSeconds: Double
    var cooldownSeconds: Double
    var requiredOnlineConfirmations: Int
    var requiredOfflineConfirmations: Int

    nonisolated init(
        enabled: Bool = true,
        routerSSHHost: String = "router",
        monitoredPhoneMAC: String = "F6:85:C2:7F:1D:32",
        monitoredWiFiInterfaces: String = "rax0",
        pollIntervalSeconds: Double = 5,
        contextTTLSeconds: Double = 10 * 60,
        cooldownSeconds: Double = 0,
        requiredOnlineConfirmations: Int = 2,
        requiredOfflineConfirmations: Int = 2
    ) {
        self.enabled = enabled
        self.routerSSHHost = routerSSHHost
        self.monitoredPhoneMAC = monitoredPhoneMAC
        self.monitoredWiFiInterfaces = monitoredWiFiInterfaces
        self.pollIntervalSeconds = pollIntervalSeconds
        self.contextTTLSeconds = contextTTLSeconds
        self.cooldownSeconds = cooldownSeconds
        self.requiredOnlineConfirmations = requiredOnlineConfirmations
        self.requiredOfflineConfirmations = requiredOfflineConfirmations
    }
}

// MARK: - 客户端音频配置

struct ClientAudioSettings: Codable, Sendable {
    var sampleRate: Int
    var channels: Int
    var sampleWidth: Int

    nonisolated init(
        sampleRate: Int = 16000,
        channels: Int = 1,
        sampleWidth: Int = 2
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleWidth = sampleWidth
    }
}

// MARK: - 客户端持续监听配置

struct ClientContinuousSettings: Codable, Sendable {
    var interruptOnSpeech: Bool
    var frameMs: Int
    var startThreshold: Int
    var playingStartThreshold: Int
    var endThreshold: Int
    var startFrames: Int
    var playingStartFrames: Int
    var endSilenceFrames: Int
    var prerollFrames: Int
    var minSpeechFrames: Int
    var postInterruptCooldownSeconds: Double

    nonisolated init(
        interruptOnSpeech: Bool = false,
        frameMs: Int = 30,
        startThreshold: Int = 1300,
        playingStartThreshold: Int = 2800,
        endThreshold: Int = 520,
        startFrames: Int = 5,
        playingStartFrames: Int = 8,
        endSilenceFrames: Int = 22,
        prerollFrames: Int = 16,
        minSpeechFrames: Int = 10,
        postInterruptCooldownSeconds: Double = 1.2
    ) {
        self.interruptOnSpeech = interruptOnSpeech
        self.frameMs = frameMs
        self.startThreshold = startThreshold
        self.playingStartThreshold = playingStartThreshold
        self.endThreshold = endThreshold
        self.startFrames = startFrames
        self.playingStartFrames = playingStartFrames
        self.endSilenceFrames = endSilenceFrames
        self.prerollFrames = prerollFrames
        self.minSpeechFrames = minSpeechFrames
        self.postInterruptCooldownSeconds = postInterruptCooldownSeconds
    }
}

// MARK: - 客户端配置

struct ClientSettings: Codable, Sendable {
    var inputDeviceIndex: String
    var outputDeviceUID: String
    var audio: ClientAudioSettings
    var continuous: ClientContinuousSettings

    nonisolated init(
        inputDeviceIndex: String = "0",
        outputDeviceUID: String = "",
        audio: ClientAudioSettings = ClientAudioSettings(),
        continuous: ClientContinuousSettings = ClientContinuousSettings()
    ) {
        self.inputDeviceIndex = inputDeviceIndex
        self.outputDeviceUID = outputDeviceUID
        self.audio = audio
        self.continuous = continuous
    }
}

// MARK: - Loader

private struct ConfigurationLoader {
    nonisolated static let configPathEnvironmentKey = "IAGENT_CONFIG_PATH"

    nonisolated private static let defaultConfigJSON = """
    {
      "speechToText": {
        "apiKey": "",
        "flashUrl": "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash",
        "resourceId": "volc.bigasr.auc_turbo"
      },
      "textToSpeech": {
        "appId": "",
        "accessToken": "",
        "endpoint": "https://openspeech.bytedance.com/api/v3/tts/unidirectional",
        "resourceId": "seed-tts-2.0",
        "voiceType": "zh_female_tianmeitaozi_uranus_bigtts",
        "volume": 2.0
      }
    }
    """

    nonisolated static func load() -> Configuration {
        var config = Configuration()

        // 确保配置文件存在
        ensureConfigFileExists()

        do {
            if let fileURL = preferredConfigFileURL(), FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let object = try JSONSerialization.jsonObject(with: data)
                guard let override = object as? [String: Any] else {
                    throw ConfigurationError.invalidConfigFile("配置文件根节点必须是 JSON 对象")
                }
                config.apply(fileOverride: override)
            }
        } catch {
            print("[Configuration] \(ConfigurationError.invalidConfigFile(error.localizedDescription).localizedDescription)")
        }

        config.apply(environment: ProcessInfo.processInfo.environment)
        return config
    }

    private nonisolated static func preferredConfigFileURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment[configPathEnvironmentKey]?.trimmedNonEmpty {
            return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
        }

        // 优先读取 ~/.config/iAgent/config.json
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let xdgConfigDir = environment["XDG_CONFIG_HOME"] ?? "\(homeDir)/.config"
        return URL(fileURLWithPath: "\(xdgConfigDir)/iAgent/config.json")
    }

    private nonisolated static func ensureConfigFileExists() {
        guard let fileURL = preferredConfigFileURL() else { return }

        let filePath = fileURL.path
        let directoryPath = (filePath as NSString).deletingLastPathComponent

        // 创建目录
        if !FileManager.default.fileExists(atPath: directoryPath) {
            do {
                try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
            } catch {
                print("[Configuration] 创建配置目录失败: \(error.localizedDescription)")
                return
            }
        }

        // 如果文件不存在，创建默认配置文件
        if !FileManager.default.fileExists(atPath: filePath) {
            do {
                try defaultConfigJSON.write(toFile: filePath, atomically: true, encoding: .utf8)
                print("[Configuration] 已创建配置文件: \(filePath)")
                print("[Configuration] 请编辑该文件填入 API 凭证后重启应用")
            } catch {
                print("[Configuration] 创建配置文件失败: \(error.localizedDescription)")
            }
        }
    }

    nonisolated static func save(_ config: Configuration) {
        guard let fileURL = preferredConfigFileURL() else { return }
        let filePath = fileURL.path
        let directoryPath = (filePath as NSString).deletingLastPathComponent

        if !FileManager.default.fileExists(atPath: directoryPath) {
            do {
                try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: true)
            } catch {
                print("[Configuration] 创建配置目录失败: \(error.localizedDescription)")
                return
            }
        }

        do {
            let object: [String: Any] = [
                "speechToText": [
                    "apiKey": config.speechToText.apiKey,
                    "flashUrl": config.speechToText.flashUrl,
                    "resourceId": config.speechToText.resourceId
                ],
                "textToSpeech": [
                    "appId": config.textToSpeech.appId,
                    "accessToken": config.textToSpeech.accessToken,
                    "endpoint": config.textToSpeech.endpoint,
                    "resourceId": config.textToSpeech.resourceId,
                    "voiceType": config.textToSpeech.voiceType,
                    "volume": config.textToSpeech.volume
                ],
                "agent": [
                    "workdir": config.agent.workdir,
                    "timeoutSeconds": config.agent.timeoutSeconds
                ],
                "behavior": [
                    "enabled": config.behavior.enabled,
                    "routerSSHHost": config.behavior.routerSSHHost,
                    "monitoredPhoneMAC": config.behavior.monitoredPhoneMAC,
                    "monitoredWiFiInterfaces": config.behavior.monitoredWiFiInterfaces,
                    "pollIntervalSeconds": config.behavior.pollIntervalSeconds,
                    "contextTTLSeconds": config.behavior.contextTTLSeconds,
                    "cooldownSeconds": config.behavior.cooldownSeconds,
                    "requiredOnlineConfirmations": config.behavior.requiredOnlineConfirmations,
                    "requiredOfflineConfirmations": config.behavior.requiredOfflineConfirmations
                ],
                "client": [
                    "inputDeviceIndex": config.client.inputDeviceIndex,
                    "outputDeviceUID": config.client.outputDeviceUID,
                    "audio": [
                        "sampleRate": config.client.audio.sampleRate,
                        "channels": config.client.audio.channels,
                        "sampleWidth": config.client.audio.sampleWidth
                    ],
                    "continuous": [
                        "interruptOnSpeech": config.client.continuous.interruptOnSpeech,
                        "frameMs": config.client.continuous.frameMs,
                        "startThreshold": config.client.continuous.startThreshold,
                        "playingStartThreshold": config.client.continuous.playingStartThreshold,
                        "endThreshold": config.client.continuous.endThreshold,
                        "startFrames": config.client.continuous.startFrames,
                        "playingStartFrames": config.client.continuous.playingStartFrames,
                        "endSilenceFrames": config.client.continuous.endSilenceFrames,
                        "prerollFrames": config.client.continuous.prerollFrames,
                        "minSpeechFrames": config.client.continuous.minSpeechFrames,
                        "postInterruptCooldownSeconds": config.client.continuous.postInterruptCooldownSeconds
                    ]
                ]
            ]

            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[Configuration] 保存配置文件失败: \(error.localizedDescription)")
        }
    }
}

private final class ConfigurationStore: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var cached: Configuration = ConfigurationLoader.load()

    nonisolated var current: Configuration {
        lock.withLock { cached }
    }

    @discardableResult
    nonisolated func reload() -> Configuration {
        lock.withLock {
            cached = ConfigurationLoader.load()
            return cached
        }
    }

    nonisolated func update(_ mutate: (inout Configuration) -> Void) {
        lock.withLock {
            mutate(&cached)
            ConfigurationLoader.save(cached)
        }
    }
}

private extension Configuration {
    nonisolated mutating func apply(fileOverride: [String: Any]) {
        if let speechToText = fileOverride["speechToText"] as? [String: Any] {
            self.speechToText.apply(fileOverride: speechToText)
        }
        if let textToSpeech = fileOverride["textToSpeech"] as? [String: Any] {
            self.textToSpeech.apply(fileOverride: textToSpeech)
        }
        if let agent = fileOverride["agent"] as? [String: Any] {
            self.agent.apply(fileOverride: agent)
        }
        if let behavior = fileOverride["behavior"] as? [String: Any] {
            self.behavior.apply(fileOverride: behavior)
        }
        if let client = fileOverride["client"] as? [String: Any] {
            self.client.apply(fileOverride: client)
        }
    }

    nonisolated mutating func apply(environment: [String: String]) {
        speechToText.apiKey = environment["IAGENT_ASR_API_KEY"]?.trimmedNonEmpty ?? speechToText.apiKey
        speechToText.flashUrl = environment["IAGENT_ASR_FLASH_URL"]?.trimmedNonEmpty ?? speechToText.flashUrl
        speechToText.resourceId = environment["IAGENT_ASR_RESOURCE_ID"]?.trimmedNonEmpty ?? speechToText.resourceId

        textToSpeech.appId = environment["IAGENT_TTS_APP_ID"]?.trimmedNonEmpty ?? textToSpeech.appId
        textToSpeech.accessToken = environment["IAGENT_TTS_ACCESS_TOKEN"]?.trimmedNonEmpty ?? textToSpeech.accessToken
        textToSpeech.endpoint = environment["IAGENT_TTS_ENDPOINT"]?.trimmedNonEmpty ?? textToSpeech.endpoint
        textToSpeech.resourceId = environment["IAGENT_TTS_RESOURCE_ID"]?.trimmedNonEmpty ?? textToSpeech.resourceId
        textToSpeech.voiceType = environment["IAGENT_TTS_VOICE_TYPE"]?.trimmedNonEmpty ?? textToSpeech.voiceType

        agent.workdir = environment["IAGENT_AGENT_WORKDIR"]?.trimmedNonEmpty ?? agent.workdir
        agent.timeoutSeconds = environment["IAGENT_AGENT_TIMEOUT_SECONDS"].flatMap(Int.init) ?? agent.timeoutSeconds

        client.inputDeviceIndex = environment["IAGENT_CLIENT_INPUT_DEVICE_UID"]?.trimmedNonEmpty ?? client.inputDeviceIndex
        client.outputDeviceUID = environment["IAGENT_CLIENT_OUTPUT_DEVICE_UID"]?.trimmedNonEmpty ?? client.outputDeviceUID

        behavior.enabled = environment["IAGENT_BEHAVIOR_ENABLED"].flatMap(Self.boolValue) ?? behavior.enabled
        behavior.routerSSHHost = environment["IAGENT_BEHAVIOR_ROUTER_SSH_HOST"]?.trimmedNonEmpty ?? behavior.routerSSHHost
        behavior.monitoredPhoneMAC = environment["IAGENT_BEHAVIOR_PHONE_MAC"]?.trimmedNonEmpty ?? behavior.monitoredPhoneMAC
        behavior.monitoredWiFiInterfaces = environment["IAGENT_BEHAVIOR_WIFI_INTERFACES"]?.trimmedNonEmpty ?? behavior.monitoredWiFiInterfaces
        behavior.pollIntervalSeconds = environment["IAGENT_BEHAVIOR_POLL_INTERVAL_SECONDS"].flatMap(Double.init) ?? behavior.pollIntervalSeconds
        behavior.contextTTLSeconds = environment["IAGENT_BEHAVIOR_CONTEXT_TTL_SECONDS"].flatMap(Double.init) ?? behavior.contextTTLSeconds
        behavior.cooldownSeconds = environment["IAGENT_BEHAVIOR_COOLDOWN_SECONDS"].flatMap(Double.init) ?? behavior.cooldownSeconds
        behavior.requiredOnlineConfirmations = environment["IAGENT_BEHAVIOR_REQUIRED_ONLINE_CONFIRMATIONS"].flatMap(Int.init) ?? behavior.requiredOnlineConfirmations
        behavior.requiredOfflineConfirmations = environment["IAGENT_BEHAVIOR_REQUIRED_OFFLINE_CONFIRMATIONS"].flatMap(Int.init) ?? behavior.requiredOfflineConfirmations
    }

    nonisolated static func boolValue(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }
}

private extension SpeechToTextSettings {
    nonisolated mutating func apply(fileOverride: [String: Any]) {
        apiKey = fileOverride.stringValue(for: "apiKey") ?? apiKey
        flashUrl = fileOverride.stringValue(for: "flashUrl") ?? flashUrl
        resourceId = fileOverride.stringValue(for: "resourceId") ?? resourceId
    }
}

private extension TextToSpeechSettings {
    nonisolated mutating func apply(fileOverride: [String: Any]) {
        appId = fileOverride.stringValue(for: "appId") ?? appId
        accessToken = fileOverride.stringValue(for: "accessToken") ?? accessToken
        endpoint = fileOverride.stringValue(for: "endpoint") ?? endpoint
        resourceId = fileOverride.stringValue(for: "resourceId") ?? resourceId
        voiceType = fileOverride.stringValue(for: "voiceType") ?? voiceType
    }
}

private extension AgentSettings {
    nonisolated mutating func apply(fileOverride: [String: Any]) {
        workdir = fileOverride.stringValue(for: "workdir") ?? workdir
        timeoutSeconds = fileOverride.intValue(for: "timeoutSeconds") ?? timeoutSeconds
    }
}

private extension BehaviorSettings {
    nonisolated mutating func apply(fileOverride: [String: Any]) {
        enabled = fileOverride.boolValue(for: "enabled") ?? enabled
        routerSSHHost = fileOverride.stringValue(for: "routerSSHHost") ?? routerSSHHost
        monitoredPhoneMAC = fileOverride.stringValue(for: "monitoredPhoneMAC") ?? monitoredPhoneMAC
        monitoredWiFiInterfaces = fileOverride.stringValue(for: "monitoredWiFiInterfaces") ?? monitoredWiFiInterfaces
        pollIntervalSeconds = fileOverride.doubleValue(for: "pollIntervalSeconds") ?? pollIntervalSeconds
        contextTTLSeconds = fileOverride.doubleValue(for: "contextTTLSeconds") ?? contextTTLSeconds
        cooldownSeconds = fileOverride.doubleValue(for: "cooldownSeconds") ?? cooldownSeconds
        requiredOnlineConfirmations = fileOverride.intValue(for: "requiredOnlineConfirmations") ?? requiredOnlineConfirmations
        requiredOfflineConfirmations = fileOverride.intValue(for: "requiredOfflineConfirmations") ?? requiredOfflineConfirmations
    }
}

private extension ClientSettings {
    nonisolated mutating func apply(fileOverride: [String: Any]) {
        inputDeviceIndex = fileOverride.stringValue(for: "inputDeviceIndex") ?? inputDeviceIndex
        outputDeviceUID = fileOverride.stringValue(for: "outputDeviceUID") ?? outputDeviceUID
        if let audio = fileOverride["audio"] as? [String: Any] {
            self.audio.apply(fileOverride: audio)
        }
        if let continuous = fileOverride["continuous"] as? [String: Any] {
            self.continuous.apply(fileOverride: continuous)
        }
    }
}

private extension ClientAudioSettings {
    nonisolated mutating func apply(fileOverride: [String: Any]) {
        sampleRate = fileOverride.intValue(for: "sampleRate") ?? sampleRate
        channels = fileOverride.intValue(for: "channels") ?? channels
        sampleWidth = fileOverride.intValue(for: "sampleWidth") ?? sampleWidth
    }
}

private extension ClientContinuousSettings {
    nonisolated mutating func apply(fileOverride: [String: Any]) {
        interruptOnSpeech = fileOverride.boolValue(for: "interruptOnSpeech") ?? interruptOnSpeech
        frameMs = fileOverride.intValue(for: "frameMs") ?? frameMs
        startThreshold = fileOverride.intValue(for: "startThreshold") ?? startThreshold
        playingStartThreshold = fileOverride.intValue(for: "playingStartThreshold") ?? playingStartThreshold
        endThreshold = fileOverride.intValue(for: "endThreshold") ?? endThreshold
        startFrames = fileOverride.intValue(for: "startFrames") ?? startFrames
        playingStartFrames = fileOverride.intValue(for: "playingStartFrames") ?? playingStartFrames
        endSilenceFrames = fileOverride.intValue(for: "endSilenceFrames") ?? endSilenceFrames
        prerollFrames = fileOverride.intValue(for: "prerollFrames") ?? prerollFrames
        minSpeechFrames = fileOverride.intValue(for: "minSpeechFrames") ?? minSpeechFrames
        postInterruptCooldownSeconds = fileOverride.doubleValue(for: "postInterruptCooldownSeconds") ?? postInterruptCooldownSeconds
    }
}

private extension NSLock {
    nonisolated func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private extension String {
    nonisolated var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Dictionary where Key == String, Value == Any {
    nonisolated func stringValue(for key: String) -> String? {
        (self[key] as? String)?.trimmedNonEmpty
    }

    nonisolated func intValue(for key: String) -> Int? {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    nonisolated func doubleValue(for key: String) -> Double? {
        if let value = self[key] as? Double {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    nonisolated func boolValue(for key: String) -> Bool? {
        if let value = self[key] as? Bool {
            return value
        }
        if let value = self[key] as? NSNumber {
            return value.boolValue
        }
        return nil
    }
}
