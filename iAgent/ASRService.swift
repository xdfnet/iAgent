//
//  ASRService.swift
//  iAgent
//
//  语音识别服务，对应 Python 版本的 asr.py
//  使用字节跳动 ASR API
//

import Foundation

// MARK: - 请求/响应模型

struct ASRRequest: Encodable, Sendable {
    let user: ASRRequest.UserInfo
    let audio: ASRRequest.AudioInfo
    let request: ASRRequest.RequestInfo

    nonisolated init(
        user: ASRRequest.UserInfo,
        audio: ASRRequest.AudioInfo,
        request: ASRRequest.RequestInfo
    ) {
        self.user = user
        self.audio = audio
        self.request = request
    }

    struct UserInfo: Encodable, Sendable {
        let uid: String
    }

    struct AudioInfo: Encodable, Sendable {
        let data: String
        let format: String
        let codec: String
        let rate: Int
        let bits: Int
        let channel: Int
    }

    struct RequestInfo: Encodable, Sendable {
        let modelName: String = "bigmodel"
        let enableItn: Bool = true
        let enablePunc: Bool = true
        let enableDdc: Bool = false
        let enableSpeakerInfo: Bool = false
        let enableChannelSplit: Bool = false
        let showUtterances: Bool = false
        let vadSegment: Bool = false
        let sensitiveWordsFilter: String = ""

        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case enableItn = "enable_itn"
            case enablePunc = "enable_punc"
            case enableDdc = "enable_ddc"
            case enableSpeakerInfo = "enable_speaker_info"
            case enableChannelSplit = "enable_channel_split"
            case showUtterances = "show_utterances"
            case vadSegment = "vad_segment"
            case sensitiveWordsFilter = "sensitive_words_filter"
        }

        nonisolated init() {}
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(user, forKey: .user)
        try container.encode(audio, forKey: .audio)
        try container.encode(request, forKey: .request)
    }

    enum CodingKeys: String, CodingKey {
        case user
        case audio
        case request
    }
}

struct ASRResponse: Decodable, Sendable {
    let result: ASRResult?

    nonisolated init(result: ASRResult?) {
        self.result = result
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decodeIfPresent(ASRResult.self, forKey: .result)
    }

    enum CodingKeys: String, CodingKey {
        case result
    }

    struct ASRResult: Decodable, Sendable {
        let text: String?
        let utterances: [Utterance]?

        nonisolated init(text: String?, utterances: [Utterance]?) {
            self.text = text
            self.utterances = utterances
        }

        nonisolated init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decodeIfPresent(String.self, forKey: .text)
            utterances = try container.decodeIfPresent([Utterance].self, forKey: .utterances)
        }

        enum CodingKeys: String, CodingKey {
            case text
            case utterances
        }

        struct Utterance: Decodable, Sendable {
            let text: String?

            nonisolated init(text: String?) {
                self.text = text
            }

            nonisolated init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                text = try container.decodeIfPresent(String.self, forKey: .text)
            }

            enum CodingKeys: String, CodingKey {
                case text
            }
        }
    }
}

// MARK: - 错误类型

enum ASRError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case noResult
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的 ASR URL"
        case .invalidResponse:
            return "无效的响应"
        case .httpError(let statusCode, let message):
            return "HTTP 错误 \(statusCode): \(message)"
        case .noResult:
            return "ASR 未返回结果"
        case .decodingError:
            return "响应解析失败"
        }
    }
}

// MARK: - 语音识别服务

actor ASRService {
    private static let requestTimeout: TimeInterval = 20

    struct Config {
        var apiKey: String
        var resourceId: String
        var flashUrl: String

        static var `default`: Config {
            let settings = Configuration.shared.speechToText
            return Config(
                apiKey: settings.apiKey,
                resourceId: settings.resourceId,
                flashUrl: settings.flashUrl
            )
        }
    }

    private let config: Config
    private let session: URLSession

    init(config: Config = .default) {
        self.config = config
        self.session = URLSession.shared
    }

    /// 识别音频数据
    /// - Parameters:
    ///   - audioData: 音频数据
    ///   - format: 音频格式 (wav, ogg, mp3)
    /// - Returns: 识别出的文本
    func transcribe(audioData: Data, format: AudioFormat = .pcm) async throws -> String {
        let audioSettings = Configuration.shared.client.audio
        let requestAudio = buildRequestAudio(
            audioData: audioData,
            format: format,
            sampleRate: audioSettings.sampleRate,
            channels: audioSettings.channels,
            bitsPerSample: audioSettings.sampleWidth * 8
        )
        let base64Audio = requestAudio.data.base64EncodedString()

        // 构建请求体
        let requestPayload = ASRRequest(
            user: ASRRequest.UserInfo(uid: "iagent"),
            audio: ASRRequest.AudioInfo(
                data: base64Audio,
                format: requestAudio.format,
                codec: requestAudio.codec,
                rate: requestAudio.rate,
                bits: requestAudio.bits,
                channel: requestAudio.channel
            ),
            request: ASRRequest.RequestInfo()
        )

        // 编码请求
        let encoder = JSONEncoder()
        let requestBody = try encoder.encode(requestPayload)

        // 构建请求
        guard let url = URL(string: config.flashUrl) else {
            throw ASRError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(config.resourceId, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.timeoutInterval = Self.requestTimeout
        request.httpBody = requestBody

        // 发送请求
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ASRError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ASRError.httpError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // 解析响应
        return try parseResponse(data)
    }

    /// 解析 ASR 响应
    private func parseResponse(_ data: Data) throws -> String {
        // 先按强类型结构解析
        if
            let response = try? JSONDecoder().decode(ASRResponse.self, from: data),
            let text = extractText(from: response)
        {
            return text
        }

        // 再走宽松 JSON 解析，兼容接口字段变体
        if
            let object = try? JSONSerialization.jsonObject(with: data),
            let text = extractTextFromJSONObject(object)
        {
            return text
        }

        if let body = String(data: data, encoding: .utf8) {
            let snippet = String(body.prefix(300))
            print("[ASRService] no-result payload snippet: \(snippet)")
        }

        throw ASRError.noResult
    }

    private struct RequestAudio {
        let data: Data
        let format: String
        let codec: String
        let rate: Int
        let bits: Int
        let channel: Int
    }

    private func buildRequestAudio(
        audioData: Data,
        format: AudioFormat,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> RequestAudio {
        switch format {
        case .pcm:
            // 豆包 ASR 在实测里对 WAV 容器更稳定，避免出现 200 但空结果
            let wavData = wrapPCMAsWAV(
                pcmData: audioData,
                sampleRate: sampleRate,
                channels: channels,
                bitsPerSample: bitsPerSample
            )
            return RequestAudio(
                data: wavData,
                format: AudioFormat.wav.rawValue,
                codec: "raw",
                rate: sampleRate,
                bits: bitsPerSample,
                channel: channels
            )
        case .wav:
            return RequestAudio(
                data: audioData,
                format: format.rawValue,
                codec: "raw",
                rate: sampleRate,
                bits: bitsPerSample,
                channel: channels
            )
        case .ogg:
            return RequestAudio(
                data: audioData,
                format: format.rawValue,
                codec: "opus",
                rate: sampleRate,
                bits: bitsPerSample,
                channel: channels
            )
        case .mp3:
            return RequestAudio(
                data: audioData,
                format: format.rawValue,
                codec: "mp3",
                rate: sampleRate,
                bits: bitsPerSample,
                channel: channels
            )
        }
    }

    private func extractText(from response: ASRResponse) -> String? {
        if let text = normalized(response.result?.text) {
            return text
        }
        if let utterances = response.result?.utterances {
            let joined = utterances.compactMap { normalized($0.text) }.joined(separator: " ")
            if let merged = normalized(joined) {
                return merged
            }
        }
        return nil
    }

    private func extractTextFromJSONObject(_ object: Any) -> String? {
        guard let root = object as? [String: Any] else { return nil }

        if let result = root["result"] as? [String: Any] {
            if let text = normalized(result["text"] as? String) {
                return text
            }
            if let utterances = joinedUtterances(from: result["utterances"]) {
                return utterances
            }
            if let nbestText = firstNBestText(from: result["nbest"]) {
                return nbestText
            }
        }

        if let text = normalized(root["text"] as? String) {
            return text
        }
        if let utterances = joinedUtterances(from: root["utterances"]) {
            return utterances
        }
        if let nbestText = firstNBestText(from: root["nbest"]) {
            return nbestText
        }

        if
            let data = root["data"] as? [String: Any],
            let nested = extractTextFromJSONObject(data)
        {
            return nested
        }

        return nil
    }

    private func joinedUtterances(from value: Any?) -> String? {
        guard let utterances = value as? [[String: Any]], !utterances.isEmpty else { return nil }
        let joined = utterances.compactMap { normalized($0["text"] as? String) }.joined(separator: " ")
        return normalized(joined)
    }

    private func firstNBestText(from value: Any?) -> String? {
        guard let nbest = value as? [[String: Any]], let first = nbest.first else { return nil }
        return normalized(first["text"] as? String)
    }

    private func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func wrapPCMAsWAV(
        pcmData: Data,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> Data {
        let subchunk1Size: UInt32 = 16
        let audioFormatPCM: UInt16 = 1
        let channelCount = UInt16(clamping: channels)
        let bits = UInt16(clamping: bitsPerSample)
        let sampleRateLE = UInt32(clamping: sampleRate)
        let byteRate = sampleRateLE * UInt32(channelCount) * UInt32(bits) / 8
        let blockAlign = UInt16((UInt32(channelCount) * UInt32(bits)) / 8)
        let dataSize = UInt32(clamping: pcmData.count)
        let riffChunkSize = UInt32(36) + dataSize

        var wav = Data()
        wav.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(riffChunkSize, to: &wav)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        appendLittleEndian(subchunk1Size, to: &wav)
        appendLittleEndian(audioFormatPCM, to: &wav)
        appendLittleEndian(channelCount, to: &wav)
        appendLittleEndian(sampleRateLE, to: &wav)
        appendLittleEndian(byteRate, to: &wav)
        appendLittleEndian(blockAlign, to: &wav)
        appendLittleEndian(bits, to: &wav)
        wav.append(contentsOf: Array("data".utf8))
        appendLittleEndian(dataSize, to: &wav)
        wav.append(pcmData)
        return wav
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
