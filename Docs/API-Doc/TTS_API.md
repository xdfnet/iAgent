# TTS 接口文档

## 1. 接口定位

TTS 使用字节跳动流式合成接口，调用由 `TTSService.synthesize(text:)` 发起。  
`AgentControlCenter.speakTextInternal(_:)` 在收到 Agent 回复后调用该接口，再交给 `PlaybackService` 播放。

## 2. 请求规范

### 2.1 Endpoint

默认：

`https://openspeech.bytedance.com/api/v3/tts/unidirectional`

来源：`Configuration.textToSpeech.endpoint`

### 2.2 Header

- `Content-Type: application/json`
- `X-Api-App-Id: <appId>`
- `X-Api-Access-Key: <accessToken>`
- `X-Api-Resource-Id: <resourceId>`
- `X-Api-Request-Id: <uuid>`

### 2.3 Body

```json
{
  "user": { "uid": "<uuid>" },
  "namespace": "BidirectionalTTS",
  "req_params": {
    "text": "你好，飞哥",
    "speaker": "zh_female_tianmeitaozi_uranus_bigtts",
    "audio_params": {
      "format": "mp3",
      "sample_rate": 24000
    }
  }
}
```

## 3. 响应解析规则（SSE/流式）

`TTSService` 支持两类输入行：

1. 标准 SSE：`data: {...}`
2. 非标准直出 JSON 行：`{...}`

对每个事件：

- 忽略空行、注释行（`:` 开头）及 `event/id/retry` 元信息。
- 支持终止标记：`[DONE]`。
- 音频 base64 字段兼容路径：
  - `data`
  - `audio`
  - `audio_data`
  - `payload.audio`
  - `result.data`（递归兼容）

最终把所有 chunk 拼接为 MP3 二进制返回。

## 4. 错误语义

`TTSError`：

- `invalidResponse`：响应不是 HTTP
- `httpError(statusCode)`：HTTP 非 2xx
- `noAudioData`：流结束后无可解码音频 chunk
- `synthesisFailed(message)`：流事件显式报错

### 4.1 事件码判定（关键）

当前实现对 `code` 字段处理：

- `code == 0`：成功
- `code == 20000000`：按成功处理（兼容线上返回）
- 其他 code：仅当 message 呈现明显失败语义，或 `code >= 4000` 时判为失败

同时采用“先提取音频，再判错”策略，避免带业务 code 的正常音频事件被误判。

## 5. 控制中心状态映射

在 `AgentControlCenter` 中，TTS 相关状态：

- 合成前：`播报中`
- 合成失败：`播报失败: ...`
- 播放结束：`播报完成`

## 6. 实战经验与排障

- `code=20000000` 在实际流里可能是业务成功码，不能简单按“非 0 即失败”处理。
- 错误判定顺序应为“先尝试提取音频，再判错”，否则会把带状态码的正常音频事件误判成失败。
- 流式解析要同时兼容 `data: {...}` 和“纯 JSON 行”，部分服务端或网关会出现非标准输出。
- 对音频字段建议做多路径兼容（`data/audio/audio_data/payload.audio/result.data`），这是线上稳定性的关键。
- 出现 `noAudioData` 时，优先检查三项：
  1. Header 凭证（`appId/accessToken/resourceId`）是否匹配环境。
  2. 返回事件是否包含可解码 base64 音频字段。
  3. 是否被中间层改写为非标准 SSE（例如丢失 `data:` 前缀或行分割异常）。
