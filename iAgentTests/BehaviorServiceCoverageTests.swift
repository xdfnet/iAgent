import XCTest
@testable import iAgent

final class BehaviorServiceCoverageTests: XCTestCase {
    func testInitialPresenceDoesNotImmediatelyCreateArrivedHomeContext() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                monitoredPhoneIP: "192.168.100.243",
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 2,
                requiredOfflineConfirmations: 2,
                activitySignalWindowSeconds: 300
            )
        )

        await service._setPresenceCheckOverrideForTesting { _ in true }
        await service._pollPresenceOnceForTesting()

        let context = await service._currentContextForTesting()
        XCTAssertNil(context)
    }

    func testOfflineToOnlineTransitionRequiresWakeAndUnlockBeforeCreatingContext() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                monitoredPhoneIP: "192.168.100.243",
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 2,
                requiredOfflineConfirmations: 2,
                activitySignalWindowSeconds: 300
            )
        )

        await service._setLastKnownPhonePresenceForTesting(false)
        await service._setPresenceCheckOverrideForTesting { _ in true }
        await service._pollPresenceOnceForTesting()
        let firstContext = await service._currentContextForTesting()
        XCTAssertNil(firstContext)

        await service._pollPresenceOnceForTesting()
        let secondContext = await service._currentContextForTesting()
        XCTAssertNil(secondContext)

        await service.noteMacDidWake()
        let afterWakeContext = await service._currentContextForTesting()
        XCTAssertNil(afterWakeContext)

        await service.noteSessionDidBecomeActive()
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
                monitoredPhoneIP: "192.168.100.243",
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 2,
                requiredOfflineConfirmations: 2,
                activitySignalWindowSeconds: 300
            )
        )

        let now = Date()
        await service._setLastKnownPhonePresenceForTesting(true)
        await service._setLastMacWakeAtForTesting(now)
        await service._setLastSessionActivationAtForTesting(now)
        await service._setLastArrivalDetectedAtForTesting(now)
        await service.noteSessionDidBecomeActive()

        let context = await service._currentContextForTesting()
        XCTAssertNil(context)
    }

    func testSinglePositiveBounceDoesNotTriggerArrivedHomeContext() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                monitoredPhoneIP: "192.168.100.243",
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 2,
                requiredOfflineConfirmations: 2,
                activitySignalWindowSeconds: 300
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

    func testWakeAndUnlockOutsideSignalWindowDoNotTriggerContext() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                monitoredPhoneIP: "192.168.100.243",
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 1,
                requiredOfflineConfirmations: 1,
                activitySignalWindowSeconds: 10
            )
        )

        let staleTime = Date(timeIntervalSinceNow: -30)
        await service._setLastKnownPhonePresenceForTesting(true)
        await service._setLastMacWakeAtForTesting(staleTime)
        await service._setLastSessionActivationAtForTesting(staleTime)
        await service.noteSessionDidBecomeActive()

        let context = await service._currentContextForTesting()
        XCTAssertNil(context)
    }

    func testARPOutputRecognizesResolvedNeighbor() {
        let output = "? (192.168.100.243) at 1c:xx:xx:xx:xx:xx on en0 ifscope [ethernet]"
        XCTAssertTrue(BehaviorService._arpOutputIndicatesResolvedNeighborForTesting(output))
    }

    func testARPOutputRejectsIncompleteNeighbor() {
        let output = "? (192.168.100.243) at (incomplete) on en0 ifscope [ethernet]"
        XCTAssertFalse(BehaviorService._arpOutputIndicatesResolvedNeighborForTesting(output))
    }

    func testExpiredContextDowngradesDiagnosticsSummary() async {
        let service = BehaviorService(
            config: .init(
                enabled: true,
                monitoredPhoneIP: "192.168.100.243",
                pollIntervalSeconds: 60,
                contextTTLSeconds: 600,
                cooldownSeconds: 1800,
                requiredOnlineConfirmations: 1,
                requiredOfflineConfirmations: 1,
                activitySignalWindowSeconds: 300
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
