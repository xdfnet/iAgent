//
//  VoiceService.swift
//  iAgent
//
//  语音活动检测和麦克风捕获服务，对应 Python 版本的 voice.py
//  使用原生音频采集，RMS 能量检测实现 VAD
//

@preconcurrency import AVFoundation
import Darwin
import Foundation

/// 语音活动检测和捕获服务
actor VoiceService {
    private static let maxSpeechDurationSeconds = 8.0

    private enum NativeCaptureError: LocalizedError {
        case converterUnavailable
        case failedToStart(String)
        case streamClosed

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                return "原生音频格式转换器不可用"
            case .failedToStart(let message):
                return "原生音频采集启动失败: \(message)"
            case .streamClosed:
                return "原生音频流已关闭"
            }
        }
    }

    private final class NativeAudioCaptureSession {
        private let engine = AVAudioEngine()
        private let processingQueue = DispatchQueue(label: "iagent.voice.capture.processing")
        private let targetFormat: AVAudioFormat
        private let frameBytes: Int
        private var converter: AVAudioConverter?
        private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
        private var pendingData = Data()
        private var isRunning = false

        init(config: Config) {
            self.targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Double(config.sampleRate),
                channels: AVAudioChannelCount(config.channels),
                interleaved: true
            )!
            self.frameBytes = config.frameBytes
        }

        func start() throws -> AsyncThrowingStream<Data, Error> {
            guard !isRunning else {
                throw NativeCaptureError.failedToStart("采集会话已在运行")
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw NativeCaptureError.converterUnavailable
            }

            self.converter = converter
            self.pendingData.removeAll(keepingCapacity: true)

            let stream = AsyncThrowingStream<Data, Error> { continuation in
                self.continuation = continuation
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
                self?.processingQueue.async {
                    self?.handle(buffer: buffer)
                }
            }

            do {
                try engine.start()
                isRunning = true
                return stream
            } catch {
                inputNode.removeTap(onBus: 0)
                continuation?.finish(throwing: NativeCaptureError.failedToStart(error.localizedDescription))
                continuation = nil
                self.converter = nil
                throw NativeCaptureError.failedToStart(error.localizedDescription)
            }
        }

        func stop() {
            processingQueue.sync {
                isRunning = false
                pendingData.removeAll(keepingCapacity: false)
                converter = nil
                continuation?.finish()
                continuation = nil
            }

            let inputNode = engine.inputNode
            inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }

        private func handle(buffer: AVAudioPCMBuffer) {
            guard isRunning, let converter else { return }

            let inputRate = buffer.format.sampleRate
            let outputRate = targetFormat.sampleRate
            let estimatedFrameCapacity = max(
                AVAudioFrameCount((Double(buffer.frameLength) * outputRate / inputRate).rounded(.up)),
                1
            )

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: estimatedFrameCapacity + 32
            ) else {
                finish(throwing: NativeCaptureError.failedToStart("创建输出缓冲失败"))
                return
            }

            var conversionError: NSError?
            var didProvideInput = false
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if didProvideInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                didProvideInput = true
                outStatus.pointee = .haveData
                return buffer
            }

            if let conversionError {
                finish(throwing: NativeCaptureError.failedToStart(conversionError.localizedDescription))
                return
            }

            switch status {
            case .error:
                finish(throwing: NativeCaptureError.failedToStart("音频格式转换失败"))
                return
            case .haveData, .inputRanDry, .endOfStream:
                break
            @unknown default:
                break
            }

            guard outputBuffer.frameLength > 0 else { return }
            let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
            guard let mData = audioBuffer.mData else { return }

            pendingData.append(mData.assumingMemoryBound(to: UInt8.self), count: Int(audioBuffer.mDataByteSize))
            while pendingData.count >= frameBytes {
                let frame = pendingData.prefix(frameBytes)
                continuation?.yield(Data(frame))
                pendingData.removeFirst(frameBytes)
            }
        }

        private func finish(throwing error: Error) {
            guard continuation != nil else { return }
            isRunning = false
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }

    struct VoiceSegment: Sendable {
        let deviceID: String
        let audioData: Data
        let capturedAt: Date
    }

    enum State: Sendable {
        case idle
        case listening
        case speaking
        case processing
    }

    struct Config: Sendable {
        var sampleRate: Int = 16000
        var channels: Int = 1
        var sampleWidth: Int = 2
        var frameMs: Int = 30
        var startThreshold: Int = 2200
        var playingStartThreshold: Int = 4200
        var endThreshold: Int = 900
        var startFrames: Int = 7
        var playingStartFrames: Int = 10
        var endSilenceFrames: Int = 28
        var prerollFrames: Int = 14
        var minSpeechFrames: Int = 12
        var inputDeviceIndex: String = "0"

        static var `default`: Config {
            let settings = Configuration.shared.client.continuous
            let audioSettings = Configuration.shared.client.audio
            let clientSettings = Configuration.shared.client
            return Config(
                sampleRate: audioSettings.sampleRate,
                channels: audioSettings.channels,
                sampleWidth: audioSettings.sampleWidth,
                frameMs: settings.frameMs,
                startThreshold: settings.startThreshold,
                playingStartThreshold: settings.playingStartThreshold,
                endThreshold: settings.endThreshold,
                startFrames: settings.startFrames,
                playingStartFrames: settings.playingStartFrames,
                endSilenceFrames: settings.endSilenceFrames,
                prerollFrames: settings.prerollFrames,
                minSpeechFrames: settings.minSpeechFrames,
                inputDeviceIndex: clientSettings.inputDeviceIndex
            )
        }

        /// 每帧字节数 (sampleRate * frameMs/1000 * sampleWidth)
        var frameBytes: Int {
            sampleRate * frameMs / 1000 * sampleWidth * channels
        }

        /// 归一化后的输入设备 ID。
        /// 历史上配置支持 "auto" 和逗号分隔列表；当前产品路径只使用首个设备。
        var inputDeviceID: String {
            let trimmed = inputDeviceIndex.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "0"

            if trimmed.isEmpty || trimmed.lowercased() == "auto" {
                return fallback
            }

            return trimmed
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .first ?? fallback
        }
    }

    /// 状态流
    nonisolated let stateStream: AsyncStream<State>

    /// 语音片段流 - 当检测到语音片段时发出结构化结果（包含设备ID）
    nonisolated let segmentStream: AsyncStream<VoiceSegment>

    /// 错误流 - 语音采集关键错误
    nonisolated let errorStream: AsyncStream<String>

    /// 诊断流 - 非阻塞的调试/调参信息
    nonisolated let diagnosticStream: AsyncStream<String>

    private let config: Config
    private var stateContinuation: AsyncStream<State>.Continuation?
    private var segmentContinuation: AsyncStream<VoiceSegment>.Continuation?
    private var errorContinuation: AsyncStream<String>.Continuation?
    private var diagnosticContinuation: AsyncStream<String>.Continuation?
    private var isRunning = false
    private var captureTask: Task<Void, Never>?
    private var nativeCaptureSession: NativeAudioCaptureSession?
    private var playbackIsActive = false
    private var speechDetectionCooldownUntil: Date?
    private var speechDetectionSuspended = false
    private var awaitingTurnCompletion = false
    private var activeCaptureSessionID = 0
    private var pendingListeningResume = false

    init(config: Config = .default) {
        self.config = config

        var sc: AsyncStream<State>.Continuation?
        self.stateStream = AsyncStream { sc = $0; sc?.yield(.idle) }
        self.stateContinuation = sc

        var segc: AsyncStream<VoiceSegment>.Continuation?
        self.segmentStream = AsyncStream { segc = $0 }
        self.segmentContinuation = segc

        var errc: AsyncStream<String>.Continuation?
        self.errorStream = AsyncStream { errc = $0 }
        self.errorContinuation = errc

        var diagc: AsyncStream<String>.Continuation?
        self.diagnosticStream = AsyncStream { diagc = $0 }
        self.diagnosticContinuation = diagc
    }

    /// 销毁时安全清理资源
    func cleanup() {
        isRunning = false
        captureTask?.cancel()
        captureTask = nil
        nativeCaptureSession?.stop()
        nativeCaptureSession = nil
        speechDetectionCooldownUntil = nil
        speechDetectionSuspended = false
        awaitingTurnCompletion = false
        pendingListeningResume = false
        activeCaptureSessionID += 1
    }

    /// 启动持续监听
    func startListening() async throws {
        guard !isRunning else { return }

        isRunning = true
        speechDetectionSuspended = false
        awaitingTurnCompletion = false
        pendingListeningResume = false
        activeCaptureSessionID += 1
        let sessionID = activeCaptureSessionID

        captureTask = Task { [weak self] in
            await self?.runCaptureLoop(sessionID: sessionID)
        }
    }

    /// 停止监听
    func stopListening() async {
        isRunning = false
        captureTask?.cancel()
        captureTask = nil

        nativeCaptureSession?.stop()
        nativeCaptureSession = nil
        speechDetectionCooldownUntil = nil
        speechDetectionSuspended = false
        awaitingTurnCompletion = false
        pendingListeningResume = false
        activeCaptureSessionID += 1

        stateContinuation?.yield(.idle)
    }

    func setPlaybackActive(_ isActive: Bool) {
        playbackIsActive = isActive
    }

    func setSpeechDetectionCooldown(seconds: Double) {
        speechDetectionCooldownUntil = Date().addingTimeInterval(seconds)
    }

    func setSpeechDetectionSuspended(_ suspended: Bool, cooldownSeconds: Double? = nil) {
        speechDetectionSuspended = suspended
        if let cooldownSeconds {
            let nextCooldownUntil = Date().addingTimeInterval(cooldownSeconds)
            if let currentCooldownUntil = speechDetectionCooldownUntil {
                speechDetectionCooldownUntil = max(currentCooldownUntil, nextCooldownUntil)
            } else {
                speechDetectionCooldownUntil = nextCooldownUntil
            }
        } else if !suspended {
            speechDetectionCooldownUntil = nil
        }

        if !suspended, pendingListeningResume, isRunning {
            awaitingTurnCompletion = false
            pendingListeningResume = false
            stateContinuation?.yield(.listening)
        }
    }

    /// 运行捕获循环
    private func runCaptureLoop(sessionID: Int) async {
        await runNativeCaptureLoop(sessionID: sessionID)
    }

    private func runNativeCaptureLoop(sessionID: Int) async {
        let deviceID = config.inputDeviceID
        Logger.log("开始原生音频采集...", category: .voice)
        Logger.log("输入设备: \(deviceID)", category: .voice)
        Logger.log("采样率: \(config.sampleRate)", category: .voice)

        let session = NativeAudioCaptureSession(config: config)
        nativeCaptureSession = session

        let frameStream: AsyncThrowingStream<Data, Error>
        do {
            frameStream = try session.start()
        } catch {
            let message = error.localizedDescription
            Logger.log(message, category: .voice, level: .error)
            reportError(message)
            finishCaptureSessionIfCurrent(sessionID)
            return
        }

        Logger.log("原生音频采集已启动", category: .voice)
        stateContinuation?.yield(.listening)

        await captureOnNativeStream(frameStream, deviceID: deviceID, sessionID: sessionID)

        session.stop()
        finishCaptureSessionIfCurrent(sessionID)
    }

    private func captureOnNativeStream(
        _ frameStream: AsyncThrowingStream<Data, Error>,
        deviceID: String,
        sessionID: Int
    ) async {
        let zeroRMSFallbackFrameThreshold = max(1, Int((8.0 * 1000.0) / Double(max(1, config.frameMs))))
        var preroll: [Data] = []
        var speechFrames: [Data] = []
        var inSpeech = false
        var hotFrames = 0
        var silenceFrames = 0
        var segmentIndex = 0
        var segmentPeakLevel = 0
        var segmentThreshold = config.startThreshold
        var zeroLevelFrames = 0
        var adaptiveStartThreshold = config.startThreshold
        var adaptivePlayingStartThreshold = config.playingStartThreshold
        var adaptiveEndThreshold = config.endThreshold
        var adaptiveWindowMaxLevel = 0
        var adaptiveWindowFrames = 0
        var adaptiveWindowLevelTotal = 0
        let adaptiveWindowFrameCount = max(1, Int((4.0 * 1000.0) / Double(max(1, config.frameMs))))
        preroll.reserveCapacity(config.prerollFrames)

        var iterator = frameStream.makeAsyncIterator()
        var localIsRunning = true

        while localIsRunning {
            let frameData: Data
            do {
                guard let nextFrame = try await iterator.next(), nextFrame.count == config.frameBytes else {
                    let message = NativeCaptureError.streamClosed.localizedDescription
                    Logger.log(message, category: .voice, level: .error)
                    reportError(message)
                    break
                }
                frameData = nextFrame
            } catch {
                let message = error.localizedDescription
                Logger.log(message, category: .voice, level: .error)
                reportError(message)
                break
            }

            localIsRunning = isRunning && sessionID == activeCaptureSessionID
            let level = calculateRMS(frame: frameData)
            let playing = playbackIsActive

            if segmentIndex % 100 == 0 && silenceFrames == 0 {
                let debugThreshold = playing ? adaptivePlayingStartThreshold : adaptiveStartThreshold
                Logger.log("RMS level: \(level), threshold: \(debugThreshold), device: \(deviceID)", category: .voice)
            }

            if !inSpeech {
                adaptiveWindowFrames += 1
                adaptiveWindowLevelTotal += level
                if level > adaptiveWindowMaxLevel {
                    adaptiveWindowMaxLevel = level
                }
                if adaptiveWindowFrames >= adaptiveWindowFrameCount {
                    let adaptiveWindowAverageLevel = adaptiveWindowLevelTotal / max(1, adaptiveWindowFrames)
                    let dynamicMargin = max(60, (adaptiveWindowMaxLevel - adaptiveWindowAverageLevel) / 2)
                    let shouldTuneDown = adaptiveWindowMaxLevel > 0 && adaptiveWindowMaxLevel < max(180, adaptiveStartThreshold)
                    if shouldTuneDown {
                        let tunedStart = max(120, adaptiveWindowAverageLevel + dynamicMargin)
                        let nextStartThreshold = min(adaptiveStartThreshold, tunedStart)
                        let nextPlayingThreshold = min(
                            adaptivePlayingStartThreshold,
                            max(nextStartThreshold + 80, nextStartThreshold * 2)
                        )
                        let nextEndThreshold = min(adaptiveEndThreshold, max(30, nextStartThreshold / 4))

                        if nextStartThreshold < adaptiveStartThreshold ||
                            nextPlayingThreshold < adaptivePlayingStartThreshold ||
                            nextEndThreshold < adaptiveEndThreshold {
                            adaptiveStartThreshold = nextStartThreshold
                            adaptivePlayingStartThreshold = nextPlayingThreshold
                            adaptiveEndThreshold = nextEndThreshold
                            let tuneMessage =
                                "自动调低VAD阈值: start \(config.startThreshold)->\(adaptiveStartThreshold), " +
                                "playing \(config.playingStartThreshold)->\(adaptivePlayingStartThreshold), " +
                                "end \(config.endThreshold)->\(adaptiveEndThreshold), " +
                                "avgRMS=\(adaptiveWindowAverageLevel), maxRMS=\(adaptiveWindowMaxLevel)"
                            reportDiagnostic(tuneMessage)
                            Logger.log(tuneMessage, category: .voice)
                        }
                    }
                    adaptiveWindowFrames = 0
                    adaptiveWindowMaxLevel = 0
                    adaptiveWindowLevelTotal = 0
                }

                if level == 0 {
                    zeroLevelFrames += 1
                } else {
                    zeroLevelFrames = 0
                }

                if zeroLevelFrames >= zeroRMSFallbackFrameThreshold {
                    let message = "持续检测到零能量音频(设备 \(deviceID))，可能输入源异常"
                    reportError(message)
                    Logger.log(message, category: .voice, level: .error)
                    break
                }
            } else {
                zeroLevelFrames = 0
            }

            if preroll.count >= config.prerollFrames {
                preroll.removeFirst()
            }
                preroll.append(frameData)

            if !inSpeech {
                if speechDetectionSuspended || awaitingTurnCompletion {
                    hotFrames = 0
                    continue
                }
                if let speechDetectionCooldownUntil, Date() < speechDetectionCooldownUntil {
                    hotFrames = 0
                    continue
                }

                let threshold = playing ? adaptivePlayingStartThreshold : adaptiveStartThreshold
                let requiredFrames = playing ? config.playingStartFrames : config.startFrames

                if level >= threshold {
                    hotFrames += 1
                } else {
                    hotFrames = 0
                }

                if hotFrames >= requiredFrames {
                    inSpeech = true
                    silenceFrames = 0
                    speechFrames = preroll
                    preroll.removeAll()
                    hotFrames = 0
                    segmentPeakLevel = level
                    segmentThreshold = threshold
                    Logger.log("检测到语音！hotFrames: \(hotFrames), required: \(requiredFrames)", category: .voice)
                    stateContinuation?.yield(.speaking)
                }
            } else {
                speechFrames.append(frameData)
                if level > segmentPeakLevel {
                    segmentPeakLevel = level
                }

                let effectiveEndThreshold = max(
                    adaptiveEndThreshold,
                    min(max(adaptiveEndThreshold + 24, segmentThreshold - 60), max(adaptiveEndThreshold + 24, segmentPeakLevel / 2))
                )

                if level <= effectiveEndThreshold {
                    silenceFrames += 1
                } else {
                    silenceFrames = 0
                }

                let segmentDurationSeconds = Double(speechFrames.count * config.frameMs) / 1000.0
                let reachedNaturalEnd = speechFrames.count >= config.minSpeechFrames && silenceFrames >= config.endSilenceFrames
                let reachedForcedEnd = segmentDurationSeconds >= Self.maxSpeechDurationSeconds

                if reachedNaturalEnd || reachedForcedEnd {
                    segmentIndex += 1
                    let endReason = reachedForcedEnd ? "forced-timeout" : "silence"
                    Logger.log("语音片段结束，共 \(speechFrames.count) 帧，reason=\(endReason)", category: .voice)
                    speechDetectionSuspended = true
                    awaitingTurnCompletion = true
                    pendingListeningResume = true
                    stateContinuation?.yield(.processing)

                    let audioData = concatenateFrames(speechFrames)
                    let segment = VoiceSegment(
                        deviceID: deviceID,
                        audioData: audioData,
                        capturedAt: Date()
                    )
                    Logger.log(
                        "segment[\(segmentIndex)] duration=\(String(format: "%.2f", segmentDurationSeconds))s " +
                        "peakRMS=\(segmentPeakLevel) startThreshold=\(segmentThreshold) endThreshold=\(effectiveEndThreshold)",
                        category: .voice
                    )

                    segmentContinuation?.yield(segment)

                    inSpeech = false
                    speechFrames.removeAll()
                    hotFrames = 0
                    silenceFrames = 0
                    preroll.removeAll()
                    segmentPeakLevel = 0
                    segmentThreshold = config.startThreshold
                }
            }
        }
    }

    private func readFrame(fileHandle: FileHandle, expectedBytes: Int, timeoutMs: UInt64) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async { [self] in
                let data = self.readFrameSynchronously(
                    fileDescriptor: fileHandle.fileDescriptor,
                    expectedBytes: expectedBytes,
                    timeoutMs: timeoutMs
                )
                continuation.resume(returning: data)
            }
        }
    }

    private nonisolated func readFrameSynchronously(
        fileDescriptor: Int32,
        expectedBytes: Int,
        timeoutMs: UInt64
    ) -> Data? {
        guard expectedBytes > 0 else { return Data() }

        let deadline = DispatchTime.now().uptimeNanoseconds + (timeoutMs * 1_000_000)
        var totalData = Data(capacity: expectedBytes)

        while totalData.count < expectedBytes {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline {
                return nil
            }

            let remainingMs = max(1, Int32((deadline - now) / 1_000_000))
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&descriptor, 1, remainingMs)

            if pollResult == 0 {
                return nil
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }

            if (descriptor.revents & Int16(POLLERR | POLLNVAL)) != 0 {
                return nil
            }
            if (descriptor.revents & Int16(POLLHUP)) != 0 && (descriptor.revents & Int16(POLLIN)) == 0 {
                return nil
            }
            guard (descriptor.revents & Int16(POLLIN)) != 0 else {
                continue
            }

            let chunkSize = min(4096, expectedBytes - totalData.count)
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            let readCount = Darwin.read(fileDescriptor, &buffer, chunkSize)
            if readCount <= 0 {
                return nil
            }
            totalData.append(buffer, count: readCount)
        }

        return totalData
    }

    /// 计算 RMS - 使用 AudioProcessor
    private nonisolated func calculateRMS(frame: Data) -> Int {
        AudioProcessor.calculateRMS(frame: frame)
    }

    /// 合并帧
    private nonisolated func concatenateFrames(_ frames: [Data]) -> Data {
        var result = Data()
        for frame in frames {
            result.append(frame)
        }
        return result
    }

    private func finishCaptureSessionIfCurrent(_ sessionID: Int) {
        guard sessionID == activeCaptureSessionID else { return }
        isRunning = false
        nativeCaptureSession = nil
        awaitingTurnCompletion = false
        pendingListeningResume = false
        stateContinuation?.yield(.idle)
    }

    private func reportError(_ message: String) {
        errorContinuation?.yield(message)
    }

    private func reportDiagnostic(_ message: String) {
        diagnosticContinuation?.yield(message)
    }

    /// 当前是否正在监听
    var isListening: Bool {
        isRunning
    }

    /// VAD 检测是否被暂停
    var isDetectionSuspended: Bool {
        speechDetectionSuspended
    }

}

#if DEBUG
extension VoiceService {
    func _setIsRunningForTesting(_ value: Bool) {
        isRunning = value
    }

    func _emitErrorForTesting(_ message: String) {
        reportError(message)
    }

    func _emitDiagnosticForTesting(_ message: String) {
        reportDiagnostic(message)
    }

    func _emitSegmentForTesting(_ segment: VoiceSegment) {
        _ = segmentContinuation?.yield(segment)
    }
}
#endif
