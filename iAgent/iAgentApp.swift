//
//  iAgentApp.swift - 完全按照 iAgent_bak 的方式实现
//
//  Created by David on 2026/4/6.
//

import AppKit
import Observation

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let controlCenter = AgentControlCenter.shared
    private let maxStatusLength = 10
    private var workspaceObservers: [NSObjectProtocol] = []
    private var diagnosticsRefreshTask: Task<Void, Never>?
    private var behaviorSummaryItem: NSMenuItem?
    private var behaviorSignalItem: NSMenuItem?
    private var behaviorEventItems: [NSMenuItem] = []
    var terminateHandler: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 先创建 UI，显示空心麦克风（服务未启动）
        setupStatusItem()
        setupMenu()
        updateIcon("mic")
        syncStatusTitle()
        
        // 2. 异步启动服务
        controlCenter.bootstrap()

        // 3. 监听系统唤醒与解锁事件，作为行为驱动的辅助信号
        observeWorkspaceEvents()
        startBehaviorDiagnosticsRefreshLoop()
        
        // 4. 绑定状态变化，直接驱动菜单栏 UI
        observeControlCenter()
    }

    private func startBehaviorDiagnosticsRefreshLoop() {
        diagnosticsRefreshTask?.cancel()
        diagnosticsRefreshTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshBehaviorDiagnosticsMenu()
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
        }
    }

    private func observeWorkspaceEvents() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.controlCenter.noteMacDidWake()
                    await self?.refreshBehaviorDiagnosticsMenu()
                }
            }
        )

        workspaceObservers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.controlCenter.noteSessionDidBecomeActive()
                    await self?.refreshBehaviorDiagnosticsMenu()
                }
            }
        )
    }

    private func observeControlCenter() {
        withObservationTracking { [weak self] in
            self?.renderControlCenterState()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeControlCenter()
            }
        }
    }

    private func renderControlCenterState() {
        if controlCenter.isPlaying {
            updateIcon("speaker.wave.2.fill")
        } else if controlCenter.isServiceRunning {
            updateIcon("mic.fill")
        } else {
            updateIcon("mic")
        }

        let statusText = controlCenter.compactStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewText = currentPreviewText(for: statusText)
        updateTitle(statusText: statusText, previewText: previewText)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = ""
            button.imagePosition = .imageLeft
        }
    }

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        // 版本信息
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            let versionItem = NSMenuItem(title: "版本 \(version) (Build \(build))", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)
        }
        menu.addItem(NSMenuItem.separator())
        let behaviorHeaderItem = NSMenuItem(title: "行为诊断", action: nil, keyEquivalent: "")
        behaviorHeaderItem.isEnabled = false
        menu.addItem(behaviorHeaderItem)

        let summaryItem = NSMenuItem(title: "状态: 读取中...", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        behaviorSummaryItem = summaryItem

        let signalItem = NSMenuItem(title: "信号: 读取中...", action: nil, keyEquivalent: "")
        signalItem.isEnabled = false
        menu.addItem(signalItem)
        behaviorSignalItem = signalItem

        behaviorEventItems = (0..<3).map { _ in
            let item = NSMenuItem(title: "事件: 暂无", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return item
        }

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // 菜单内容由后台刷新循环维护；这里不再依赖异步刷新结果。
    }

    private func updateIcon(_ name: String) {
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        statusItem?.button?.image?.isTemplate = true
        statusItem?.button?.imagePosition = .imageLeft
    }

    private func syncStatusTitle() {
        let status = controlCenter.compactStatusText.trimmingCharacters(in: .whitespacesAndNewlines)
        updateTitle(statusText: status, previewText: nil)
    }

    private func currentPreviewText(for statusText: String) -> String? {
        switch statusText {
        case "思考中":
            let userText = normalizedMenuBarText(controlCenter.latestConversation.user)
            return userText.isEmpty ? nil : userText
        case "播报中":
            let assistantText = normalizedMenuBarText(controlCenter.latestConversation.assistant)
            return assistantText.isEmpty ? nil : assistantText
        default:
            return nil
        }
    }

    private func updateTitle(statusText: String, previewText: String?) {
        guard let button = statusItem?.button else { return }
        let normalizedStatus = normalizedMenuBarText(statusText, maxLength: maxStatusLength)
        let text: String
        if let previewText {
            let normalizedPreview = normalizedMenuBarText(previewText)
            let combined = normalizedStatus.isEmpty
                ? normalizedPreview
                : "\(normalizedStatus)...\(normalizedPreview)"
            text = combined
        } else {
            text = normalizedStatus
        }
        button.title = text.isEmpty ? "" : " \(text)"
        button.imagePosition = .imageLeft
    }

    private func normalizedMenuBarText(_ rawText: String) -> String {
        rawText
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedMenuBarText(_ rawText: String, maxLength: Int) -> String {
        let compact = normalizedMenuBarText(rawText)

        guard compact.count > maxLength, maxLength > 1 else {
            return compact
        }

        return String(compact.prefix(maxLength - 1)) + "…"
    }

    private func refreshBehaviorDiagnosticsMenu() async {
        let snapshot = await controlCenter.behaviorDiagnosticsSnapshot()
        behaviorSummaryItem?.title = "状态: \(snapshot.summary)"
        behaviorSignalItem?.title = "信号: \(snapshot.signalSummary)"

        for (index, item) in behaviorEventItems.enumerated() {
            if index < snapshot.eventLines.count {
                item.title = snapshot.eventLines[index]
            } else {
                item.title = "事件: 暂无"
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        diagnosticsRefreshTask?.cancel()
        diagnosticsRefreshTask = nil
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    @objc private func quitApp() {
        performQuit(shouldTerminateApp: true)
    }

    private func performQuit(shouldTerminateApp: Bool) {
        let terminateHandler = self.terminateHandler
        Task { @MainActor [weak self, terminateHandler] in
            if let self {
                await self.controlCenter.stopService()
            } else {
                await AgentControlCenter.shared.stopService()
            }
            guard shouldTerminateApp else { return }
            if let terminateHandler {
                terminateHandler()
            } else {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

#if DEBUG
extension AppDelegate {
    func _setupStatusItemForTesting() {
        setupStatusItem()
    }

    func _setupMenuForTesting() {
        setupMenu()
    }

    func _updateIconForTesting(_ name: String) {
        updateIcon(name)
    }

    func _observeControlCenterForTesting() {
        observeControlCenter()
    }

    func _pollConversationForTesting() {
        renderControlCenterState()
    }

    func _showTextForTesting(_ text: String) {
        updateTitle(statusText: controlCenter.compactStatusText, previewText: text)
    }

    func _performQuitForTesting() {
        performQuit(shouldTerminateApp: false)
    }

    func _statusTitleForTesting() -> String {
        statusItem?.button?.title ?? ""
    }

    func _refreshBehaviorDiagnosticsMenuForTesting() async {
        await refreshBehaviorDiagnosticsMenu()
    }

    func _menuItemTitlesForTesting() -> [String] {
        statusItem?.menu?.items.map(\.title) ?? []
    }
}
#endif
