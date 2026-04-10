import XCTest
import Darwin
@testable import iAgent

private func makeSleepProcess(seconds: String) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = [seconds]
    try process.run()
    return process
}

private func makeTempPlaybackFile(data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("iagent-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mp3")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
}

private func makeWAVData(durationSeconds: Double = 0.08, sampleRate: Int = 8000) -> Data {
    let sampleCount = max(1, Int(Double(sampleRate) * durationSeconds))
    var pcm = Data(capacity: sampleCount * 2)
    for i in 0..<sampleCount {
        let t = Double(i) / Double(sampleRate)
        let value = Int16(sin(t * 2.0 * .pi * 440.0) * 15000.0)
        var little = value.littleEndian
        pcm.append(Data(bytes: &little, count: MemoryLayout<Int16>.size))
    }

    let byteRate = sampleRate * 2
    let blockAlign: UInt16 = 2
    let bitsPerSample: UInt16 = 16
    let dataSize = UInt32(pcm.count)
    let riffSize = UInt32(36) + dataSize

    func u32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: MemoryLayout<UInt32>.size)
    }
    func u16(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: MemoryLayout<UInt16>.size)
    }

    var wav = Data()
    wav.append(Data("RIFF".utf8))
    wav.append(u32(riffSize))
    wav.append(Data("WAVE".utf8))
    wav.append(Data("fmt ".utf8))
    wav.append(u32(16))
    wav.append(u16(1))
    wav.append(u16(1))
    wav.append(u32(UInt32(sampleRate)))
    wav.append(u32(UInt32(byteRate)))
    wav.append(u16(blockAlign))
    wav.append(u16(bitsPerSample))
    wav.append(Data("data".utf8))
    wav.append(u32(dataSize))
    wav.append(pcm)
    return wav
}

private enum PlaybackStubError: Error {
    case socketFailed
    case bindFailed
    case getSockNameFailed
    case startTimeout
    case scriptData
}

private func makePlaybackStubScript(prefix: String, body: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iagent-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(prefix).py")
    guard let data = body.data(using: .utf8) else { throw PlaybackStubError.scriptData }
    try data.write(to: url)
    return url
}

private func reservePlaybackStubPort() throws -> Int {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { throw PlaybackStubError.socketFailed }
    defer { close(sock) }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(0).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw PlaybackStubError.bindFailed }

    var current = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &current) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(sock, $0, &len)
        }
    }
    guard nameResult == 0 else { throw PlaybackStubError.getSockNameFailed }
    return Int(UInt16(bigEndian: current.sin_port))
}

private func startPlaybackStubServer(script: String, prefix: String) throws -> (Process, Int) {
    let scriptURL = try makePlaybackStubScript(prefix: prefix, body: script)
    let port = try reservePlaybackStubPort()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [scriptURL.path, "\(port)"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()

    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock >= 0 {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(sock)
            if connected == 0 {
                return (process, port)
            }
        }
        usleep(50_000)
    }
    throw PlaybackStubError.startTimeout
}

final class PlaybackServiceCoverageTests: XCTestCase {
    func testPlayURLAndDataFallbackAndStop() async throws {
        let service = PlaybackService()
        let invalidData = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        let tempURL = try makeTempPlaybackFile(data: invalidData)

        try await service._playURLForTesting(tempURL, interrupt: true)
        try await service._playDataForTesting(invalidData, interrupt: true)

        _ = await service.stop()
        let isPlayingAfterStop = await service.isPlaying
        let hasTempFileAfterStop = await service._isTempFilePresentForTesting()
        XCTAssertFalse(isPlayingAfterStop)
        XCTAssertFalse(hasTempFileAfterStop)
    }

    func testPlayDataWithAVAudioPlayerPath() async throws {
        let service = PlaybackService()
        let wavData = makeWAVData()

        try await service._playDataForTesting(wavData, interrupt: true)
        try await service._playDataForTesting(wavData, interrupt: false)
        try? await Task.sleep(for: .milliseconds(300))

        let playing = await service.isPlaying
        XCTAssertFalse(playing)
    }

    func testDecodeErrorCallbackAndForcedStartFailureBranch() async throws {
        let service = PlaybackService()
        let longWav = makeWAVData(durationSeconds: 0.5)

        try await service._playDataForTesting(longWav, interrupt: true)
        await service._triggerDecodeErrorCallbackForTesting()
        try? await Task.sleep(for: .milliseconds(120))
        let afterDecodeError = await service.isPlaying
        XCTAssertFalse(afterDecodeError)

        await service._setForcePlayerStartFailureForTesting(true)
        try await service._playDataForTesting(longWav, interrupt: true)
        await service._setForcePlayerStartFailureForTesting(false)
        _ = await service.stop()
    }

    func testPlayDataWithInterruptFalseWaitsCurrentPlayback() async throws {
        let service = PlaybackService()
        let running = try makeSleepProcess(seconds: "0.2")
        await service._setCurrentProcessForTesting(running)

        let start = Date()
        try await service._playDataForTesting(Data([0x10, 0x20]), interrupt: false)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
        _ = await service.stop()
    }

    func testAfplayFinishAndCleanupBranches() async throws {
        let service = PlaybackService()
        let tempFile = AudioProcessor.tempFileURL(prefix: "cleanup-test", ext: "mp3")
        try Data([0x01, 0x02, 0x03]).write(to: tempFile)
        await service._setTempFileURLForTesting(tempFile)

        let trackedProcess = Process()
        let otherProcess = Process()
        await service._setCurrentProcessForTesting(trackedProcess)

        await service._finishAfplayPlaybackForTesting(otherProcess)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempFile.path))

        await service._finishAfplayPlaybackForTesting(trackedProcess)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
        let hasTempFile = await service._isTempFilePresentForTesting()
        XCTAssertFalse(hasTempFile)
    }

    func testHandlePlayerFinishedGuardBranches() async {
        let service = PlaybackService()
        let token = UUID()
        await service._setCurrentPlayerTokenForTesting(token)
        await service._handlePlayerFinishedForTesting(UUID())
        await service._handlePlayerFinishedForTesting(token)
        let isPlaying = await service.isPlaying
        XCTAssertFalse(isPlaying)
    }

    func testCleanupTempFileAndWaitUntilFinished() async throws {
        let service = PlaybackService()
        let tempFile = AudioProcessor.tempFileURL(prefix: "manual-cleanup", ext: "mp3")
        try Data([0x11]).write(to: tempFile)
        await service._setTempFileURLForTesting(tempFile)
        await service._cleanupTempFileForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))

        let process = try makeSleepProcess(seconds: "0.1")
        await service._setCurrentProcessForTesting(process)
        try await service._waitUntilFinishedForTesting()
        let isPlayingAfterWait = await service.isPlaying
        XCTAssertFalse(isPlayingAfterWait)
    }

    func testWaitUntilFinishedTimesOutAndStopsPlayback() async throws {
        let service = PlaybackService()
        let process = try makeSleepProcess(seconds: "5")
        await service._setCurrentProcessForTesting(process)

        do {
            try await service._waitUntilFinishedForTesting(timeoutSeconds: 0.05)
            XCTFail("expected wait timeout")
        } catch let error as PlaybackError {
            XCTAssertEqual(error, .waitTimeout)
        } catch {
            XCTFail("unexpected error \(error)")
        }

        let isPlayingAfterTimeout = await service.isPlaying
        XCTAssertFalse(isPlayingAfterTimeout)
    }

    func testSuggestedWaitTimeoutUsesPlayerDuration() async throws {
        let service = PlaybackService()
        let longWav = makeWAVData(durationSeconds: 35.0)

        try await service._playDataForTesting(longWav, interrupt: true)
        let timeout = await service._suggestedWaitTimeoutForTesting()
        XCTAssertGreaterThanOrEqual(timeout, 42.5)

        _ = await service.stop()
    }

    func testSynthesizeAndPlayPath() async throws {
        let script = """
        import base64
        import json
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        port = int(sys.argv[1])
        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"
            def do_POST(self):
                _ = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                payload = base64.b64encode(b"abc").decode("utf-8")
                self.wfile.write(("data: " + json.dumps({"data": payload}) + "\\n\\n").encode("utf-8"))
                self.wfile.flush()
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        let (server, port) = try startPlaybackStubServer(script: script, prefix: "playback-tts")
        defer { if server.isRunning { server.terminate() } }

        let tts = TTSService(
            config: .init(
                appId: "app",
                accessToken: "token",
                resourceId: "res",
                voiceType: "voice",
                endpoint: "http://127.0.0.1:\(port)/tts"
            )
        )
        let service = PlaybackService()
        try await service.synthesizeAndPlay(text: "hello", using: tts, interrupt: true)
        try await service._playWithAfplayDataForTesting(Data([0x01, 0x02]))
        let fileURL = try makeTempPlaybackFile(data: Data([0xAA, 0xBB]))
        try await service._playWithAfplayURLForTesting(fileURL)
        _ = await service.stop()
    }
}
