import XCTest
import AppKit
import SwiftUI
@testable import iAgent

@MainActor
final class AppDelegateAndViewCoverageTests: XCTestCase {
    private func sleep(milliseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    override func setUp() async throws {
        try await super.setUp()
        await resetSharedControlCenter()
    }

    override func tearDown() async throws {
        await resetSharedControlCenter()
        try await super.tearDown()
    }

    private func resetSharedControlCenter() async {
        let center = AgentControlCenter.shared
        await center.stopService()
        center._setTestHooksForTesting(nil)
        center._setRequiredAgentExecutableNameOverrideForTesting(nil)
        center._setVoiceRecoveryAttemptHookForTesting(nil)
        center.latestConversation = .empty
        center.statusMessage = "等待启动"
        center.health = .stopped
        center.isPlaying = false
        center.autoSpeak = true
        center.lastRefresh = nil
    }

    func testAppDelegatePollingUsesStateDrivenPreviewText() {
        let delegate = AppDelegate()
        delegate._setupStatusItemForTesting()
        delegate._setupMenuForTesting()
        delegate._updateIconForTesting("mic")
        AgentControlCenter.shared.health = .healthy
        AgentControlCenter.shared.isPlaying = false
        AgentControlCenter.shared.statusMessage = "Agent处理中..."

        AgentControlCenter.shared.latestConversation = AgentConversation(user: "你好", assistant: "")
        delegate._pollConversationForTesting()
        XCTAssertEqual(delegate._statusTitleForTesting(), " 思考中...你好")

        AgentControlCenter.shared.statusMessage = "播报中"
        AgentControlCenter.shared.latestConversation = AgentConversation(user: "你好", assistant: "收到")
        delegate._pollConversationForTesting()
        XCTAssertEqual(delegate._statusTitleForTesting(), " 播报中...收到")

        AgentControlCenter.shared.statusMessage = "正在监听..."
        AgentControlCenter.shared.isPlaying = false
        delegate._pollConversationForTesting()
        XCTAssertEqual(delegate._statusTitleForTesting(), " 监听中")
    }

    func testAppDelegateObservationAndQuitSelector() async {
        let delegate = AppDelegate()
        delegate.terminateHandler = {}
        delegate._setupStatusItemForTesting()
        delegate._setupMenuForTesting()

        AgentControlCenter.shared.health = .healthy
        AgentControlCenter.shared.isPlaying = true
        delegate._observeControlCenterForTesting()
        await sleep(milliseconds: 30)

        AgentControlCenter.shared.isPlaying = false
        AgentControlCenter.shared.statusMessage = "正在监听..."
        delegate._pollConversationForTesting()
        XCTAssertEqual(delegate._statusTitleForTesting(), " 监听中")

        _ = delegate.perform(NSSelectorFromString("quitApp"))
        delegate.applicationWillTerminate(Notification(name: Notification.Name("unit-test-will-terminate")))
    }

    func testApplicationDidFinishLaunchingPath() async {
        let delegate = AppDelegate()
        delegate.terminateHandler = {}
        delegate.applicationDidFinishLaunching(Notification(name: Notification.Name("unit-test-did-finish")))
        await sleep(milliseconds: 120)
        delegate._performQuitForTesting()
        delegate.applicationWillTerminate(Notification(name: Notification.Name("unit-test-done")))
    }

    func testPerformQuitStopsServiceAsynchronously() async {
        let delegate = AppDelegate()
        AgentControlCenter.shared.health = .healthy
        delegate._performQuitForTesting()
        await sleep(milliseconds: 120)
        XCTAssertEqual(AgentControlCenter.shared.health, .stopped)
    }

    func testMenuBarPanelBodyBuilds() {
        let view = MenuBarPanel(controlCenter: AgentControlCenter())
        _ = view.body
    }

    func testMenuBarPanelActionMethodsAndQuitHandler() async {
        let center = AgentControlCenter()
        var quitCalled = false
        let view = MenuBarPanel(controlCenter: center, textDisplayDuration: 0.05, quitHandler: {
            quitCalled = true
        })

        view._toggleServiceForTesting()
        view._stopPlaybackForTesting()
        view._quitAppForTesting()
        await sleep(milliseconds: 80)

        XCTAssertTrue(quitCalled)
    }

    func testMenuBarPanelDefaultQuitPathWithTestingHook() {
        var defaultQuitCalled = false
        MenuBarPanel._setDefaultQuitHandlerForTesting {
            defaultQuitCalled = true
        }
        defer {
            MenuBarPanel._setDefaultQuitHandlerForTesting(nil)
        }

        let view = MenuBarPanel(controlCenter: AgentControlCenter())
        view._quitAppForTesting()
        XCTAssertTrue(defaultQuitCalled)
    }

    func testMenuBarPanelBodyBuildsWithInitialDisplayText() {
        let view = MenuBarPanel(controlCenter: AgentControlCenter(), initialDisplayText: "预览文本")
        _ = view.body
    }

    func testMenuBarPanelHandlersAndShowText() async {
        var view = MenuBarPanel(controlCenter: AgentControlCenter(), textDisplayDuration: 0.05)
        view._handleUserChangeForTesting("用户文本")
        view._handleAssistantChangeForTesting("助手文本")
        view._handlePlayingChangeForTesting(true)
        view._showTextForTesting("临时文本")
        _ = view.body
        await sleep(milliseconds: 80)
    }

    func testAppDelegateAdditionalTestingHooks() async {
        let delegate = AppDelegate()
        delegate._setupStatusItemForTesting()
        delegate._setupMenuForTesting()
        delegate._showTextForTesting("hook-text")
        delegate._observeControlCenterForTesting()
        await sleep(milliseconds: 120)
        delegate.applicationWillTerminate(Notification(name: Notification.Name("unit-test-hooks-end")))
    }

    func testMenuBarPreviewTextIsNormalizedAndTruncated() {
        let delegate = AppDelegate()
        delegate._setupStatusItemForTesting()
        AgentControlCenter.shared.health = .healthy
        AgentControlCenter.shared.statusMessage = "Agent处理中..."

        AgentControlCenter.shared.latestConversation = AgentConversation(
            user: "第一行\n第二行 第三行 第四行 第五行",
            assistant: ""
        )

        delegate._pollConversationForTesting()
        XCTAssertEqual(delegate._statusTitleForTesting(), " 思考中...第一行 第二行 第三行 第四行 第五行")
    }

    func testStatusFallbackTextIsTruncated() {
        let delegate = AppDelegate()
        delegate._setupStatusItemForTesting()

        AgentControlCenter.shared.health = .healthy
        AgentControlCenter.shared.statusMessage = "这是一个非常非常长的状态消息"

        delegate._pollConversationForTesting()
        XCTAssertEqual(delegate._statusTitleForTesting(), " 这是一个非常非常长…")
    }

    func testPreviewTextTracksLatestStatusWhilePhaseChanges() {
        let delegate = AppDelegate()
        delegate._setupStatusItemForTesting()

        AgentControlCenter.shared.health = .healthy
        AgentControlCenter.shared.statusMessage = "Agent处理中..."
        AgentControlCenter.shared.latestConversation = AgentConversation(user: "豆包你在吗", assistant: "")
        delegate._pollConversationForTesting()
        XCTAssertEqual(delegate._statusTitleForTesting(), " 思考中...豆包你在吗")

        AgentControlCenter.shared.latestConversation = AgentConversation(user: "豆包你在吗", assistant: "我在")
        AgentControlCenter.shared.statusMessage = "播报中"
        delegate._pollConversationForTesting()
        XCTAssertEqual(delegate._statusTitleForTesting(), " 播报中...我在")
    }

    func testStatusTitleFallbackWhenStatusItemNotSetup() {
        let delegate = AppDelegate()
        XCTAssertEqual(delegate._statusTitleForTesting(), "")
    }

    func testBehaviorDiagnosticsMenuRefreshShowsSnapshot() async {
        let delegate = AppDelegate()
        delegate._setupStatusItemForTesting()
        delegate._setupMenuForTesting()

        await AgentControlCenter.shared._setBehaviorDiagnosticsForTesting(
            summary: "手机在线已确认，等待最近一次 Mac 唤醒",
            signalSummary: "手机在线探测：ping=ok, arp=ok",
            eventLines: [
                "12:00:00 收到系统唤醒事件",
                "12:00:03 收到会话激活/解锁事件"
            ]
        )

        await delegate._refreshBehaviorDiagnosticsMenuForTesting()
        let titles = delegate._menuItemTitlesForTesting()

        XCTAssertTrue(titles.contains("状态: 手机在线已确认，等待最近一次 Mac 唤醒"))
        XCTAssertTrue(titles.contains("信号: 手机在线探测：ping=ok, arp=ok"))
        XCTAssertTrue(titles.contains("12:00:00 收到系统唤醒事件"))
        XCTAssertTrue(titles.contains("12:00:03 收到会话激活/解锁事件"))
    }
}
