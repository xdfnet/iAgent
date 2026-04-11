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
}
