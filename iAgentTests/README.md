# iAgentTests README

本目录用于 iAgent 的单元测试与本地集成测试，目标是覆盖从采集到播报的完整时序链路，并验证 CLI 会话续接行为。

## 测试分层

- 纯逻辑/状态测试：
  - `PlaybackServiceStateStreamTests.swift`
  - `AgentControlCenterPipelineTests.swift`
  - `CoreUtilitiesCoverageTests.swift`
- 时序链路测试（控制中心编排）：
  - `AgentControlCenterVoiceTimingChainTests.swift`
- 本地集成测试（真实进程/本地网络 stub）：
  - `AgentServiceSessionIntegrationTests.swift`
  - `VoiceServiceCaptureIntegrationTests.swift`
  - `ASRAndTTSLocalIntegrationTests.swift`
- 覆盖补强（分支/异常/生命周期）：
  - `PlaybackServiceCoverageTests.swift`
  - `AgentControlCenterCoverageTests.swift`
  - `AgentServiceCoverageTests.swift`
  - `ASRAndTTSErrorCoverageTests.swift`
  - `VoiceServiceCoverageTests.swift`
  - `AppDelegateAndViewCoverageTests.swift`

## 覆盖范围

- 主管线：`Voice Segment -> ASR -> Agent -> TTS -> Playback`
- 分支：`autoSpeak=false`、ASR 失败下游短路
- 播放状态流：`idle -> playing -> idle`
- 会话续接：Qwen `--resume`
- 本地 HTTP / SSE：ASR 普通 JSON、TTS SSE 流式音频拼接
- 采集分段：`VoiceService` 捕获循环 + VAD 分段产出
- 服务生命周期：`bootstrap/start/toggle/stop`、菜单栏 Observation 更新、退出清理
- 异常传播：ASR HTTP 错误、ASR 无结果、TTS HTTP 错误、TTS SSE 解析异常、Agent 超时/执行失败/启动失败
- 播放分支：`AVAudioPlayer` 路径、`afplay` 回退路径、打断/等待分支、临时文件清理

## 运行方式

在仓库根目录执行：

```bash
xcodebuild -project iAgent.xcodeproj -scheme iAgent -configuration Debug test -only-testing:iAgentTests
```

按文件运行示例：

```bash
xcodebuild -project iAgent.xcodeproj -scheme iAgent -configuration Debug test -only-testing:iAgentTests/AgentServiceSessionIntegrationTests
```

## 编写约定

- 默认使用本地 stub，不依赖外网和真实第三方服务。
- 需要真实进程行为时，优先用临时脚本 + 临时目录，测试结束后自动清理。
- 新测试优先验证“时序顺序 + 数据传递 + 失败传播”，避免只测 happy path。
- 若新增测试专用入口（如 `_xxxForTesting`），保持最小暴露，仅用于测试编排。
