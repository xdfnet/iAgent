import XCTest
@testable import iAgent

private enum AgentServiceIntegrationError: Error {
    case missingLog
}

private func makeTempScript(prefix: String, body: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iagent-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let scriptURL = dir.appendingPathComponent("\(prefix).sh")
    guard let data = body.data(using: .utf8) else {
        throw AgentServiceIntegrationError.missingLog
    }
    try data.write(to: scriptURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    return scriptURL
}

private func readLogLines(from url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw AgentServiceIntegrationError.missingLog
    }
    let text = try String(contentsOf: url, encoding: .utf8)
    return text
        .split(separator: "\n")
        .map { String($0) }
}

private func shellSingleQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func validAgentSessionTestWorkdir() -> String {
    FileManager.default.temporaryDirectory.path
}

final class AgentServiceSessionIntegrationTests: XCTestCase {
    func testQwenSessionIdContinuationUsesResumeFlag() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iagent-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("qwen-args.log")
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let script = """
        #!/bin/zsh
        set -euo pipefail
        LOG_FILE=\(shellSingleQuote(logURL.path))
        resume=""
        prompt=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --resume)
              resume="$2"
              shift 2
              ;;
            -p)
              prompt="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        echo "${resume}|${prompt}" >> "$LOG_FILE"
        if [[ -z "$resume" ]]; then
          sid="sid-1"
        else
          sid="$resume"
        fi
        printf '[{"type":"result","message":{"content":"reply:%s"},"session_id":"%s"}]\\n' "$prompt" "$sid"
        """
        let scriptURL = try makeTempScript(prefix: "fake-qwen", body: script)

        let service = AgentService(
            config: .init(
                qwenPath: scriptURL.path,
                workdir: validAgentSessionTestWorkdir(),
                timeoutSeconds: 5
            )
        )

        let first = try await service.execute(prompt: "hello1")
        let second = try await service.execute(prompt: "hello2")

        XCTAssertEqual(first.replyText, "reply:hello1")
        XCTAssertEqual(first.sessionId, "sid-1")
        XCTAssertEqual(second.replyText, "reply:hello2")
        XCTAssertEqual(second.sessionId, "sid-1")

        let logs = try readLogLines(from: logURL)
        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(logs[0], "|hello1")
        XCTAssertEqual(logs[1], "sid-1|hello2")
    }
}
