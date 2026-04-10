import XCTest
import Darwin
@testable import iAgent

private enum LocalServerError: Error {
    case socketFailed
    case bindFailed
    case getSockNameFailed
    case serverStartTimeout
    case invalidScriptData
}

private func makeTempPythonScript(prefix: String, body: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iagent-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let scriptURL = dir.appendingPathComponent("\(prefix).py")
    guard let data = body.data(using: .utf8) else {
        throw LocalServerError.invalidScriptData
    }
    try data.write(to: scriptURL)
    return scriptURL
}

private func findFreeLocalPort() throws -> Int {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { throw LocalServerError.socketFailed }
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
    guard bindResult == 0 else { throw LocalServerError.bindFailed }

    var boundAddr = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(sock, $0, &len)
        }
    }
    guard nameResult == 0 else { throw LocalServerError.getSockNameFailed }
    return Int(UInt16(bigEndian: boundAddr.sin_port))
}

private func waitForServerReady(port: Int, timeoutSeconds: Double) throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock >= 0 {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(sock)
            if connectResult == 0 {
                return
            }
        }
        usleep(50_000)
    }
    throw LocalServerError.serverStartTimeout
}

private func startLocalPythonServer(script: String, prefix: String) throws -> (Process, Int) {
    let scriptURL = try makeTempPythonScript(prefix: prefix, body: script)
    let port = try findFreeLocalPort()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [scriptURL.path, "\(port)"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()

    try waitForServerReady(port: port, timeoutSeconds: 2.0)
    return (process, port)
}

final class ASRAndTTSLocalIntegrationTests: XCTestCase {
    func testASRServiceTranscribeWithLocalStub() async throws {
        let script = """
        import json
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer

        port = int(sys.argv[1])

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                _ = self.rfile.read(length)
                if self.path != "/asr":
                    self.send_response(404)
                    self.end_headers()
                    return
                body = {"result": {"text": "本地ASR成功"}}
                payload = json.dumps(body).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, format, *args):
                return

        server = HTTPServer(("127.0.0.1", port), Handler)
        server.serve_forever()
        """

        let (server, port) = try startLocalPythonServer(script: script, prefix: "asr-local-stub")
        defer {
            if server.isRunning { server.terminate() }
        }

        let service = ASRService(
            config: .init(
                apiKey: "test-api-key",
                resourceId: "test-resource",
                flashUrl: "http://127.0.0.1:\(port)/asr"
            )
        )

        let text = try await service.transcribe(audioData: Data([0x01, 0x02, 0x03]), format: .pcm)
        XCTAssertEqual(text, "本地ASR成功")
    }

    func testTTSServiceSSEWithLocalStub() async throws {
        let script = """
        import base64
        import json
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer

        port = int(sys.argv[1])

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"
            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                _ = self.rfile.read(length)
                if self.path != "/tts":
                    self.send_response(404)
                    self.end_headers()
                    return

                chunks = [base64.b64encode(b"ab").decode("utf-8"), base64.b64encode(b"cd").decode("utf-8")]
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                for chunk in chunks:
                    event = {"data": chunk}
                    line = "data: " + json.dumps(event) + "\\n\\n"
                    self.wfile.write(line.encode("utf-8"))
                    self.wfile.flush()

            def log_message(self, format, *args):
                return

        server = HTTPServer(("127.0.0.1", port), Handler)
        server.serve_forever()
        """

        let (server, port) = try startLocalPythonServer(script: script, prefix: "tts-local-stub")
        defer {
            if server.isRunning { server.terminate() }
        }

        let service = TTSService(
            config: .init(
                appId: "test-app",
                accessToken: "test-token",
                resourceId: "test-resource",
                voiceType: "test-voice",
                endpoint: "http://127.0.0.1:\(port)/tts"
            )
        )

        let audio = try await service.synthesize(text: "hello")
        XCTAssertEqual(audio, Data("abcd".utf8))
    }
}
