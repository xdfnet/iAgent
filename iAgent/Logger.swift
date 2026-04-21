//
//  Logger.swift
//  iAgent
//
//  统一日志工具，提供结构化日志输出。
//

import Foundation

enum LogCategory: String {
    case voice
    case asr
    case agent
    case tts
    case playback
    case behavior
    case config
    case control
    case app
}

enum Logger {
    nonisolated static func log(_ message: String, category: LogCategory, level: LogLevel = .info) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        switch level {
        case .debug:
            print("[\(timestamp)] [\(category.rawValue)] \(message)")
        case .info:
            print("[\(timestamp)] [\(category.rawValue)] \(message)")
        case .warning:
            print("[\(timestamp)] [WARNING] [\(category.rawValue)] \(message)")
        case .error:
            print("[\(timestamp)] [ERROR] [\(category.rawValue)] \(message)")
        }
    }

    enum LogLevel {
        case debug
        case info
        case warning
        case error
    }
}
