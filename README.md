# iAgent

![Version](https://img.shields.io/badge/version-1.0.18-blue)
![Platform](https://img.shields.io/badge/platform-macOS-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

iAgent 是一款本地语音助手，运行于 macOS 菜单栏。通过语音完成日常任务——张嘴就来，不用打字。

贾维斯式的语音交互体验：**随时开口 → 理解执行 → 语音回应**，整个过程像对话一样自然。

**功能特性：**
- 语音控制电脑：执行命令、操作文件、开关程序
- 智能对话：查询信息、定提醒、写代码、处理杂事
- 持续监听：VAD 语音活动检测，无需按键自动唤醒
- 任何 CLI 能做到的事：只要说句话，Agent 帮你跑

**技术链路：**
麦克风 → VoiceService（`AVAudioEngine`）→ 字节跳动 ASR → Agent（Qwen CLI）→ 字节跳动 TTS → 播放

## 项目结构

```
iAgent/
├── main.swift               # 应用入口，手动创建 NSApplication
├── iAgentApp.swift          # AppDelegate / 菜单栏状态管理
├── AgentControlCenter.swift # 核心协调器（@MainActor @Observable）
├── VoiceService.swift       # 语音活动检测和麦克风捕获（Actor）
├── ASRService.swift         # 语音识别服务（Actor）
├── TTSService.swift         # 语音合成服务（Actor）
├── PlaybackService.swift    # 音频播放服务（Actor）
├── AgentService.swift       # AI Agent 执行器（Actor）
├── Configuration.swift      # 配置文件
├── AudioProcessor.swift     # 音频处理工具 + ExecutableLocator
└── ConversationMemory.swift # 对话记忆管理（最近 12 轮）
```

## 依赖要求

- **Agent CLI**：
  - [Qwen CLI](https://github.com/QwenLM/qwen-cli)

- **字节跳动 API**：ASR 和 TTS 凭证

## 配置

首次启动会自动创建配置文件 `~/.config/iAgent/config.json`，填入凭证后重启即可。

### 配置文件

`~/.config/iAgent/config.json`（XDG 规范）：

```json
{
  "speechToText": {
    "apiKey": "",
    "resourceId": "volc.bigasr.auc_turbo"
  },
  "textToSpeech": {
    "appId": "",
    "accessToken": "",
    "resourceId": "seed-tts-2.0",
    "voiceType": "zh_female_tianmeitaozi_uranus_bigtts"
  }
}
```

凭证获取：<https://console.volcengine.com>

### 环境变量（可选）

- `IAGENT_ASR_API_KEY`
- `IAGENT_TTS_APP_ID`
- `IAGENT_TTS_ACCESS_TOKEN`
- `IAGENT_CONFIG_PATH` - 自定义配置文件路径

### VAD 参数（语音活动检测）

配置文件中的 `client.continuous` 部分控制 VAD 行为：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `startThreshold` | 1300 | 开口阈值 |
| `playingStartThreshold` | 2800 | 播放中开口阈值 |
| `endThreshold` | 520 | 静音结束阈值 |
| `startFrames` | 5 | 连续超过阈值帧数 |
| `playingStartFrames` | 8 | 播放中触发所需帧数 |
| `endSilenceFrames` | 22 | 静音帧数后结束录音 |
| `prerollFrames` | 16 | 预留帧数，避免句首截断 |
| `minSpeechFrames` | 10 | 最短语音帧数 |
| `interruptOnSpeech` | false | 说话时是否打断播放 |

## 技术实现

- **SwiftUI**：声明式 UI 框架
- **Observation**：macOS 14+ 的状态管理（`@Observable`）
- **Actor**：线程安全的并发服务
- **AsyncStream**：服务间事件流通信
- **AVFoundation**：音频播放
- **Process**：外部进程管理

## 架构

`AgentControlCenter` 是单例中央协调器（`@MainActor @Observable`），管理所有服务生命周期：

```
用户说话 → VoiceService (VAD) → ASRService (转写) → AgentService (AI响应) → TTSService (合成) → PlaybackService (播放)
```

服务均基于 Actor 实现，通过 AsyncStream 实现状态同步：
- `VoiceService.stateStream`：监听状态变化
- `VoiceService.segmentStream`：语音片段数据（`VoiceSegment`）
- `VoiceService.errorStream`：错误信息
- `PlaybackService.stateStream`：播放状态

菜单栏层由 [iAgentApp.swift](/Users/admin/iCode/iAgent/iAgent/iAgentApp.swift) 通过 Observation 直接观察 `AgentControlCenter`，不再依赖状态轮询；仅最近一条文本展示使用短时 `Timer` 自动回退到状态文案。

## License

Personal use only.
