//
//  ContentView.swift
//  iAgent
//
//  Created by David on 2026/4/6.
//

import SwiftUI

struct MenuBarPanel: View {
    @Bindable var controlCenter: AgentControlCenter
    @State private var displayText = ""
    @State private var clearDisplayTask: Task<Void, Never>?
    var textDisplayDuration: TimeInterval = 5.0
    var quitHandler: (() -> Void)?
#if DEBUG
    private static var defaultQuitHandlerForTesting: (() -> Void)?
#endif

    init(
        controlCenter: AgentControlCenter,
        textDisplayDuration: TimeInterval = 5.0,
        quitHandler: (() -> Void)? = nil,
        initialDisplayText: String = ""
    ) {
        self.controlCenter = controlCenter
        self.textDisplayDuration = textDisplayDuration
        self.quitHandler = quitHandler
        self._displayText = State(initialValue: initialDisplayText)
    }

    var body: some View {
        VStack(spacing: 12) {
            Label(controlCenter.health.title, systemImage: controlCenter.menuBarSymbolName)

            if !displayText.isEmpty {
                Text(displayText)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
            }

            Divider()

            Button(controlCenter.isServiceRunning ? "停止服务" : "启动服务", action: toggleService)

            Button("停止播放", action: stopPlayback)
            .disabled(!controlCenter.isPlaying)

            Divider()

            Button("退出", action: quitApp)
        }
        .padding()
        .frame(width: 200)
        .onChange(of: controlCenter.latestConversation.user) { _, newValue in
            handleUserChange(newValue)
        }
        .onChange(of: controlCenter.latestConversation.assistant) { _, newValue in
            handleAssistantChange(newValue)
        }
        .onChange(of: controlCenter.isPlaying) { _, playing in
            handlePlayingChange(playing)
        }
    }

    private func quitApp() {
        if let quitHandler {
            quitHandler()
        } else {
#if DEBUG
            if let defaultQuitHandlerForTesting = Self.defaultQuitHandlerForTesting {
                defaultQuitHandlerForTesting()
                return
            }
#endif
            NSApplication.shared.terminate(nil)
        }
    }

    private func toggleService() {
        controlCenter.toggleService()
    }

    private func stopPlayback() {
        controlCenter.stopPlayback()
    }

    private func handleUserChange(_ newValue: String) {
        if !newValue.isEmpty {
            showText(newValue)
        }
    }

    private func handleAssistantChange(_ newValue: String) {
        if !newValue.isEmpty {
            showText(newValue)
        }
    }

    private func handlePlayingChange(_ playing: Bool) {
        if playing {
            showText("播报中...")
        }
    }

    private func showText(_ text: String) {
        clearDisplayTask?.cancel()
        displayText = text
        clearDisplayTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(textDisplayDuration))
            guard !Task.isCancelled else { return }
            displayText = ""
            clearDisplayTask = nil
        }
    }
}

#Preview {
    MenuBarPanel(controlCenter: AgentControlCenter())
}

#if DEBUG
extension MenuBarPanel {
    static func _setDefaultQuitHandlerForTesting(_ handler: (() -> Void)?) {
        defaultQuitHandlerForTesting = handler
    }

    func _quitAppForTesting() {
        quitApp()
    }

    func _toggleServiceForTesting() {
        toggleService()
    }

    func _stopPlaybackForTesting() {
        stopPlayback()
    }

    mutating func _handleUserChangeForTesting(_ newValue: String) {
        handleUserChange(newValue)
    }

    mutating func _handleAssistantChangeForTesting(_ newValue: String) {
        handleAssistantChange(newValue)
    }

    mutating func _handlePlayingChangeForTesting(_ playing: Bool) {
        handlePlayingChange(playing)
    }

    mutating func _showTextForTesting(_ text: String) {
        showText(text)
    }
}
#endif
