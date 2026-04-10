# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

**iAgent** 是一个本地语音助手控制台，运行于 macOS 菜单栏。基于 SwiftUI 构建，集成语音识别（ASR）、语音合成（TTS）和 AI Agent 服务。

## 构建与运行

```bash
cd /Users/admin/iCode/iAgent

# 调试构建（自动停止旧进程、清理、生成图标、启动）
make debug

# 发布构建（清理、版本自增、Release构建、安装到/Applications、Git推送）
make push MSG="提交信息"

# 直接安装到 /Applications
pkill -f "iAgent" 2>/dev/null; rm -rf /Applications/iAgent.app
cp -R build/Build/Products/Debug/iAgent.app /Applications/
open -a iAgent
```

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
- `client`: 麦克风设备索引、VAD 参数

运行时按”环境变量 -> JSON 配置文件 -> 代码默认值”优先级加载。

**配置方式（按优先级排序）**：

1. **环境变量**（推荐）：
   ```bash
   export IAGENT_ASR_API_KEY=”your-asr-api-key”
   export IAGENT_TTS_APP_ID=”your-tts-app-id”
   export IAGENT_TTS_ACCESS_TOKEN=”your-tts-access-token”
   ```

2. **配置文件**：
   复制 `config.example.json` 并配置：
   ```bash
   mkdir -p ~/Library/Application\ Support/iAgent
   cp config.example.json ~/Library/Application\ Support/iAgent/config.json
   # 编辑 config.json 填入真实凭证
   ```

凭证获取：https://console.volcengine.com（字节跳动火山引擎）

### 入口点

`main.swift` 手动创建 `NSApplication` 和 `AppDelegate`，不使用 `@main` 属性。

### ExecutableLocator

工具类定义在 `AudioProcessor.swift` 中，用于在 `PATH`、`/opt/homebrew/bin`、`/usr/local/bin` 中查找可执行文件（qwen）。

## 依赖要求

- **Agent CLI**: qwen
- **字节跳动 API**: ASR 和 TTS 凭证

## 外部脚本

`scripts/welcome-home` - 路由器端脚本，检测手机回家并触发 Agent 打招呼（通过 HTTP POST 到 `/v1/agent/respond`）。当前 HTTP 服务器功能已移除，此脚本可能已不适用。
