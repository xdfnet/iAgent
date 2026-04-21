//
//  AudioProcessor.swift
//  iAgent
//
//  音频处理工具函数，对应 Python 版本的 utils.py
//

import Foundation
import Darwin

/// 音频处理工具
struct AudioProcessor {

    /// 计算音频帧的 RMS（均方根）值
    /// - Parameter frame: 16-bit PCM 音频数据
    /// - Returns: RMS 值，用于 VAD 音量检测
    nonisolated static func calculateRMS(frame: Data) -> Int {
        guard !frame.isEmpty else { return 0 }

        var sumOfSquares: Float = 0
        let count = frame.count / MemoryLayout<Int16>.size
        frame.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            for i in 0..<count {
                let sample = base.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                let floatSample = Float(sample)
                sumOfSquares += floatSample * floatSample
            }
        }

        guard count > 0 else { return 0 }
        return Int(sqrt(sumOfSquares / Float(count)))
    }

    /// 将多个音频帧合并为一个 Data
    /// - Parameter frames: 音频帧数组
    /// - Returns: 合并后的音频数据
    nonisolated static func concatenateFrames(_ frames: [Data]) -> Data {
        var result = Data()
        for frame in frames {
            result.append(frame)
        }
        return result
    }

    /// 获取临时目录下的 iagent 文件夹路径
    nonisolated static var tempDirectory: URL {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("iagent")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// 生成临时音频文件路径
    /// - Parameters:
    ///   - prefix: 文件名前缀
    ///   - ext: 扩展名
    /// - Returns: 临时文件 URL
    nonisolated static func tempFileURL(prefix: String = "segment", ext: String = "wav") -> URL {
        let filename = "\(prefix)-\(UUID().uuidString).\(ext)"
        return tempDirectory.appendingPathComponent(filename)
    }
}

// MARK: - 可执行文件定位

struct ExecutableLocator {
    nonisolated static func find(_ name: String) -> String? {
        if name.contains("/") {
            return resolvedLaunchPath(for: name)
        }

        for candidate in searchDirectories().map({ ($0 as NSString).appendingPathComponent(name) }) {
            if let resolved = resolvedLaunchPath(for: candidate) {
                return resolved
            }
        }

        if let path = resolveViaShell(name, shell: "/bin/zsh") {
            return path
        }

        if let path = resolveViaShell(name, shell: "/bin/bash") {
            return path
        }

        return nil
    }

    nonisolated static func isAvailable(_ name: String) -> Bool {
        find(name) != nil
    }

    nonisolated static func runtimeEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = actualHomeDirectory()
        environment["PATH"] = searchDirectories().joined(separator: ":")
        return environment
    }

    nonisolated static func audioCaptureEnvironment() -> [String: String] {
        let home = actualHomeDirectory()
        var environment: [String: String] = [
            "HOME": home,
            "PATH": searchDirectories().joined(separator: ":"),
            "TMPDIR": ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory(),
            "USER": ProcessInfo.processInfo.environment["USER"] ?? NSUserName(),
            "LOGNAME": ProcessInfo.processInfo.environment["LOGNAME"] ?? NSUserName(),
            "SHELL": ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            "LANG": ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8"
        ]

        if let term = ProcessInfo.processInfo.environment["TERM"], !term.isEmpty {
            environment["TERM"] = term
        }

        return environment
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated static func resolvedLaunchPath(for path: String) -> String? {
        let resolvedURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return nil
        }
        return resolvedPath
    }

    nonisolated private static func searchDirectories() -> [String] {
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let home = actualHomeDirectory()
        let fallbackPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "\(home)/Library/Python/3.9/bin",
            "\(home)/Library/Python/3.10/bin",
            "\(home)/Library/Python/3.11/bin",
            "\(home)/Library/Python/3.12/bin"
        ]

        var seen = Set<String>()
        return (environmentPaths + fallbackPaths).filter { path in
            !path.isEmpty && seen.insert(path).inserted
        }
    }

    nonisolated private static func actualHomeDirectory() -> String {
        guard let passwd = getpwuid(getuid()), let home = passwd.pointee.pw_dir else {
            return NSHomeDirectory()
        }
        return String(cString: home)
    }

    nonisolated private static func resolveViaShell(_ executable: String, shell: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-lc", "command -v -- \(executable)"]
        task.environment = runtimeEnvironment()

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let output, !output.isEmpty, resolvedLaunchPath(for: output) != nil else {
            return nil
        }

        return resolvedLaunchPath(for: output)
    }
}

// MARK: - 音频格式辅助

enum AudioFormat: String {
    case wav = "wav"
    case mp3 = "mp3"
    case ogg = "ogg"
    case pcm = "s16le"

    /// 根据格式返回 MIME 类型
    var mimeType: String {
        switch self {
        case .wav: return "audio/wav"
        case .mp3: return "audio/mpeg"
        case .ogg: return "audio/ogg"
        case .pcm: return "audio/raw"
        }
    }

    /// 根据格式返回 FFmpeg 编码器
    var ffmpegCodec: String {
        switch self {
        case .wav: return "pcm_s16le"
        case .mp3: return "libmp3lame"
        case .ogg: return "libopus"
        case .pcm: return "copy"
        }
    }
}

#if DEBUG
extension ExecutableLocator {
    nonisolated static func _resolveViaShellForTesting(_ executable: String, shell: String) -> String? {
        resolveViaShell(executable, shell: shell)
    }
}
#endif
