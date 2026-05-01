//
//  BehaviorService.swift
//  iAgent
//
//  行为驱动上下文服务
//

import Foundation

actor BehaviorService {
    struct PresenceSignals: Sendable {
        let routerReachable: Bool
        let associatedInterface: String?

        var isConfirmedPresent: Bool {
            associatedInterface != nil
        }

        var summaryText: String {
            let sshSummary = "ssh=\(routerReachable ? "ok" : "fail")"
            let interfaceSummary = "iface=\(associatedInterface ?? "none")"
            return "\(sshSummary), \(interfaceSummary)"
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
        var routerSSHHost: String
        var monitoredPhoneMAC: String
        var monitoredWiFiInterfaces: [String]
        var pollIntervalSeconds: Double
        var contextTTLSeconds: Double
        var cooldownSeconds: Double
        var requiredOnlineConfirmations: Int
        var requiredOfflineConfirmations: Int

        static var `default`: Config {
            let settings = Configuration.shared.behavior
            return Config(
                enabled: settings.enabled,
                routerSSHHost: settings.routerSSHHost,
                monitoredPhoneMAC: settings.monitoredPhoneMAC,
                monitoredWiFiInterfaces: settings.monitoredWiFiInterfaces
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty },
                pollIntervalSeconds: settings.pollIntervalSeconds,
                contextTTLSeconds: settings.contextTTLSeconds,
                cooldownSeconds: settings.cooldownSeconds,
                requiredOnlineConfirmations: settings.requiredOnlineConfirmations,
                requiredOfflineConfirmations: settings.requiredOfflineConfirmations
            )
        }
    }

    private let config: Config
    private let contextEventStreamStorage: AsyncStream<Context>
    private var contextEventContinuation: AsyncStream<Context>.Continuation?
    private var monitoringTask: Task<Void, Never>?
    private var activeContext: Context?
    private var lastKnownPhonePresence: Bool?
    private var lastArrivalDetectedAt: Date?
    private var consecutiveOnlineDetections = 0
    private var consecutiveOfflineDetections = 0
    private var lastDecisionSummary = "等待行为信号"
    private var lastSignalSummary = "尚未开始在线探测"
    private var recentEvents: [String] = []
#if DEBUG
    private var presenceCheckOverride: ((String) async -> Bool)?
#endif

    init(config: Config = .default) {
        var continuation: AsyncStream<Context>.Continuation?
        self.contextEventStreamStorage = AsyncStream { continuation = $0 }
        self.contextEventContinuation = continuation
        self.config = config
    }

    func contextEventStream() -> AsyncStream<Context> {
        contextEventStreamStorage
    }

    func startMonitoring() {
        guard config.enabled else { return }
        guard monitoringTask == nil else { return }

        lastDecisionSummary = "行为监控已启动"
        recordEvent("开始监控手机在线，目标 \(config.monitoredPhoneMAC)")

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

    private func pollPresence() async {
        let monitoredPhoneMAC = config.monitoredPhoneMAC.trimmingCharacters(in: .whitespacesAndNewlines)
        guard config.enabled, !monitoredPhoneMAC.isEmpty else { return }
        guard !config.monitoredWiFiInterfaces.isEmpty else {
            lastDecisionSummary = "未配置路由器无线接口"
            lastSignalSummary = "路由器关联探测：未配置接口"
            return
        }

        let isPresent = await isPhonePresent(target: monitoredPhoneMAC)
        handlePhonePresence(isPresent, source: "router_assoc:\(monitoredPhoneMAC)")
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
                lastDecisionSummary = "手机在线已确认"
                recordEvent("手机在线确认完成")
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
                lastDecisionSummary = "手机在线"
            }
            return
        }

        guard isPresent, consecutiveOnlineDetections >= onlineThreshold else {
            lastDecisionSummary = "等待手机在线确认 \(consecutiveOnlineDetections)/\(onlineThreshold)"
            return
        }

        lastKnownPhonePresence = true
        lastDecisionSummary = "手机在线已确认"
        recordEvent("手机在线确认完成")
        maybeTriggerArrivedHome(source: source)
    }

    private func maybeTriggerArrivedHome(source: String, now: Date = Date()) {
        guard lastKnownPhonePresence == true else {
            lastDecisionSummary = "等待手机在线"
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
        contextEventContinuation?.yield(activeContext!)
        Logger.log("detected arrived_home, source=\(source)", category: .behavior)
    }

    private func clearExpiredContextIfNeeded(now: Date = Date()) {
        guard let context = activeContext else { return }
        guard context.expiresAt <= now else { return }

        activeContext = nil
        lastDecisionSummary = "行为上下文已过期，等待新信号"
        recordEvent("\(context.scene.rawValue) 上下文已过期", now: now)
    }

    private func isPhonePresent(target: String) async -> Bool {
#if DEBUG
        if let presenceCheckOverride {
            return await presenceCheckOverride(target)
        }
#endif
        return await runPresenceCheck(target)
    }

    private func runPresenceCheck(_ monitoredPhoneMAC: String) async -> Bool {
        let signals = await probePresenceSignals(monitoredPhoneMAC)
        lastSignalSummary = "路由器关联探测：\(signals.summaryText)"
        return signals.isConfirmedPresent
    }

    private func probePresenceSignals(_ monitoredPhoneMAC: String) async -> PresenceSignals {
        let normalizedMAC = monitoredPhoneMAC.lowercased()
        let interfaces = config.monitoredWiFiInterfaces.map(ExecutableLocator.shellQuote).joined(separator: " ")
        let remoteCommand = """
        for ifname in \(interfaces); do
          if iwinfo "$ifname" assoclist 2>/dev/null | grep -iq \(ExecutableLocator.shellQuote(normalizedMAC)); then
            echo "associated:$ifname"
            exit 0
          fi
        done
        echo "not-associated"
        exit 3
        """
        let sshCommand = "ssh \(ExecutableLocator.shellQuote(config.routerSSHHost)) \(ExecutableLocator.shellQuote(remoteCommand))"
        let result = await runShellCommand(sshCommand)
        let associatedInterface = Self.associatedInterface(from: result.standardOutput)

        return PresenceSignals(
            routerReachable: result.terminationStatus != 255,
            associatedInterface: associatedInterface
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

    nonisolated static func associatedInterface(from output: String) -> String? {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        guard normalized.hasPrefix("associated:") else { return nil }
        let interface = normalized.replacingOccurrences(of: "associated:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return interface.isEmpty ? nil : interface
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

    nonisolated static func _associatedInterfaceForTesting(_ output: String) -> String? {
        associatedInterface(from: output)
    }

    func _setDiagnosticsForTesting(summary: String, signalSummary: String, eventLines: [String]) {
        lastDecisionSummary = summary
        lastSignalSummary = signalSummary
        recentEvents = eventLines
    }
}
#endif
