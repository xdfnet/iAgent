# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## 项目概述

**iAgent** 是一个本地语音助手控制台，运行于 macOS 菜单栏。基于 SwiftUI 构建，集成语音识别（ASR）、语音合成（TTS）和 AI Agent 服务。

## 构建与运行

```bash
# 使用 Xcode 构建
xcodebuild -project iAgent.xcodeproj -scheme iAgent -configuration Debug build

# 运行应用
open -a iAgent
```

## 测试

```bash
# 推荐：仅运行单元/集成测试（稳定）
xcodebuild -project iAgent.xcodeproj -scheme iAgent -destination 'platform=macOS' test -only-testing:iAgentTests

# 全量测试（含 UI Tests）
xcodebuild -project iAgent.xcodeproj -scheme iAgent -destination 'platform=macOS' test
```

说明：当前 `iAgentUITests` 目标未配置测试源码时，全量测试可能因 UI Test bundle 无可执行文件而失败。

## 架构

### 核心协调器模式

`AgentControlCenter` 是单例中央协调器（`@MainActor @Observable`），管理所有服务生命周期和数据流：

```
用户说话 → VoiceService (VAD) → ASRService (转写) → AgentService (AI响应) → TTSService (合成) → PlaybackService (播放)
```

### 服务组件（均为 Actor）

| 服务 | 职责 | 外部依赖 |
|------|------|----------|
| `VoiceService` | 语音活动检测、原生麦克风采集 | AVFoundation |
| `ASRService` | 字节跳动 ASR API 语音转文字 | 字节跳动 API |
| `TTSService` | 字节跳动 TTS API 文字转语音 | 字节跳动 API |
| `AgentService` | 执行 Qwen CLI | qwen 可执行文件 |
| `PlaybackService` | 音频播放（AVFoundation） | - |
| `ConversationMemory` | 保存最近 12 轮对话上下文 | - |

### 数据流

1. `VoiceService` 通过原生音频采集获取麦克风输入
2. 检测到语音片段后，通过 `segmentStream` AsyncStream 发出 `VoiceSegment`
3. `AgentControlCenter` 订阅 `segmentStream`，依次调用 ASR → Agent → TTS → Playback
4. `AppDelegate` 通过 Observation 直接监听 `AgentControlCenter` 状态，更新菜单栏图标和文本

### 配置

`Configuration.shared` 是全局配置单例，包含：
- `speechToText`: ASR API 凭证
- `textToSpeech`: TTS API 凭证
- `agent`: Qwen 工作目录、超时设置
- `client`: 麦克风设备 ID、VAD 参数

运行时按“环境变量 -> JSON 配置文件 -> 代码默认值”优先级加载。
修改配置可直接编辑 `iAgent/Configuration.swift`，或使用外部配置覆盖。
请勿将真实生产凭证提交到仓库。

### 入口点

`main.swift` 手动创建 `NSApplication` 和 `AppDelegate`，不使用 `@main` 属性。

### ExecutableLocator

工具类定义在 `AudioProcessor.swift` 中，用于在 `PATH`、`/opt/homebrew/bin`、`/usr/local/bin` 中查找可执行文件（qwen）。

## 依赖要求

- **Agent CLI**: qwen
- **字节跳动 API**: ASR 和 TTS 凭证

## 外部脚本

`scripts/welcome-home` - 路由器端脚本，检测手机回家并触发 Agent 打招呼（通过 HTTP POST 到 `/v1/agent/respond`）。当前 HTTP 服务器功能已移除，此脚本可能已不适用。
