# ASK 接口文档

## 1. 接口定位

`ask` 在当前工程里是**内部接口**，不是 HTTP 路由。  
调用入口在 `AgentControlCenter`，实际执行在 `AgentService`：

- `AgentControlCenter.executeAgent(text:)`
- `AgentService.execute(prompt:sessionId:)`

主链路：

1. ASR 输出文本 `transcript`
2. `buildAgentPrompt(userText:)` 组装提示词
3. `AgentService.execute(...)` 调 `qwen` CLI
4. 返回 `replyText`（可选 `sessionId`）

## 2. 方法签名

```swift
func execute(prompt: String, sessionId: String? = nil) async throws -> AgentService.Response
```

返回结构：

```swift
struct Response {
    var replyText: String
    var sessionId: String?
}
```

## 3. 会话续接规则

- 优先使用显式入参 `sessionId`。
- 未传时使用 `AgentService` 内部缓存的 `currentSessionId`。
- 本次返回了 `sessionId` 时，会覆盖 `currentSessionId`。
- 当前实现仅内存保存，**App 重启后不会持久化恢复**。

## 4. CLI 调用参数

基础参数：

```bash
qwen -p "<prompt>" --output-format json
```

可选参数：

- 会话续接：`--resume <sessionId>`

## 5. 输出解析约定

### 5.1 Qwen 输出

- 期望 JSON 数组
- 遍历消息，命中以下任一条件视为结果消息：
  - `type == "result"`
  - `subtype == "success"`
- 回复优先级：
  1. `message.content`
  2. `result`
- 会话 ID：任意消息中的 `session_id`

## 6. 错误语义

`AgentError`：

- `executableNotFound`：CLI 不存在
- `launchFailed`：进程启动失败
- `executionFailed`：CLI 返回非 0
- `parseError`：返回 JSON 结构不符合约定
- `timeout`：执行超时（`Configuration.agent.timeoutSeconds`）

在控制中心状态栏映射为：

- `Agent失败: <errorDescription>`

## 7. 实战经验与建议

- 会话续接核心是 Qwen 返回的 `session_id`，必须优先用结构化 JSON 解析，不建议用字符串匹配。
- 当前会话 ID 只在内存里，重启后会丢失；如果要跨重启续接，需要加持久化层（例如写入本地配置或数据库）。
- Prompt 应保持“短、可播报、无 Markdown”，否则 TTS 端会把符号和格式噪音也读出来，听感明显变差。
- `timeoutSeconds` 建议结合模型和网络实际延迟调参，过短会把可成功请求误判超时，过长会拖慢失败反馈。
- 当前只有 Qwen 一条执行链，输出解析应继续保持“先判结构再取内容”，避免上游格式变化导致静默失败。
