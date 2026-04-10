# ASR 接口文档

## 1. 接口定位

ASR（语音识别）负责把语音片段转成文本。  
在工程中的调用入口是 `AgentControlCenter.transcribeAudioData(_:)`，实际请求由 `ASRService.transcribe(audioData:format:)` 发起。

## 2. 请求规范

### 2.1 Endpoint

默认：

`https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash`

来源：`Configuration.speechToText.flashUrl`

### 2.2 Header

- `Content-Type: application/json`
- `X-Api-Key: <apiKey>`
- `X-Api-Resource-Id: <resourceId>`
- `X-Api-Request-Id: <uuid>`
- `X-Api-Sequence: -1`

### 2.3 Body

```json
{
  "user": { "uid": "iagent" },
  "audio": {
    "data": "<base64>",
    "format": "wav",
    "codec": "raw",
    "rate": 16000,
    "bits": 16,
    "channel": 1
  },
  "request": {
    "model_name": "bigmodel",
    "enable_itn": true,
    "enable_punc": true,
    "enable_ddc": false,
    "enable_speaker_info": false,
    "enable_channel_split": false,
    "show_utterances": false,
    "vad_segment": false,
    "sensitive_words_filter": ""
  }
}
```

## 3. 音频格式策略（关键）

当前实现已做如下处理：

- 输入是 `pcm` 时，先在客户端封装成 `wav` 容器再上传（`format=wav, codec=raw`）。
- 输入是 `wav` 时，直接上传（`codec=raw`）。
- 输入是 `ogg` 时，`codec=opus`。
- 输入是 `mp3` 时，`codec=mp3`。

这样做是为了解决“HTTP 成功但 ASR 返回空结果”的线上问题。

## 4. 响应解析规则

`ASRService` 采用“两阶段解析”：

1. 强类型结构解析（`ASRResponse`）
2. 宽松 JSON 兜底解析（兼容字段变体）

文本提取优先级：

1. `result.text`
2. `result.utterances[].text`（拼接）
3. `result.nbest[0].text`
4. `text`
5. `utterances[].text`
6. `nbest[0].text`
7. `data` 节点递归中的上述字段

如果都拿不到文本，返回 `ASRError.noResult`，并打印返回体片段用于排障。

## 5. 错误语义与状态映射

`ASRError`：

- `invalidURL`：地址非法
- `invalidResponse`：非 HTTP 响应
- `httpError(statusCode, message)`：HTTP 非 2xx
- `decodingError`：解码失败
- `noResult`：未提取到可用文本

在控制中心状态中：

- `noResult` 映射为：`ASR未识别到有效语音，请再说一次`
- 其他错误映射为：`ASR失败: ...`

## 6. 实战经验与排障

- 若出现“ASR 未返回结果”，优先确认是否上传了 `wav` 容器而不是裸 `pcm`。
- `rate/bits/channel` 必须与采集一致（当前默认 `16000/16/1`），不一致会显著降低识别率。
- 先看 HTTP 状态码，再看返回体结构；很多问题是“接口成功但字段不在预期路径”。
- 噪声环境下应优先保证 VAD 切段质量，否则 ASR 常表现为空结果或短句误识别。

