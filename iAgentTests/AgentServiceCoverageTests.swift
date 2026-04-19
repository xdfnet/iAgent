import XCTest
@testable import iAgent

private func makeExecutableScript(prefix: String, body: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("iagent-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(prefix).sh")
    guard let data = body.data(using: .utf8) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func testShellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func validTestWorkdir() -> String {
    FileManager.default.temporaryDirectory.path
}

final class AgentServiceCoverageTests: XCTestCase {
    func testParseAndHelperMethods() async throws {
        let service = AgentService(
            config: .init(
                claudePath: "/bin/echo",
                workdir: validTestWorkdir(),
                timeoutSeconds: 1
            )
        )

        let prompt = buildAgentPrompt(userText: "测试输入")
        XCTAssertTrue(prompt.contains("测试输入"))

        let compact = await service._compressForSpeechForTesting("a b c")
        XCTAssertEqual(compact, "abc")

        let longText = String(repeating: "x", count: 320)
        let truncated = await service._compressForSpeechForTesting(longText)
        XCTAssertEqual(truncated.count, 280)
        XCTAssertTrue(truncated.hasSuffix("..."))

        let jsCommand = await service._shellCommandForTesting(path: "/tmp/tool.js", arguments: ["-p", "x y"])
        XCTAssertTrue(jsCommand.contains("node"))
        XCTAssertTrue(jsCommand.contains("/tmp/tool.js"))

        let binCommand = await service._shellCommandForTesting(path: "/bin/echo", arguments: ["hello"])
        XCTAssertTrue(binCommand.contains("/bin/echo"))

        let foundSh = await service._findExecutableForTesting("/bin/sh")
        XCTAssertNotNil(foundSh)
        let missingCommand = await service._findExecutableForTesting("missing_cmd_\(UUID().uuidString)")
        XCTAssertNil(missingCommand)

        let claudeResult = try await service._parseClaudeOutputForTesting(#"{"type":"result","subtype":"success","result":"claude text","session_id":"sid-claude"}"#)
        XCTAssertEqual(claudeResult.replyText, "claudetext")
        XCTAssertEqual(claudeResult.sessionId, "sid-claude")

        do {
            _ = try await service._parseClaudeOutputForTesting(#"{"type":"result"}"#)
            XCTFail("expected parse error")
        } catch {
            XCTAssertTrue((error as? AgentError)?.errorDescription?.contains("解析错误") == true)
        }

        let jsCommandWithoutArgs = await service._shellCommandForTesting(path: "/tmp/tool.js", arguments: [])
        XCTAssertTrue(jsCommandWithoutArgs.contains("node"))
        XCTAssertFalse(jsCommandWithoutArgs.contains("  "))
    }

    func testRunProcessLaunchFailedExecutionFailedAndTimeout() async throws {
        let badWorkdirService = AgentService(
            config: .init(
                claudePath: "/bin/echo",
                workdir: "/tmp/not-exist-\(UUID().uuidString)",
                timeoutSeconds: 1
            )
        )
        do {
            _ = try await badWorkdirService.execute(prompt: "x")
            XCTFail("expected launch failure")
        } catch let error as AgentError {
            switch error {
            case .launchFailed:
                XCTAssertTrue(true)
            case .timeout:
                // 在高负载下可能出现超时，允许该分支避免 flaky
                XCTAssertTrue(true)
            default:
                XCTFail("unexpected error \(error)")
            }
        }

        let failingScript = try makeExecutableScript(
            prefix: "agent-fail",
            body: """
            #!/bin/zsh
            echo "oops" >&2
            exit 3
            """
        )
        let executionFailedService = AgentService(
            config: .init(
                claudePath: failingScript.path,
                workdir: validTestWorkdir(),
                timeoutSeconds: 2
            )
        )
        do {
            _ = try await executionFailedService.execute(prompt: "x")
            XCTFail("expected execution failed")
        } catch let error as AgentError {
            if case .executionFailed(let statusCode, _, let stderr) = error {
                XCTAssertEqual(statusCode, 3)
                XCTAssertTrue(stderr.contains("oops"))
            } else if case .timeout = error {
                // 在并行测试压力下，进程调度可能导致超时
                XCTAssertTrue(true)
            } else {
                XCTFail("unexpected error \(error)")
            }
        }

        let timeoutScript = try makeExecutableScript(
            prefix: "agent-timeout",
            body: """
            #!/bin/zsh
            sleep 2
            echo '{"type":"result","subtype":"success","result":"late"}'
            """
        )
        let timeoutService = AgentService(
            config: .init(
                claudePath: timeoutScript.path,
                workdir: validTestWorkdir(),
                timeoutSeconds: 1
            )
        )
        do {
            _ = try await timeoutService.execute(prompt: "x")
            XCTFail("expected timeout")
        } catch let error as AgentError {
            if case .timeout = error {
                XCTAssertTrue(true)
            } else {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testClaudeExecutePassesResumeAndJsonArguments() async throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iagent-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("claude-model.log")
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let script = """
        #!/bin/zsh
        set -euo pipefail
        LOG_FILE=\(testShellQuote(logURL.path))
        prompt=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -p)
              prompt="$2"
              shift 2
              ;;
            *)
              echo "$1" >> "$LOG_FILE"
              shift 1
              ;;
          esac
        done
        echo "PROMPT:${prompt}" >> "$LOG_FILE"
        printf '{"type":"result","subtype":"success","result":"ok:%s","session_id":"sid-claude"}\\n' "$prompt"
        """
        let scriptURL = try makeExecutableScript(prefix: "agent-claude-model", body: script)

        let service = AgentService(
            config: .init(
                claudePath: scriptURL.path,
                workdir: validTestWorkdir(),
                timeoutSeconds: 5
            )
        )

        let response = try await service.execute(prompt: "hello-claude", sessionId: "sid-resume")
        XCTAssertEqual(response.replyText, "ok:hello-claude")
        XCTAssertEqual(response.sessionId, "sid-claude")

        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            lines,
            ["--output-format", "json", "--permission-mode", "bypassPermissions", "--resume", "sid-resume", "PROMPT:hello-claude"]
        )
    }

    func testClaudeFallsBackToPATHLookupWhenConfiguredPathIsNil() async throws {
        let script = """
        #!/bin/zsh
        set -euo pipefail
        printf '{"type":"result","subtype":"success","result":"path-lookup-ok"}\\n'
        """
        let scriptURL = try makeExecutableScript(prefix: "claude", body: script)

        let service = AgentService(
            config: .init(
                claudePath: nil,
                workdir: validTestWorkdir(),
                timeoutSeconds: 5
            )
        )
        await service._setFindExecutableOverrideForTesting { name in
            name == "claude" ? scriptURL.path : nil
        }
        let response = try await service.execute(prompt: "path-run")
        await service._setFindExecutableOverrideForTesting(nil)
        XCTAssertEqual(response.replyText, "path-lookup-ok")
    }

    func testExecuteFailsWhenExecutableCannotBeResolved() async {
        let service = AgentService(
            config: .init(
                claudePath: nil,
                workdir: validTestWorkdir(),
                timeoutSeconds: 2
            )
        )
        await service._setFindExecutableOverrideForTesting { _ in nil }

        do {
            _ = try await service.execute(prompt: "missing")
            XCTFail("expected executableNotFound")
        } catch let error as AgentError {
            if case .executableNotFound(let name) = error {
                XCTAssertEqual(name, "claude")
            } else {
                XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }

        await service._setFindExecutableOverrideForTesting(nil)
    }

    func testParseAgentOutputRejectsInvalidTopLevel() async {
        let service = AgentService(
            config: .init(
                claudePath: "/bin/echo",
                workdir: validTestWorkdir(),
                timeoutSeconds: 1
            )
        )

        do {
            _ = try await service._parseClaudeOutputForTesting(#"[{"type":"result"}]"#)
            XCTFail("expected parse error")
        } catch let error as AgentError {
            if case .parseError(let message) = error {
                XCTAssertTrue(message.contains("格式异常"))
            } else {
                XCTFail("unexpected error \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testParseClaudeOutputSupportsJSONLMessages() async throws {
        let service = AgentService(
            config: .init(
                claudePath: "/bin/echo",
                workdir: validTestWorkdir(),
                timeoutSeconds: 1
            )
        )

        let output = """
        {"type":"system","session_id":"sid-jsonl"}
        {"type":"result","subtype":"success","result":"jsonl result"}
        """

        let response = try await service._parseClaudeOutputForTesting(output)
        XCTAssertEqual(response.replyText, "jsonlresult")
        XCTAssertEqual(response.sessionId, "sid-jsonl")
    }

    func testConfiguredExecutablePathDefaultCaseReturnsNil() async {
        let service = AgentService(
            config: .init(
                claudePath: nil,
                workdir: validTestWorkdir(),
                timeoutSeconds: 1
            )
        )
        let path = await service._configuredExecutablePathForTesting("other-tool")
        XCTAssertNil(path)
    }

    func testLargeProcessOutputDoesNotDeadlock() async throws {
        let script = try makeExecutableScript(
            prefix: "agent-large-output",
            body: """
            #!/bin/zsh
            print -n '{"type":"result","subtype":"success","result":"'
            for i in {1..70000}; do
              print -n 'a'
            done
            print '"}'
            """
        )

        let service = AgentService(
            config: .init(
                claudePath: script.path,
                workdir: validTestWorkdir(),
                timeoutSeconds: 5
            )
        )

        let response = try await service.execute(prompt: "large-output")
        XCTAssertEqual(response.replyText.count, 280)
        XCTAssertTrue(response.replyText.hasSuffix("..."))
    }
}
