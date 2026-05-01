import XCTest
@testable import iAgent

final class BehaviorServiceCoverageTests: XCTestCase {
    func testInitialPresenceDoesNotImmediatelyCreateArrivedHomeContext() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 2,
                requiredOfflineConfirmations: 2
            )
        )

        await service._setPresenceCheckOverrideForTesting { _ in true }
        await service._pollPresenceOnceForTesting()

        let context = await service._currentContextForTesting()
        XCTAssertNil(context)
    }

    func testOfflineToOnlineTransitionCreatesArrivedHomeContextAfterStableOnlineConfirmation() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 2,
                requiredOfflineConfirmations: 2
            )
        )

        await service._setLastKnownPhonePresenceForTesting(false)
        await service._setPresenceCheckOverrideForTesting { _ in true }
        await service._pollPresenceOnceForTesting()
        let firstContext = await service._currentContextForTesting()
        XCTAssertNil(firstContext)

        await service._pollPresenceOnceForTesting()
        let context = await service._currentContextForTesting()
        XCTAssertEqual(context?.scene, .arrivedHome)
        XCTAssertEqual(context?.message, "飞哥回来了，和他打个招呼")

        let consumedMessage = await service._consumePromptContextForTesting()
        XCTAssertEqual(consumedMessage, "飞哥回来了，和他打个招呼")
        let consumedAgain = await service._consumePromptContextForTesting()
        XCTAssertNil(consumedAgain)
    }

    func testCooldownBlocksRepeatedArrivedHomeDetection() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 2,
                requiredOfflineConfirmations: 2
            )
        )

        let now = Date()
        await service._setLastKnownPhonePresenceForTesting(true)
        await service._setLastArrivalDetectedAtForTesting(now)
        await service._setPresenceCheckOverrideForTesting { _ in true }
        await service._pollPresenceOnceForTesting()

        let context = await service._currentContextForTesting()
        XCTAssertNil(context)
    }

    func testSinglePositiveBounceDoesNotTriggerArrivedHomeContext() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 2,
                requiredOfflineConfirmations: 2
            )
        )

        await service._setLastKnownPhonePresenceForTesting(false)
        await service._setPresenceCheckOverrideForTesting { _ in true }
        await service._pollPresenceOnceForTesting()
        await service._setPresenceCheckOverrideForTesting { _ in false }
        await service._pollPresenceOnceForTesting()

        let context = await service._currentContextForTesting()
        XCTAssertNil(context)
    }

    func testStableOnlineCanTriggerWithoutWakeOrUnlock() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 1,
                requiredOfflineConfirmations: 1
            )
        )

        await service._setLastKnownPhonePresenceForTesting(false)
        await service._setPresenceCheckOverrideForTesting { _ in true }
        await service._pollPresenceOnceForTesting()

        let context = await service._currentContextForTesting()
        XCTAssertEqual(context?.scene, .arrivedHome)
    }

    func testAssociatedInterfaceParsesDetectedInterface() {
        let output = "associated:rax0"
        XCTAssertEqual(BehaviorService._associatedInterfaceForTesting(output), "rax0")
    }

    func testAssociatedInterfaceRejectsNonAssociatedOutput() {
        let output = "not-associated"
        XCTAssertNil(BehaviorService._associatedInterfaceForTesting(output))
    }

    func testExpiredContextDowngradesDiagnosticsSummary() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 1,
                requiredOfflineConfirmations: 1
            )
        )

        let expiredContext = BehaviorService.Context(
            scene: .arrivedHome,
            message: "飞哥回来了，和他打个招呼",
            source: "testing",
            detectedAt: Date(timeIntervalSinceNow: -20),
            expiresAt: Date(timeIntervalSinceNow: -10)
        )

        await service._setActiveContextForTesting(expiredContext)
        let snapshot = await service.diagnosticsSnapshot()
        let currentContext = await service._currentContextForTesting()

        XCTAssertNil(currentContext)
        XCTAssertEqual(snapshot.summary, "行为上下文已过期，等待新信号")
        XCTAssertTrue(snapshot.eventLines.contains { $0.contains("arrived_home 上下文已过期") })
    }

    // MARK: - Monitoring Task Tests

    func testStartMonitoring_createsPollingTask() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 2,
                requiredOfflineConfirmations: 2
            )
        )

        await service._setPresenceCheckOverrideForTesting { _ in false }

        await service.startMonitoring()

        let snapshot1 = await service.diagnosticsSnapshot()
        XCTAssertTrue(snapshot1.summary.contains("监控已启动") || snapshot1.summary.contains("行为监控"))

        await service.stopMonitoring()

        let snapshot2 = await service.diagnosticsSnapshot()
        XCTAssertEqual(snapshot2.summary, "行为监控已停止")
    }

    func testStopMonitoring_cancelsTask() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 2,
                requiredOfflineConfirmations: 2
            )
        )

        await service.startMonitoring()
        await service.stopMonitoring()

        let snapshot = await service.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.summary, "行为监控已停止")
    }

    func testSSHFailure_updatesDiagnostics() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "nonexistent-router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 1,
                requiredOfflineConfirmations: 1
            )
        )

        await service._setPresenceCheckOverrideForTesting { _ in false }
        await service._pollPresenceOnceForTesting()

        let snapshot = await service.diagnosticsSnapshot()
        XCTAssertNotNil(snapshot.signalSummary)
    }

    func testContextExpiration_clearsOldContext() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 1,
                requiredOfflineConfirmations: 1
            )
        )

        let now = Date()
        let expiredContext = BehaviorService.Context(
            scene: .arrivedHome,
            message: "飞哥回来了，和他打个招呼",
            source: "testing",
            detectedAt: now.addingTimeInterval(-700),
            expiresAt: now.addingTimeInterval(-100)
        )

        await service._setActiveContextForTesting(expiredContext)

        let contextBefore = await service._currentContextForTesting()
        XCTAssertNil(contextBefore)

        let snapshot = await service.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.summary, "行为上下文已过期，等待新信号")
    }

    func testMultiplePolls_maintainStability() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 3,
                requiredOfflineConfirmations: 2
            )
        )

        await service._setPresenceCheckOverrideForTesting { _ in true }
        await service._pollPresenceOnceForTesting()

        let snapshot1 = await service.diagnosticsSnapshot()
        XCTAssertTrue(snapshot1.summary.contains("等待") || snapshot1.summary.contains("确认"))

        await service._pollPresenceOnceForTesting()

        let snapshot2 = await service.diagnosticsSnapshot()
        XCTAssertTrue(snapshot2.summary.contains("等待") || snapshot2.summary.contains("确认") || snapshot2.summary.contains("在线"))

        await service._pollPresenceOnceForTesting()

        let contextAfterColdStart = await service._currentContextForTesting()
        XCTAssertNil(contextAfterColdStart)

        await service._setPresenceCheckOverrideForTesting { _ in false }
        await service._pollPresenceOnceForTesting()
        await service._pollPresenceOnceForTesting()

        await service._setPresenceCheckOverrideForTesting { _ in true }
        await service._pollPresenceOnceForTesting()
        await service._pollPresenceOnceForTesting()
        await service._pollPresenceOnceForTesting()

        let contextAfterReturnHome = await service._currentContextForTesting()
        XCTAssertNotNil(contextAfterReturnHome)
        XCTAssertEqual(contextAfterReturnHome?.scene, .arrivedHome)
    }

    func testDiagnosticsSnapshot_format() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 1,
                requiredOfflineConfirmations: 1
            )
        )

        await service._setDiagnosticsForTesting(
            summary: "test-summary",
            signalSummary: "test-signal-summary",
            eventLines: ["event1", "event2", "event3"]
        )

        let snapshot = await service.diagnosticsSnapshot()

        XCTAssertEqual(snapshot.summary, "test-summary")
        XCTAssertEqual(snapshot.signalSummary, "test-signal-summary")
        XCTAssertEqual(snapshot.eventLines.count, 3)
        XCTAssertEqual(snapshot.eventLines[0], "event1")
    }

    func testContextEventStream_yieldsContext() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                routerSSHHost: "router",
                monitoredPhoneMAC: "F6:85:C2:7F:1D:32",
                monitoredWiFiInterfaces: ["rax0"],
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 1,
                requiredOfflineConfirmations: 1
            )
        )

        await service._setLastKnownPhonePresenceForTesting(false)
        await service._setPresenceCheckOverrideForTesting { _ in true }
        await service._pollPresenceOnceForTesting()

        let stream = await service.contextEventStream()
        var iterator = stream.makeAsyncIterator()

        let context = await iterator.next()
        XCTAssertNotNil(context)
        XCTAssertEqual(context?.scene, .arrivedHome)
    }

    func testPresenceSignals_summaryText() {
        let signals1 = BehaviorService.PresenceSignals(routerReachable: true, associatedInterface: "rax0")
        XCTAssertEqual(signals1.summaryText, "ssh=ok, iface=rax0")
        XCTAssertTrue(signals1.isConfirmedPresent)

        let signals2 = BehaviorService.PresenceSignals(routerReachable: false, associatedInterface: nil)
        XCTAssertEqual(signals2.summaryText, "ssh=fail, iface=none")
        XCTAssertFalse(signals2.isConfirmedPresent)

        let signals3 = BehaviorService.PresenceSignals(routerReachable: true, associatedInterface: nil)
        XCTAssertFalse(signals3.isConfirmedPresent)
    }
}
