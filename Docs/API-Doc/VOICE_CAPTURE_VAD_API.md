# 语音采集与 VAD 文档


## 1. 接口定位

语音采集与切段由 `VoiceService` 负责，核心入口：

- `startListening()`
- `stopListening()`
- `setPlaybackActive(_:)`
- `setSpeechDetectionSuspended(_:cooldownSeconds:)`

`AgentControlCenter` 通过三个流对接：

- `stateStream`：状态流（更新菜单栏文案）
- `segmentStream`：语音片段流（`VoiceSegment`，包含 `deviceID/audioData/capturedAt`）
- `errorStream`：采集关键异常流（用于恢复和用户态故障提示）
- `diagnosticStream`：非阻塞诊断流（如 VAD 自适应调参日志）

---

## 2. 采集命令与设备选择

当前采集链路使用 `AVAudioEngine`。

关键配置来自 `Configuration.shared.client`：

- `inputDeviceIndex`：默认 `"0"`，当前运行时会归一化成单个设备 ID
- `audio.sampleRate/channels/sampleWidth`：定义帧大小和 PCM 读取格式

当前会直接建立 `NativeCaptureSession` 并把 PCM 帧送入同一套 VAD 状态机。

---

## 3. VAD 判定参数（默认值）

- `frameMs = 30`
- `startThreshold = 1300`
- `playingStartThreshold = 2800`
- `endThreshold = 520`
- `startFrames = 5`（约 150ms）
- `playingStartFrames = 8`（约 240ms）
- `endSilenceFrames = 22`（约 660ms）
- `prerollFrames = 16`（约 480ms）
- `minSpeechFrames = 10`（约 300ms）
- `postInterruptCooldownSeconds = 1.2`
- `interruptOnSpeech = false`

判定逻辑：

1. 静默阶段：RMS 连续超过阈值达到 `startFrames`（或播放中 `playingStartFrames`）进入 `speaking`
2. 语音阶段：RMS 连续低于 `endThreshold` 达到 `endSilenceFrames`，且总帧数 `>= minSpeechFrames`，进入 `processing`
3. 输出切段：`preroll + speechFrames` 合并后通过 `segmentStream` 发出
4. 单段最长 `8s`，超过后强制收段，避免长期卡在 `speaking`

---

## 4. 自适应阈值与保护机制

### 4.1 自适应阈值（4 秒窗口）

在未进入 `speaking` 前统计平均 RMS 和峰值：

- 若环境能量很低，会自动下调阈值并通过 `diagnosticStream` 输出调参日志
- 下调后用于后续开口和收尾判定，减少“有声但一直不触发”

### 4.2 零能量保护（8 秒）

- 若长期 `RMS == 0`（按 `frameMs` 计算约 8 秒）：
  - 上报 `持续检测到零能量音频...`
  - 会退出当前会话并进入恢复路径

### 4.3 处理中/播报中挂起检测

- 语音段一旦结束并进入 `processing`，`VoiceService` 会立即挂起新的语音检测
- `AgentControlCenter` 在整轮 `ASR -> Agent -> TTS -> Playback` 完成后，才会恢复检测
- 这意味着“播报完成前不要采集语音”已经由代码保证

### 4.4 背压保护

- `segmentStream` 仅保留最新 1 段（`bufferingNewest(1)`）
- 上游快于下游时，旧段会被丢弃并打印 `dropped due to backpressure`

---

## 5. 状态映射（菜单栏可见）

`VoiceService.State` 到 `AgentControlCenter.statusMessage`：

- `idle` -> `等待说话`
- `listening` -> `正在监听...`
- `interruptingPlayback` -> `检测到语音，正在打断播放...`
- `speaking` -> `检测到语音...`
- `processing` -> `处理中...`

此外：

- 采集异常通过 `errorStream` 映射为 `采集异常: <message>`
- 诊断信息不会进入恢复逻辑，也不会覆盖用户态异常文案
- `segmentStream` 收到片段后状态转为 `识别中...`，进入 ASR 链路
- `listening` 现在只会在整轮处理真正结束后重新发出，不会在片段刚投递时提前恢复

---

## 6. 常见问题与排障

1. 菜单栏看不到“正在监听...”
   - 先确认服务已启动成功
   - 当前实现已修复订阅时序：先订阅 `stateStream`，再 `startListening()`

2. 说话后没有反应
   - 先看是否有 `持续检测到零能量音频` 提示
   - 检查 `inputDeviceIndex` 是否指向正确麦克风，当前默认是 `"0"`
   - 观察 RMS 日志是否长期低于 `startThreshold`

3. 句首被截断或短句丢失
   - 调大 `prerollFrames`
   - 适当降低 `minSpeechFrames` 或 `startFrames`

4. 语音切段偏晚
   - 适当降低 `endSilenceFrames` 或 `endThreshold`

5. 回声或播报干扰识别
   - 当前代码已经在播报完成前挂起新的采集
   - 如需“说话打断播报”能力，再开启 `interruptOnSpeech`，并配合更高 `playingStartThreshold`
