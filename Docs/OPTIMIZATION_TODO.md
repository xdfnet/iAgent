# iAgent Optimization TODO

更新时间：2026-04-06

## P0
- [x] 音频采集可观测性：为每个语音段输出关键指标（时长、峰值 RMS、触发阈值、是否播放中触发、是否触发打断）
- [x] 音频采集背压：限制 `segmentStream` 消费积压，避免连续说话导致处理延迟无限增长
- [x] `VoiceService` 采集错误上抛到 UI：把关键失败原因映射到 `statusMessage`

## P1
- [x] 配置对齐：清理或接入未生效配置项（保证“配置即行为”）
- [x] `main.swift` Swift 6 actor 隔离 warning 修复

## P2
- [x] 状态轮询降频/收敛：减少 `AgentControlCenter` 周期轮询依赖，优先事件驱动
- [x] 增加最小回归测试（至少覆盖：语音段处理主管线、播放状态流更新）
