//
//  ConversationMemory.swift
//  iAgent
//
//  最近对话历史，仅用于本地 UI 展示
//

import Foundation

/// 对话回合
struct Turn: Sendable {
    let userText: String
    let replyText: String
}

/// 最近对话历史
actor ConversationMemory {
    /// 最大保存回合数
    private let maxTurns: Int

    /// 对话回合记录
    private var turns: [Turn] = []

    init(maxTurns: Int = 12) {
        self.maxTurns = maxTurns
    }

    /// 添加对话回合
    /// - Parameters:
    ///   - userText: 用户文本
    ///   - replyText: 助手回复
    func addTurn(user: String, assistant: String) {
        let turn = Turn(userText: user, replyText: assistant)
        turns.append(turn)

        // 保持最大回合数限制
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }

    /// 获取所有回合
    func getTurns() -> [Turn] {
        return turns
    }

    /// 获取最近的回合
    func getLatestTurn() -> Turn? {
        return turns.last
    }

    /// 清空记忆
    func clear() {
        turns.removeAll()
    }
}
