//
//  PlaybackService.swift
//  iAgent
//
//  音频播放服务，对应 Python 版本的 playback.py
//

import Foundation
import AVFoundation

private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let didFinish: @Sendable (Bool) -> Void

    init(didFinish: @escaping @Sendable (Bool) -> Void) {
        self.didFinish = didFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        didFinish(flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        didFinish(false)
    }
}

enum PlaybackError: Error, LocalizedError, Equatable {
    case waitTimeout

    var errorDescription: String? {
        switch self {
        case .waitTimeout:
            return "播放等待超时"
        }
    }
}

/// 音频播放服务
actor PlaybackService {
    private static let minimumWaitTimeoutSeconds = 30.0
    private static let durationTimeoutBufferSeconds = 8.0
    private static let fallbackWaitTimeoutSeconds = 120.0

    enum State: Sendable, Equatable {
        case idle
        case playing
    }

    nonisolated let stateStream: AsyncStream<State>

    /// 播放音量 (0.0 - 1.0, 默认 1.0)
    var volume: Float = 1.0

    private var currentPlayer: AVAudioPlayer?
    private var currentPlayerDelegate: PlaybackDelegate?
    private var currentPlayerToken: UUID?
    private var currentProcess: Process?
    private var state: State = .idle
    private var currentTempFileURL: URL?
    private var afplayWaitTask: Task<Void, Never>?
    private var stateContinuation: AsyncStream<State>.Continuation?
#if DEBUG
    private var forcePlayerStartFailureForTesting = false
#endif

    init() {
        var continuation: AsyncStream<State>.Continuation?
        self.stateStream = AsyncStream { continuation = $0; continuation?.yield(.idle) }
        self.stateContinuation = continuation
        // 从配置读取音量
        self.volume = Configuration.shared.textToSpeech.volume
    }

    /// 设置播放音量
    func setVolume(_ volume: Float) {
        self.volume = max(0.0, min(1.0, volume))
    }

    /// 当前是否正在播放
    var isPlaying: Bool {
        if let player = currentPlayer {
            return player.isPlaying
        }
        if let process = currentProcess, process.isRunning {
            return true
        }
        return false
    }

    /// 播放音频文件
    /// - Parameters:
    ///   - url: 音频文件 URL
    ///   - interrupt: 是否打断当前播放
    func play(url: URL, interrupt: Bool = true) async throws {
        let data = try Data(contentsOf: url)
        try await play(data: data, interrupt: interrupt)
    }

    /// 播放音频数据
    /// - Parameters:
    ///   - data: 音频数据
    ///   - interrupt: 是否打断当前播放
    func play(data: Data, interrupt: Bool = true) async throws {
        if interrupt {
            stop()
        } else {
            try await waitUntilFinished()
        }

        guard let player = try? AVAudioPlayer(data: data) else {
            // Fallback: 使用 afplay
            try await playWithAfplay(data: data)
            return
        }

        let token = UUID()
        let currentVolume = volume
        let delegate = await MainActor.run {
            PlaybackDelegate { [weak self, token] _ in
                Task {
                    await self?.handlePlayerFinished(token: token)
                }
            }
        }

        await MainActor.run {
            player.delegate = delegate
            player.volume = currentVolume
        }
        currentPlayerDelegate = delegate
        currentPlayerToken = token
        currentPlayer = player
        updateState(.playing)

        let startedPlaying: Bool
#if DEBUG
        if forcePlayerStartFailureForTesting {
            startedPlaying = false
        } else {
            startedPlaying = player.play()
        }
#else
        startedPlaying = player.play()
#endif

        guard startedPlaying else {
            currentPlayer = nil
            currentPlayerDelegate = nil
            currentPlayerToken = nil
            updateState(.idle)
            try await playWithAfplay(data: data)
            return
        }
    }

    /// 使用 afplay 播放音频数据（写入临时文件后播放）
    private func playWithAfplay(data: Data) async throws {
        let tempURL = AudioProcessor.tempFileURL(prefix: "playback", ext: "mp3")
        try data.write(to: tempURL)
        currentTempFileURL = tempURL
        try await playWithAfplay(url: tempURL)
    }

    /// 使用 afplay 播放音频文件
    private func playWithAfplay(url: URL) async throws {
        stop()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        // afplay -v 音量范围 0.0 - 6.0 (可以大于1.0)
        process.arguments = ["-v", String(volume), url.path]

        try process.run()
        currentProcess = process
        updateState(.playing)
        afplayWaitTask = Task { [weak self] in
            process.waitUntilExit()
            await self?.finishAfplayPlayback(for: process)
        }
    }

    private func finishAfplayPlayback(for process: Process) {
        guard currentProcess === process else { return }
        currentProcess = nil
        afplayWaitTask = nil
        cleanupTempFile()
        updateState(.idle)
    }

    private func handlePlayerFinished(token: UUID) {
        guard currentPlayerToken == token else { return }
        currentPlayer?.stop()
        currentPlayer = nil
        currentPlayerDelegate = nil
        currentPlayerToken = nil
        updateState(.idle)
    }

    /// 清理临时文件
    private func cleanupTempFile() {
        if let url = currentTempFileURL {
            try? FileManager.default.removeItem(at: url)
            currentTempFileURL = nil
        }
    }

    /// 停止当前播放
    /// - Returns: 是否成功停止
    @discardableResult
    func stop() -> Bool {
        afplayWaitTask?.cancel()
        afplayWaitTask = nil

        // 停止 AVAudioPlayer
        currentPlayer?.stop()
        currentPlayer = nil
        currentPlayerDelegate = nil
        currentPlayerToken = nil

        // 停止 afplay 进程
        if let process = currentProcess, process.isRunning {
            process.terminate()
            if process.isRunning {
                process.interrupt()
            }
        }
        currentProcess = nil

        updateState(.idle)
        cleanupTempFile()
        return true
    }

    /// 等待当前播放结束
    func waitUntilFinished(timeoutSeconds: Double? = nil) async throws {
        let effectiveTimeout = timeoutSeconds ?? suggestedWaitTimeoutSeconds()
        let deadline = Date().addingTimeInterval(effectiveTimeout)
        while isPlaying {
            if Date() >= deadline {
                stop()
                throw PlaybackError.waitTimeout
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func updateState(_ newState: State) {
        guard state != newState else { return }
        state = newState
        stateContinuation?.yield(newState)
    }

    private func suggestedWaitTimeoutSeconds() -> Double {
        if let player = currentPlayer {
            return max(
                Self.minimumWaitTimeoutSeconds,
                player.duration + Self.durationTimeoutBufferSeconds
            )
        }

        if currentProcess != nil {
            return Self.fallbackWaitTimeoutSeconds
        }

        return Self.minimumWaitTimeoutSeconds
    }
}

// MARK: - 便捷扩展

extension PlaybackService {
    /// 合成并播放文本
    /// - Parameters:
    ///   - text: 要播报的文本
    ///   - ttsService: TTS 服务实例
    ///   - interrupt: 是否打断当前播放
    func synthesizeAndPlay(
        text: String,
        using ttsService: TTSService,
        interrupt: Bool = true
    ) async throws {
        let audioData = try await ttsService.synthesize(text: text)
        try await play(data: audioData, interrupt: interrupt)
    }
}

#if DEBUG
extension PlaybackService {
    func _setStateForTesting(_ state: State) {
        updateState(state)
    }

    func _playDataForTesting(_ data: Data, interrupt: Bool = true) async throws {
        try await play(data: data, interrupt: interrupt)
    }

    func _playURLForTesting(_ url: URL, interrupt: Bool = true) async throws {
        try await play(url: url, interrupt: interrupt)
    }

    func _playWithAfplayDataForTesting(_ data: Data) async throws {
        try await playWithAfplay(data: data)
    }

    func _playWithAfplayURLForTesting(_ url: URL) async throws {
        try await playWithAfplay(url: url)
    }

    func _setCurrentProcessForTesting(_ process: Process?) {
        currentProcess = process
        if process != nil {
            updateState(.playing)
        }
    }

    func _finishAfplayPlaybackForTesting(_ process: Process) {
        finishAfplayPlayback(for: process)
    }

    func _setCurrentPlayerTokenForTesting(_ token: UUID?) {
        currentPlayerToken = token
    }

    func _handlePlayerFinishedForTesting(_ token: UUID) {
        handlePlayerFinished(token: token)
    }

    func _setTempFileURLForTesting(_ url: URL?) {
        currentTempFileURL = url
    }

    func _cleanupTempFileForTesting() {
        cleanupTempFile()
    }

    func _waitUntilFinishedForTesting(timeoutSeconds: Double? = nil) async throws {
        try await waitUntilFinished(timeoutSeconds: timeoutSeconds)
    }

    func _suggestedWaitTimeoutForTesting() -> Double {
        suggestedWaitTimeoutSeconds()
    }

    func _isTempFilePresentForTesting() -> Bool {
        currentTempFileURL != nil
    }

    func _setForcePlayerStartFailureForTesting(_ enabled: Bool) {
        forcePlayerStartFailureForTesting = enabled
    }

    func _triggerDecodeErrorCallbackForTesting() async {
        guard let delegate = currentPlayerDelegate, let player = currentPlayer else { return }
        await MainActor.run {
            delegate.audioPlayerDecodeErrorDidOccur(player, error: nil)
        }
    }
}
#endif
