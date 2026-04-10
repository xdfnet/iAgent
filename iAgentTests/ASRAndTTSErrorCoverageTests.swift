import XCTest
import Darwin
@testable import iAgent

private enum StubServerError: Error {
    case socketFailed
    case bindFailed
    case getSockNameFailed
    case startTimeout
    case scriptData
}

private func makeStubPython(prefix: String, body: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iagent-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let scriptURL = dir.appendingPathComponent("\(prefix).py")
    guard let data = body.data(using: .utf8) else { throw StubServerError.scriptData }
    try data.write(to: scriptURL)
    return scriptURL
}

private func reservePort() throws -> Int {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { throw StubServerError.socketFailed }
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
    guard bindResult == 0 else { throw StubServerError.bindFailed }

    var current = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &current) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(sock, $0, &len)
        }
    }
    guard nameResult == 0 else { throw StubServerError.getSockNameFailed }
    return Int(UInt16(bigEndian: current.sin_port))
}

private func startStubServer(script: String, prefix: String) throws -> (Process, Int) {
    let scriptURL = try makeStubPython(prefix: prefix, body: script)
    let port = try reservePort()

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
    throw StubServerError.startTimeout
}

final class ASRAndTTSErrorCoverageTests: XCTestCase {
    func testASRPCMRequestIsWrappedAsWAV() async throws {
        let wavGuardServerScript = """
        import base64
        import json
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        port = int(sys.argv[1])
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                _ = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                body = json.loads(_.decode("utf-8"))
                audio = body.get("audio", {})
                audio_data = base64.b64decode(audio.get("data", ""))
                is_wav = audio.get("format") == "wav" and audio.get("codec") == "raw" and audio_data[:4] == b"RIFF"
                payload = {"result": {"text": "WAV封装成功"}} if is_wav else {"result": {}}
                encoded = json.dumps(payload).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """

        let (server, port) = try startStubServer(script: wavGuardServerScript, prefix: "asr-pcm-wav-wrap")
        defer { if server.isRunning { server.terminate() } }

        let service = ASRService(
            config: .init(
                apiKey: "k",
                resourceId: "r",
                flashUrl: "http://127.0.0.1:\(port)/asr"
            )
        )
        let text = try await service.transcribe(audioData: Data(repeating: 0x01, count: 3200), format: .pcm)
        XCTAssertEqual(text, "WAV封装成功")
    }

    func testASRUtterancesAndErrorBranches() async throws {
        let utteranceServerScript = """
        import json
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        port = int(sys.argv[1])
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                if self.path != "/asr":
                    self.send_response(404); self.end_headers(); return
                _ = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                payload = json.dumps({"result":{"utterances":[{"text":"你"},{"text":"好"}]}}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        let (utteranceServer, utterancePort) = try startStubServer(script: utteranceServerScript, prefix: "asr-utterance")
        defer { if utteranceServer.isRunning { utteranceServer.terminate() } }

        let utteranceService = ASRService(
            config: .init(
                apiKey: "k",
                resourceId: "r",
                flashUrl: "http://127.0.0.1:\(utterancePort)/asr"
            )
        )
        let utteranceText = try await utteranceService.transcribe(audioData: Data([0x01]), format: .pcm)
        XCTAssertEqual(utteranceText, "你 好")

        let noResultServerScript = """
        import json
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        port = int(sys.argv[1])
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                _ = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                payload = json.dumps({"result":{}}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        let (noResultServer, noResultPort) = try startStubServer(script: noResultServerScript, prefix: "asr-no-result")
        defer { if noResultServer.isRunning { noResultServer.terminate() } }
        let noResultService = ASRService(
            config: .init(
                apiKey: "k",
                resourceId: "r",
                flashUrl: "http://127.0.0.1:\(noResultPort)/asr"
            )
        )
        do {
            _ = try await noResultService.transcribe(audioData: Data([0x02]), format: .pcm)
            XCTFail("expected noResult")
        } catch let error as ASRError {
            if case .noResult = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("unexpected error \(error)")
            }
        }

        let httpErrorScript = """
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        port = int(sys.argv[1])
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                _ = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                payload = b"bad request"
                self.send_response(500)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        let (httpServer, httpPort) = try startStubServer(script: httpErrorScript, prefix: "asr-http-error")
        defer { if httpServer.isRunning { httpServer.terminate() } }
        let httpService = ASRService(
            config: .init(
                apiKey: "k",
                resourceId: "r",
                flashUrl: "http://127.0.0.1:\(httpPort)/asr"
            )
        )
        do {
            _ = try await httpService.transcribe(audioData: Data([0x03]), format: .pcm)
            XCTFail("expected httpError")
        } catch let error as ASRError {
            if case .httpError(let statusCode, let message) = error {
                XCTAssertEqual(statusCode, 500)
                XCTAssertTrue(message.contains("bad request"))
            } else {
                XCTFail("unexpected error \(error)")
            }
        }

        let invalidURLService = ASRService(config: .init(apiKey: "k", resourceId: "r", flashUrl: ""))
        do {
            _ = try await invalidURLService.transcribe(audioData: Data([0x04]), format: .pcm)
            XCTFail("expected invalidURL")
        } catch let error as ASRError {
            if case .invalidURL = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testTTSNoAudioAndHTTPErrorBranches() async throws {
        let parseErrorScript = """
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
                for _ in range(12):
                    self.wfile.write(b"data: {invalid-json}\\n\\n")
                    self.wfile.flush()
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        let (parseServer, parsePort) = try startStubServer(script: parseErrorScript, prefix: "tts-parse-error")
        defer { if parseServer.isRunning { parseServer.terminate() } }
        let parseService = TTSService(
            config: .init(
                appId: "app",
                accessToken: "token",
                resourceId: "res",
                voiceType: "voice",
                endpoint: "http://127.0.0.1:\(parsePort)/tts"
            )
        )
        do {
            _ = try await parseService.synthesize(text: "hello")
            XCTFail("expected noAudioData")
        } catch let error as TTSError {
            if case .noAudioData = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("unexpected error \(error)")
            }
        }

        let httpErrorScript = """
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        port = int(sys.argv[1])
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                _ = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                self.send_response(503)
                self.end_headers()
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        let (httpServer, httpPort) = try startStubServer(script: httpErrorScript, prefix: "tts-http-error")
        defer { if httpServer.isRunning { httpServer.terminate() } }
        let httpService = TTSService(
            config: .init(
                appId: "app",
                accessToken: "token",
                resourceId: "res",
                voiceType: "voice",
                endpoint: "http://127.0.0.1:\(httpPort)/tts"
            )
        )
        do {
            _ = try await httpService.synthesize(text: "hello")
            XCTFail("expected httpError")
        } catch let error as TTSError {
            if case .httpError(let statusCode) = error {
                XCTAssertEqual(statusCode, 503)
            } else {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testTTSSupportsRawJSONLineAndNestedAudioPayload() async throws {
        let streamScript = """
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
                line1 = json.dumps({"data": base64.b64encode(b"ab").decode("utf-8")}) + "\\n"
                line2 = "data: " + json.dumps({"payload": {"audio": base64.b64encode(b"cd").decode("utf-8")}}) + "\\n\\n"
                self.wfile.write(line1.encode("utf-8"))
                self.wfile.write(line2.encode("utf-8"))
                self.wfile.flush()
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        let (server, port) = try startStubServer(script: streamScript, prefix: "tts-raw-json-line")
        defer { if server.isRunning { server.terminate() } }

        let service = TTSService(
            config: .init(
                appId: "app",
                accessToken: "token",
                resourceId: "res",
                voiceType: "voice",
                endpoint: "http://127.0.0.1:\(port)/tts"
            )
        )
        let audio = try await service.synthesize(text: "hello")
        XCTAssertEqual(audio, Data("abcd".utf8))
    }

    func testTTSErrorEventReturnsSynthesisFailed() async throws {
        let errorEventScript = """
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
                line = "data: " + json.dumps({"code": 4301, "message": "quota exceeded"}) + "\\n\\n"
                self.wfile.write(line.encode("utf-8"))
                self.wfile.flush()
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        let (server, port) = try startStubServer(script: errorEventScript, prefix: "tts-error-event")
        defer { if server.isRunning { server.terminate() } }

        let service = TTSService(
            config: .init(
                appId: "app",
                accessToken: "token",
                resourceId: "res",
                voiceType: "voice",
                endpoint: "http://127.0.0.1:\(port)/tts"
            )
        )
        do {
            _ = try await service.synthesize(text: "hello")
            XCTFail("expected synthesisFailed")
        } catch let error as TTSError {
            if case .synthesisFailed(let message) = error {
                XCTAssertTrue(message.contains("quota exceeded"))
                XCTAssertTrue(message.contains("4301"))
            } else {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testTTSCode20000000IsNotTreatedAsFailure() async throws {
        let successCodeScript = """
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
                line1 = "data: " + json.dumps({"code": 20000000, "message": "ok"}) + "\\n\\n"
                line2 = "data: " + json.dumps({"code": 20000000, "data": base64.b64encode(b"ok").decode("utf-8")}) + "\\n\\n"
                self.wfile.write(line1.encode("utf-8"))
                self.wfile.write(line2.encode("utf-8"))
                self.wfile.flush()
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        let (server, port) = try startStubServer(script: successCodeScript, prefix: "tts-success-code-20000000")
        defer { if server.isRunning { server.terminate() } }

        let service = TTSService(
            config: .init(
                appId: "app",
                accessToken: "token",
                resourceId: "res",
                voiceType: "voice",
                endpoint: "http://127.0.0.1:\(port)/tts"
            )
        )
        let audio = try await service.synthesize(text: "hello")
        XCTAssertEqual(audio, Data("ok".utf8))
    }

    func testTTSInvalidURLReturnsTypedError() async {
        let service = TTSService(
            config: .init(
                appId: "app",
                accessToken: "token",
                resourceId: "res",
                voiceType: "voice",
                endpoint: ""
            )
        )

        do {
            _ = try await service.synthesize(text: "hello")
            XCTFail("expected invalidURL")
        } catch let error as TTSError {
            if case .invalidURL = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTTSSupportsMultilineSSEDataEvent() async throws {
        let streamScript = """
        import base64
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer
        port = int(sys.argv[1])
        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"
            def do_POST(self):
                _ = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                audio = base64.b64encode(b"chunked-audio").decode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                self.wfile.write(b"event: message\\n")
                self.wfile.write(b"data: {\\n")
                self.wfile.write(f"data: \\"data\\": \\"{audio}\\"\\n".encode("utf-8"))
                self.wfile.write(b"data: }")
                self.wfile.write(b"\\n\\n")
                self.wfile.flush()
            def log_message(self, format, *args): return
        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """
        let (server, port) = try startStubServer(script: streamScript, prefix: "tts-multiline-event")
        defer { if server.isRunning { server.terminate() } }

        let service = TTSService(
            config: .init(
                appId: "app",
                accessToken: "token",
                resourceId: "res",
                voiceType: "voice",
                endpoint: "http://127.0.0.1:\(port)/tts"
            )
        )
        let audio = try await service.synthesize(text: "hello")
        XCTAssertEqual(audio, Data("chunked-audio".utf8))
    }
}
