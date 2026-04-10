//
//  TTSService.swift
//  iAgent
//
//  语音合成服务，对应 Python 版本的 tts.py
//  使用字节跳动 TTS API，支持 SSE 流式响应
//

import Foundation

// MARK: - 请求/响应模型

struct TTSRequest: Encodable, Sendable {
    let user: TTSRequest.TTSUser
    let namespace: String
    let reqParams: TTSRequest.TTSReqParams

    nonisolated init(
        user: TTSRequest.TTSUser,
        namespace: String,
        reqParams: TTSRequest.TTSReqParams
    ) {
        self.user = user
        self.namespace = namespace
        self.reqParams = reqParams
    }

    struct TTSUser: Encodable, Sendable {
        let uid: String
    }

    struct TTSReqParams: Encodable, Sendable {
        let text: String
        let speaker: String
        let audioParams: TTSRequest.TTSAudioParams

        enum CodingKeys: String, CodingKey {
            case text
            case speaker
            case audioParams = "audio_params"
        }
    }

    struct TTSAudioParams: Encodable, Sendable {
        let format: String
        let sampleRate: Int

        enum CodingKeys: String, CodingKey {
            case format
            case sampleRate = "sample_rate"
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(user, forKey: .user)
        try container.encode(namespace, forKey: .namespace)
        try container.encode(reqParams, forKey: .reqParams)
    }

    enum CodingKeys: String, CodingKey {
        case user
        case namespace
        case reqParams = "req_params"
    }
}

/// SSE 事件
struct SSEvent: Decodable, Sendable {
    let data: String?
    let code: Int?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case data
        case code
        case message
    }

    nonisolated init(data: String?, code: Int?, message: String?) {
        self.data = data
        self.code = code
        self.message = message
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(String.self, forKey: .data)
        code = try container.decodeIfPresent(Int.self, forKey: .code)
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }
}

// MARK: - 错误类型

enum TTSError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case noAudioData
    case synthesisFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 TTS URL"
        case .invalidResponse:
            return "无效的 TTS 响应"
        case .httpError(let statusCode):
            return "TTS HTTP 错误: \(statusCode)"
        case .noAudioData:
            return "TTS 未返回音频数据"
        case .synthesisFailed(let message):
            return "语音合成失败: \(message)"
        }
    }
}

// MARK: - 语音合成服务

actor TTSService {
    private static let requestTimeout: TimeInterval = 30

    struct Config {
        var appId: String
        var accessToken: String
        var resourceId: String
        var voiceType: String
        var endpoint: String

        static var `default`: Config {
            let settings = Configuration.shared.textToSpeech
            return Config(
                appId: settings.appId,
                accessToken: settings.accessToken,
                resourceId: settings.resourceId,
                voiceType: settings.voiceType,
                endpoint: settings.endpoint
            )
        }
    }

    private let config: Config
    private let session: URLSession

    init(config: Config = .default) {
        self.config = config
        self.session = URLSession.shared
    }

    /// 合成文本为音频
    /// - Parameter text: 要合成的文本
    /// - Returns: 合成的音频数据 (MP3)
    func synthesize(text: String) async throws -> Data {
        // SSE 流式请求
        guard let url = URL(string: config.endpoint) else {
            throw TTSError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.appId, forHTTPHeaderField: "X-Api-App-Id")
        request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(config.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.timeoutInterval = Self.requestTimeout

        // 构建请求体
        let requestPayload = TTSRequest(
            user: TTSRequest.TTSUser(uid: UUID().uuidString),
            namespace: "BidirectionalTTS",
            reqParams: TTSRequest.TTSReqParams(
                text: text,
                speaker: config.voiceType,
                audioParams: TTSRequest.TTSAudioParams(
                    format: "mp3",
                    sampleRate: 24000
                )
            )
        )

        request.httpBody = try JSONEncoder().encode(requestPayload)

        // 发送流式请求
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw TTSError.httpError(statusCode: httpResponse.statusCode)
        }

        // 解析 SSE 流
        return try await parseSSEStream(bytes)
    }

    /// 解析 SSE 流式响应
    private func parseSSEStream(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var audioChunks: [Data] = []
        var parseErrorCount = 0
        var eventDataLines: [String] = []

        func consumeBufferedEvent() throws -> Bool {
            guard !eventDataLines.isEmpty else { return true }
            let payload = eventDataLines.joined(separator: "\n")
            eventDataLines.removeAll(keepingCapacity: true)
            return try consumeEventPayload(
                payload,
                audioChunks: &audioChunks,
                parseErrorCount: &parseErrorCount
            )
        }

        func consumeRawLine(_ rawLine: String) throws -> Bool {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                return try consumeBufferedEvent()
            }

            if line.hasPrefix(":") {
                // SSE 注释行
                return true
            }

            if rawLine.hasPrefix("data:") || line.hasPrefix("data:") {
                let dataLine = rawLine.hasPrefix("data:") ? rawLine : line
                let start = dataLine.index(dataLine.startIndex, offsetBy: 5)
                var value = String(dataLine[start...])
                if value.first == " " {
                    value.removeFirst()
                }
                eventDataLines.append(value)
                return true
            }

            if line.hasPrefix("event:") || line.hasPrefix("id:") || line.hasPrefix("retry:") {
                // 目前不依赖这些元信息
                return true
            }

            // 兼容非标准流（直接逐行返回 JSON）
            if try !consumeBufferedEvent() {
                return false
            }
            return try consumeEventPayload(
                line,
                audioChunks: &audioChunks,
                parseErrorCount: &parseErrorCount
            )
        }

        var lineBuffer = Data()
        for try await byte in bytes {
            if byte == UInt8(ascii: "\n") {
                if lineBuffer.last == UInt8(ascii: "\r") {
                    lineBuffer.removeLast()
                }
                let rawLine = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                if try !consumeRawLine(rawLine) {
                    break
                }
                continue
            }
            lineBuffer.append(byte)
        }

        if !lineBuffer.isEmpty {
            if lineBuffer.last == UInt8(ascii: "\r") {
                lineBuffer.removeLast()
            }
            let rawLine = String(decoding: lineBuffer, as: UTF8.self)
            if try !consumeRawLine(rawLine) {
                // [DONE] 之类的终止事件在流末尾也生效
            }
        }

        if try !consumeBufferedEvent() {
            // [DONE] 之类的终止事件在流末尾也生效
        }

        guard !audioChunks.isEmpty else {
            throw TTSError.noAudioData
        }

        if parseErrorCount > 0 {
            print("[TTSService] 共跳过 \(parseErrorCount) 个无法解析的流事件")
        }

        var mergedAudio = Data()
        mergedAudio.reserveCapacity(audioChunks.reduce(0) { $0 + $1.count })
        for chunk in audioChunks {
            mergedAudio.append(chunk)
        }
        return mergedAudio
    }

    private func consumeEventPayload(
        _ payload: String,
        audioChunks: inout [Data],
        parseErrorCount: inout Int
    ) throws -> Bool {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed == "[DONE]" || trimmed == "\"[DONE]\"" {
            return false
        }

        guard let jsonData = trimmed.data(using: .utf8) else {
            parseErrorCount += 1
            if parseErrorCount <= 5 {
                print("[TTSService] 非 UTF8 事件，已忽略")
            }
            return true
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: jsonData)
        } catch {
            parseErrorCount += 1
            if parseErrorCount <= 5 {
                let snippet = String(trimmed.prefix(180))
                print("[TTSService] JSON 解析失败，事件=\(snippet)")
            }
            return true
        }

        if let errorMessage = extractTTSErrorMessage(from: object) {
            // 仅在当前事件没有可用音频数据时才作为错误抛出
            if extractAudioBase64(from: object) == nil {
                throw TTSError.synthesisFailed(errorMessage)
            }
        }

        if let audioBase64 = extractAudioBase64(from: object) {
            if let audioData = Data(base64Encoded: audioBase64) {
                audioChunks.append(audioData)
                return true
            }
            parseErrorCount += 1
            if parseErrorCount <= 5 {
                print("[TTSService] 音频 base64 解码失败，已忽略事件")
            }
        }

        return true
    }

    private func extractAudioBase64(from object: Any) -> String? {
        guard let dict = object as? [String: Any] else { return nil }

        if let data = dict["data"] as? String, !data.isEmpty {
            return data
        }
        if let audio = dict["audio"] as? String, !audio.isEmpty {
            return audio
        }
        if let audioData = dict["audio_data"] as? String, !audioData.isEmpty {
            return audioData
        }

        if let dataDict = dict["data"] as? [String: Any] {
            if let nested = extractAudioBase64(from: dataDict) {
                return nested
            }
        }
        if let resultDict = dict["result"] as? [String: Any] {
            if let nested = extractAudioBase64(from: resultDict) {
                return nested
            }
        }
        if let payloadDict = dict["payload"] as? [String: Any] {
            if let nested = extractAudioBase64(from: payloadDict) {
                return nested
            }
        }

        return nil
    }

    private func extractTTSErrorMessage(from object: Any) -> String? {
        guard let dict = object as? [String: Any] else { return nil }

        if let errorDict = dict["error"] as? [String: Any] {
            if let message = errorDict["message"] as? String, !message.isEmpty {
                return message
            }
            if let message = errorDict["msg"] as? String, !message.isEmpty {
                return message
            }
            return "TTS返回错误: \(errorDict)"
        }

        if let code = dict["code"] as? Int {
            if code == 0 || code == 20000000 {
                // 20000000 是服务端常见业务成功码，不应判错
            } else {
                let message = (dict["message"] as? String) ?? (dict["msg"] as? String) ?? ""
                let lower = message.lowercased()
                let looksLikeFailure =
                    lower.contains("error")
                    || lower.contains("fail")
                    || lower.contains("forbidden")
                    || lower.contains("invalid")
                    || lower.contains("quota")
                    || lower.contains("denied")
                    || lower.contains("unauthorized")
                    || message.contains("失败")
                    || message.contains("错误")
                    || message.contains("超限")
                    || message.contains("拒绝")
                    || message.contains("无效")
                    || code >= 4000
                if looksLikeFailure {
                    let finalMessage = message.isEmpty ? "code=\(code)" : message
                    return "TTS返回错误 code=\(code), message=\(finalMessage)"
                }
            }
        }

        if let result = dict["result"] as? [String: Any], let nestedError = extractTTSErrorMessage(from: result) {
            return nestedError
        }
        if let payload = dict["payload"] as? [String: Any], let nestedError = extractTTSErrorMessage(from: payload) {
            return nestedError
        }

        return nil
    }
}
