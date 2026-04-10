//
//  BehaviorService.swift
//  iAgent
//
//  行为驱动上下文服务
//

import Foundation

actor BehaviorService {
    struct PresenceSignals: Sendable {
        let pingSucceeded: Bool
        let arpResolved: Bool

        var isConfirmedPresent: Bool {
            pingSucceeded && arpResolved
        }

        var summaryText: String {
            "ping=\(pingSucceeded ? "ok" : "fail"), arp=\(arpResolved ? "ok" : "fail")"
        }
    }

    struct DiagnosticsSnapshot: Sendable {
        let summary: String
        let signalSummary: String
        let eventLines: [String]
    }

    enum Scene: String, Sendable {
        case arrivedHome = "arrived_home"
    }

    struct Context: Sendable {
        let scene: Scene
        let message: String
        let source: String
        let detectedAt: Date
        let expiresAt: Date
    }

    struct Config: Sendable {
        var enabled: Bool
        var monitoredPhoneIP: String
        var pollIntervalSeconds: Double
        var contextTTLSeconds: Double
        var cooldownSeconds: Double
        var requiredOnlineConfirmations: Int
        var requiredOfflineConfirmations: Int
        var activitySignalWindowSeconds: Double

        static var `default`: Config {
            let settings = Configuration.shared.behavior
            return Config(
                enabled: settings.enabled,
                monitoredPhoneIP: settings.monitoredPhoneIP,
                pollIntervalSeconds: settings.pollIntervalSeconds,
                contextTTLSeconds: settings.contextTTLSeconds,
                cooldownSeconds: settings.cooldownSeconds,
                requiredOnlineConfirmations: settings.requiredOnlineConfirmations,
                requiredOfflineConfirmations: settings.requiredOfflineConfirmations,
                activitySignalWindowSeconds: settings.activitySignalWindowSeconds
            )
        }
    }

    private let config: Config
    private var monitoringTask: Task<Void, Never>?
    private var activeContext: Context?
    private var lastKnownPhonePresence: Bool?
    private var lastArrivalDetectedAt: Date?
    private var lastMacWakeAt: Date?
    private var lastSessionActivationAt: Date?
    private var consecutiveOnlineDetections = 0
    private var consecutiveOfflineDetections = 0
    private var lastDecisionSummary = "等待行为信号"
    private var lastSignalSummary = "尚未开始在线探测"
    private var recentEvents: [String] = []
#if DEBUG
    private var presenceCheckOverride: ((String) async -> Bool)?
#endif

    init(config: Config = .default) {
        self.config = config
    }

    func startMonitoring() {
        guard config.enabled else { return }
        guard monitoringTask == nil else { return }

        lastDecisionSummary = "行为监控已启动"
        recordEvent("开始监控手机在线，目标 \(config.monitoredPhoneIP)")

        monitoringTask = Task { [pollIntervalSeconds = config.pollIntervalSeconds] in
            await pollPresence()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(pollIntervalSeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await pollPresence()
            }
        }
    }

    func stopMonitoring(clearContext: Bool = false) {
        monitoringTask?.cancel()
        monitoringTask = nil
        lastKnownPhonePresence = nil
        lastMacWakeAt = nil
        lastSessionActivationAt = nil
        consecutiveOnlineDetections = 0
        consecutiveOfflineDetections = 0
        lastDecisionSummary = "行为监控已停止"
        lastSignalSummary = "监控已停止"
        recordEvent("停止行为监控")
        if clearContext {
            activeContext = nil
        }
    }

    func currentContext() -> Context? {
        clearExpiredContextIfNeeded()
        guard let context = activeContext else { return nil }
        return context
    }

    func consumePromptContextIfAvailable() -> String? {
        guard let context = currentContext() else { return nil }
        activeContext = nil
        lastDecisionSummary = "行为上下文已注入到本轮对话"
        recordEvent("上下文已消费：\(context.scene.rawValue)")
        return context.message
    }

    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        clearExpiredContextIfNeeded()
        return DiagnosticsSnapshot(
            summary: lastDecisionSummary,
            signalSummary: lastSignalSummary,
            eventLines: recentEvents
        )
    }

    func noteMacDidWake() {
        lastMacWakeAt = Date()
        lastDecisionSummary = "已收到 Mac 唤醒信号，等待解锁与手机在线"
        recordEvent("收到系统唤醒事件")
        maybeTriggerArrivedHome(source: "mac_wake")
    }

    func noteSessionDidBecomeActive() {
        lastSessionActivationAt = Date()
        lastDecisionSummary = "已收到会话激活信号，等待手机在线与唤醒条件"
        recordEvent("收到会话激活/解锁事件")
        maybeTriggerArrivedHome(source: "session_active")
    }

    private func pollPresence() async {
        let monitoredPhoneIP = config.monitoredPhoneIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.enabled, !monitoredPhoneIP.isEmpty else { return }

        let isPresent = await isPhonePresent(ipAddress: monitoredPhoneIP)
        handlePhonePresence(isPresent, source: "phone_presence:\(monitoredPhoneIP)")
    }

    private func handlePhonePresence(_ isPresent: Bool, source: String) {
        if isPresent {
            consecutiveOnlineDetections += 1
            consecutiveOfflineDetections = 0
        } else {
            consecutiveOfflineDetections += 1
            consecutiveOnlineDetections = 0
        }

        let onlineThreshold = max(1, config.requiredOnlineConfirmations)
        let offlineThreshold = max(1, config.requiredOfflineConfirmations)

        guard let stablePhonePresence = lastKnownPhonePresence else {
            if isPresent, consecutiveOnlineDetections >= onlineThreshold {
                lastKnownPhonePresence = true
                lastDecisionSummary = "手机在线已确认，等待唤醒与解锁"
                recordEvent("手机在线确认完成")
                maybeTriggerArrivedHome(source: source)
            } else if !isPresent, consecutiveOfflineDetections >= offlineThreshold {
                lastKnownPhonePresence = false
                lastDecisionSummary = "手机当前离线"
            } else if isPresent {
                lastDecisionSummary = "等待手机在线确认 \(consecutiveOnlineDetections)/\(onlineThreshold)"
            } else {
                lastDecisionSummary = "等待离线确认 \(consecutiveOfflineDetections)/\(offlineThreshold)"
            }
            return
        }

        if stablePhonePresence {
            if !isPresent, consecutiveOfflineDetections >= offlineThreshold {
                lastKnownPhonePresence = false
                lastDecisionSummary = "手机离线已确认"
                recordEvent("手机离线确认完成")
            } else if isPresent {
                lastDecisionSummary = "手机在线，等待唤醒与解锁"
            }
            return
        }

        guard isPresent, consecutiveOnlineDetections >= onlineThreshold else {
            lastDecisionSummary = "等待手机在线确认 \(consecutiveOnlineDetections)/\(onlineThreshold)"
            return
        }

        lastKnownPhonePresence = true
        lastDecisionSummary = "手机在线已确认，等待唤醒与解锁"
        recordEvent("手机在线确认完成")
        maybeTriggerArrivedHome(source: source)
    }

    private func maybeTriggerArrivedHome(source: String, now: Date = Date()) {
        guard lastKnownPhonePresence == true else {
            lastDecisionSummary = "等待手机在线"
            return
        }
        guard hasRecentSignal(lastMacWakeAt, now: now) else {
            lastDecisionSummary = "手机在线已确认，等待最近一次 Mac 唤醒"
            return
        }
        guard hasRecentSignal(lastSessionActivationAt, now: now) else {
            lastDecisionSummary = "手机在线与唤醒已确认，等待解锁/会话激活"
            return
        }

        if let lastArrivalDetectedAt, now.timeIntervalSince(lastArrivalDetectedAt) < config.cooldownSeconds {
            lastDecisionSummary = "回家场景冷却中"
            return
        }

        activeContext = Context(
            scene: .arrivedHome,
            message: "飞哥回来了，和他打个招呼",
            source: source,
            detectedAt: now,
            expiresAt: now.addingTimeInterval(config.contextTTLSeconds)
        )
        lastArrivalDetectedAt = now
        lastDecisionSummary = "已生成 arrived_home 行为上下文"

        recordEvent("触发 arrived_home，来源 \(source)")
        print("[BehaviorService] detected arrived_home, source=\(source)")
    }

    private func clearExpiredContextIfNeeded(now: Date = Date()) {
        guard let context = activeContext else { return }
        guard context.expiresAt <= now else { return }

        activeContext = nil
        lastDecisionSummary = "行为上下文已过期，等待新信号"
        recordEvent("\(context.scene.rawValue) 上下文已过期", now: now)
    }

    private func hasRecentSignal(_ timestamp: Date?, now: Date) -> Bool {
        guard let timestamp else { return false }
        return now.timeIntervalSince(timestamp) <= config.activitySignalWindowSeconds
    }

    private func isPhonePresent(ipAddress: String) async -> Bool {
#if DEBUG
        if let presenceCheckOverride {
            return await presenceCheckOverride(ipAddress)
        }
#endif
        return await runPresenceCheck(ipAddress)
    }

    private func runPresenceCheck(_ ipAddress: String) async -> Bool {
        let signals = await probePresenceSignals(ipAddress)
        lastSignalSummary = "手机在线探测：\(signals.summaryText)"
        if signals.pingSucceeded, !signals.arpResolved {
            recordEvent("ping 可达，但 arp 未解析 \(ipAddress)")
            print("[BehaviorService] ping ok but arp unresolved, ip=\(ipAddress)")
        }
        return signals.isConfirmedPresent
    }

    private func probePresenceSignals(_ ipAddress: String) async -> PresenceSignals {
        let pingSucceeded = await runShellCommand(
            "ping -c 1 -W 1000 \(ExecutableLocator.shellQuote(ipAddress)) >/dev/null 2>&1"
        ).terminationStatus == 0

        let arpCommand = "arp -n \(ExecutableLocator.shellQuote(ipAddress)) 2>/dev/null || true"
        let arpOutput = await runShellCommand(arpCommand).standardOutput
        let arpResolved = Self.arpOutputIndicatesResolvedNeighbor(arpOutput)

        return PresenceSignals(
            pingSucceeded: pingSucceeded,
            arpResolved: arpResolved
        )
    }

    private func runShellCommand(_ command: String) async -> (terminationStatus: Int32, standardOutput: String) {
        await withCheckedContinuation { continuation in
            let stdout = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.environment = ExecutableLocator.runtimeEnvironment()
            process.standardOutput = stdout
            process.standardError = Pipe()

            process.terminationHandler = { process in
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(
                    returning: (
                        terminationStatus: process.terminationStatus,
                        standardOutput: output
                    )
                )
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (terminationStatus: -1, standardOutput: ""))
            }
        }
    }

    nonisolated static func arpOutputIndicatesResolvedNeighbor(_ output: String) -> Bool {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        guard !normalized.contains("no entry") else { return false }
        guard !normalized.contains("incomplete") else { return false }
        return normalized.contains(" at ")
    }

    private func recordEvent(_ message: String, now: Date = Date()) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: now)) \(message)"
        recentEvents.insert(line, at: 0)
        if recentEvents.count > 5 {
            recentEvents = Array(recentEvents.prefix(5))
        }
    }
}

#if DEBUG
extension BehaviorService {
    func _setPresenceCheckOverrideForTesting(_ override: ((String) async -> Bool)?) {
        presenceCheckOverride = override
    }

    func _pollPresenceOnceForTesting() async {
        await pollPresence()
    }

    func _currentContextForTesting() -> Context? {
        currentContext()
    }

    func _consumePromptContextForTesting() -> String? {
        consumePromptContextIfAvailable()
    }

    func _setLastKnownPhonePresenceForTesting(_ value: Bool?) {
        lastKnownPhonePresence = value
    }

    func _setLastArrivalDetectedAtForTesting(_ value: Date?) {
        lastArrivalDetectedAt = value
    }

    func _setActiveContextForTesting(_ context: Context?) {
        activeContext = context
    }

    func _setConsecutiveDetectionsForTesting(online: Int, offline: Int) {
        consecutiveOnlineDetections = online
        consecutiveOfflineDetections = offline
    }

    func _setLastMacWakeAtForTesting(_ value: Date?) {
        lastMacWakeAt = value
    }

    func _setLastSessionActivationAtForTesting(_ value: Date?) {
        lastSessionActivationAt = value
    }

    nonisolated static func _arpOutputIndicatesResolvedNeighborForTesting(_ output: String) -> Bool {
        arpOutputIndicatesResolvedNeighbor(output)
    }

    func _setDiagnosticsForTesting(summary: String, signalSummary: String, eventLines: [String]) {
        lastDecisionSummary = summary
        lastSignalSummary = signalSummary
        recentEvents = eventLines
    }
}
#endif
