//
//  AgentService.swift
//  iAgent
//
//  Agent 执行器服务，对应 Python 版本的 agent.py
//  当前默认使用 Claude Code CLI 调用
//

import Foundation
import Darwin
import Synchronization

private final class ContinuationGate: @unchecked Sendable {
    private let hasResumed = Mutex(false)

    nonisolated init() {}

    nonisolated func claim() -> Bool {
        hasResumed.withLock {
            guard !$0 else { return false }
            $0 = true
            return true
        }
    }
}

// MARK: - Agent Prompt 构建（独立函数）

/// 构建 Agent Prompt
/// - Parameters:
///   - userText: 用户输入文本
///   - behaviorContext: 可选的行为上下文提示
/// - Returns: 构建好的 prompt
func buildAgentPrompt(userText: String, behaviorContext: String? = nil) -> String {
    let cleanedBehaviorContext = behaviorContext?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let behaviorSection: String
    if let cleanedBehaviorContext, !cleanedBehaviorContext.isEmpty {
        behaviorSection = """
        附加行为上下文：
        \(cleanedBehaviorContext)
        """
    } else {
        behaviorSection = ""
    }

    return """
    你是一个本地电脑语音助手的执行器，叫豆包。用户叫飞哥。
    你的回复会被直接转成中文语音播放给用户听。
    要求：
    1. 直接回答用户这次的问题或任务，不要复述规则，不要自我介绍。
    2. 简洁自然，尽量控制在 2 到 4 句，优先用短句和口语化表达。
    3. 不要使用 Markdown、标题、列表、代码块、表格、引号式大段引用。
    4. 如果你执行了代码、命令或分析，只说最终结果、关键影响和下一步结论，不要展开中间过程。
    5. 如果任务失败，就直接说明失败原因；如果需要更多信息，就明确说出你缺什么。
    6. 避免生硬的 AI 口吻，避免长括号说明，避免堆砌英文术语；必须提到命令、路径或代码时再提。
    7. 除非用户明确要求，否则不要逐条教学，不要给过长免责声明。
    8. 输出必须适合语音播报，听起来像助手当面在说话。
    本轮目标：
    - 成功时：先说结果，再补一句最重要的说明。
    - 失败时：先说没成功，再说最关键的原因。
    - 信息不足时：直接说还缺哪一个信息。
    \(behaviorSection)
    本轮用户输入：
    \(userText)
    """
}

// MARK: - Agent 执行器服务

actor AgentService {
    static let executableName = "claude"

    struct Config: Sendable {
        var claudePath: String?
        var workdir: String
        var timeoutSeconds: Int

        static var `default`: Config {
            let settings = Configuration.shared.agent
            return Config(
                claudePath: nil,
                workdir: settings.workdir,
                timeoutSeconds: settings.timeoutSeconds
            )
        }
    }

    struct Response: Sendable {
        var replyText: String
        var sessionId: String?
    }

    private let config: Config
    private var currentSessionId: String?
#if DEBUG
    private var findExecutableOverrideForTesting: ((String) -> String?)?
#endif

    init(config: Config = .default) {
        self.config = config
    }

    /// 执行 prompt
    /// - Parameters:
    ///   - prompt: 要执行的提示词
    ///   - sessionId: 可选的会话 ID，用于恢复会话
    /// - Returns: Agent 响应
    func execute(prompt: String, sessionId: String? = nil) async throws -> Response {
        let effectiveSessionId = sessionId ?? currentSessionId

        let result = try await executeClaudeCode(prompt: prompt, sessionId: effectiveSessionId)
        let replyText = result.replyText
        let newSessionId = result.sessionId

        if let newId = newSessionId {
            currentSessionId = newId
        }

        return Response(replyText: replyText, sessionId: newSessionId)
    }

    /// 执行 Claude Code CLI
    private func executeClaudeCode(prompt: String, sessionId: String?) async throws -> Response {
        var arguments = [
            "-p",
            prompt,
            "--output-format",
            "json",
            "--permission-mode",
            "bypassPermissions"
        ]

        if let sessionId = sessionId {
            arguments += ["--resume", sessionId]
        }

        let output = try await runProcess(
            executable: Self.executableName,
            arguments: arguments
        )

        return try parseAgentOutput(output)
    }

    /// 运行外部进程并捕获输出
    private func runProcess(executable: String, arguments: [String]) async throws -> String {
        let launchCommand: LaunchCommand
        if let command = prepareLaunchCommand(for: executable, arguments: arguments) {
            launchCommand = command
        } else {
            throw AgentError.executableNotFound(executable)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchCommand.executablePath)
            process.arguments = launchCommand.arguments
            process.currentDirectoryURL = URL(fileURLWithPath: config.workdir)
            var environment = ExecutableLocator.runtimeEnvironment()
            // 避免 iAgent 内部调用 Agent 时触发外部 Stop Hook 二次播报
            environment["ISPEAK_SKIP"] = "1"
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let stdoutHandle = outputPipe.fileHandleForReading
            let stderrHandle = errorPipe.fileHandleForReading
            let outputBuffer = Mutex(Data())
            let errorBuffer = Mutex(Data())
            let gate = ContinuationGate()

            let cleanupHandles: @Sendable () -> Void = {
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                try? stdoutHandle.close()
                try? stderrHandle.close()
            }

            let drainBufferedOutput: @Sendable () -> (String, String) = {
                let remainingOutput = stdoutHandle.readDataToEndOfFile()
                if !remainingOutput.isEmpty {
                    outputBuffer.withLock { $0.append(remainingOutput) }
                }

                let remainingError = stderrHandle.readDataToEndOfFile()
                if !remainingError.isEmpty {
                    errorBuffer.withLock { $0.append(remainingError) }
                }

                let output = outputBuffer.withLock { String(data: $0, encoding: .utf8) ?? "" }
                let error = errorBuffer.withLock { String(data: $0, encoding: .utf8) ?? "" }
                return (output, error)
            }

            // 设置超时
            let timeoutTask = Task {
                do {
                    try await Task.sleep(for: .seconds(Double(config.timeoutSeconds)))
                } catch {
                    return
                }
                if gate.claim() {
                    if process.isRunning {
                        process.terminate()
                        try? await Task.sleep(for: .milliseconds(250))
                        if process.isRunning {
                            Darwin.kill(process.processIdentifier, SIGKILL)
                        }
                    }
                    continuation.resume(throwing: AgentError.timeout)
                }
            }

            process.terminationHandler = { [stdoutHandle, stderrHandle] process in
                timeoutTask.cancel()
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                let (output, errorOutput) = drainBufferedOutput()
                try? stdoutHandle.close()
                try? stderrHandle.close()

                guard gate.claim() else { return }

                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: AgentError.executionFailed(
                        statusCode: Int(process.terminationStatus),
                        output: output,
                        error: errorOutput
                    ))
                }
            }

            do {
                try process.run()
                stdoutHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        handle.readabilityHandler = nil
                        return
                    }
                    outputBuffer.withLock { $0.append(data) }
                }
                stderrHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else {
                        handle.readabilityHandler = nil
                        return
                    }
                    errorBuffer.withLock { $0.append(data) }
                }
            } catch {
                timeoutTask.cancel()
                cleanupHandles()
                guard gate.claim() else {
                    return
                }
                continuation.resume(throwing: AgentError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// 解析 Agent CLI 输出
    private func parseAgentOutput(_ output: String) throws -> Response {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgentError.parseError("Claude Code 返回为空")
        }

        // 兼容单条 JSON 与 JSONL（逐行事件）两种输出形式。
        if let singleMessage = decodeJSONObject(from: trimmed) {
            return try parseClaudeMessages([singleMessage])
        }

        let messages = trimmed
            .split(whereSeparator: \.isNewline)
            .compactMap { decodeJSONObject(from: String($0)) }
        guard !messages.isEmpty else {
            throw AgentError.parseError("Claude Code 返回格式异常")
        }
        return try parseClaudeMessages(messages)
    }

    private func decodeJSONObject(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func parseClaudeMessages(_ messages: [[String: Any]]) throws -> Response {
        var latestSessionId: String?
        var latestReplyText: String?

        for message in messages {
            if let sessionId = (message["session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !sessionId.isEmpty
            {
                latestSessionId = sessionId
            }

            let type = message["type"] as? String
            let subtype = message["subtype"] as? String
            let isSuccess = type == "result" || subtype == "success"
            guard isSuccess else { continue }

            let replyText = (message["result"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !replyText.isEmpty {
                latestReplyText = replyText
            }
        }

        guard let replyText = latestReplyText else {
            throw AgentError.parseError("Claude Code 没有返回可播报内容")
        }

        let compressed = compressForSpeech(replyText)
        return Response(replyText: compressed, sessionId: latestSessionId)
    }

    /// 为语音播报压缩文本
    private func compressForSpeech(_ text: String) -> String {
        let compact = text.split(separator: " ").joined()
        if compact.count <= 280 {
            return compact
        }
        let index = compact.index(compact.startIndex, offsetBy: 277)
        return String(compact[..<index]) + "..."
    }

    /// 查找可执行文件路径
    private func findExecutable(_ name: String) -> String? {
#if DEBUG
        if let override = findExecutableOverrideForTesting {
            return override(name)
        }
#endif
        return ExecutableLocator.find(name)
    }

    private struct LaunchCommand {
        let executablePath: String
        let arguments: [String]
    }

    private func prepareLaunchCommand(for executable: String, arguments: [String]) -> LaunchCommand? {
        guard let resolvedPath = configuredExecutablePath(for: executable) ?? findExecutable(executable) else {
            return nil
        }

        return LaunchCommand(
            executablePath: "/bin/zsh",
            arguments: ["-lc", shellCommand(for: resolvedPath, arguments: arguments)]
        )
    }

    private func shellCommand(for resolvedPath: String, arguments: [String]) -> String {
        let joinedArguments = arguments.map(ExecutableLocator.shellQuote).joined(separator: " ")
        if resolvedPath.hasSuffix(".js") {
            let nodePath = ExecutableLocator.find("node") ?? "/opt/homebrew/bin/node"
            let suffix = joinedArguments.isEmpty ? "" : " " + joinedArguments
            return "exec \(ExecutableLocator.shellQuote(nodePath)) \(ExecutableLocator.shellQuote(resolvedPath))\(suffix)"
        }
        let suffix = joinedArguments.isEmpty ? "" : " " + joinedArguments
        return "exec \(ExecutableLocator.shellQuote(resolvedPath))\(suffix)"
    }

    private func configuredExecutablePath(for executable: String) -> String? {
        let configuredPath: String?
        switch executable {
        case "claude":
            configuredPath = config.claudePath
        default:
            configuredPath = nil
        }

        guard let configuredPath, !configuredPath.isEmpty else {
            return nil
        }

        return ExecutableLocator.resolvedLaunchPath(for: configuredPath)
    }
}

// MARK: - 错误类型

enum AgentError: Error, LocalizedError, Sendable {
    case executableNotFound(String)
    case launchFailed(String)
    case executionFailed(statusCode: Int, output: String, error: String)
    case parseError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "\(name) 可执行文件未找到"
        case .launchFailed(let message):
            return "启动失败: \(message)"
        case .executionFailed(let statusCode, _, let error):
            return "执行失败 (状态码 \(statusCode)): \(error)"
        case .parseError(let message):
            return "解析错误: \(message)"
        case .timeout:
            return "执行超时"
        }
    }
}

#if DEBUG
extension AgentService {
    func _compressForSpeechForTesting(_ text: String) -> String {
        compressForSpeech(text)
    }

    func _shellCommandForTesting(path: String, arguments: [String]) -> String {
        shellCommand(for: path, arguments: arguments)
    }

    func _findExecutableForTesting(_ name: String) -> String? {
        findExecutable(name)
    }

    func _setFindExecutableOverrideForTesting(_ override: ((String) -> String?)?) {
        findExecutableOverrideForTesting = override
    }

    func _parseClaudeOutputForTesting(_ output: String) throws -> Response {
        try parseAgentOutput(output)
    }

    func _configuredExecutablePathForTesting(_ executable: String) -> String? {
        configuredExecutablePath(for: executable)
    }
}
#endif
