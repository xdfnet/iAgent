//
//  AudioInputDeviceManager.swift
//  iAgent
//
//  管理 macOS 输入设备列表与默认输入切换
//

import CoreAudio
import Foundation

enum AudioInputDeviceManager {
    struct InputDevice: Sendable, Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let isDefault: Bool
    }

    enum DeviceError: LocalizedError {
        case propertyQueryFailed(String)
        case deviceNotFound(String)
        case updateDefaultFailed

        var errorDescription: String? {
            switch self {
            case .propertyQueryFailed(let property):
                return "读取音频设备属性失败: \(property)"
            case .deviceNotFound(let uid):
                return "未找到指定麦克风: \(uid)"
            case .updateDefaultFailed:
                return "切换默认麦克风失败"
            }
        }
    }

    static func inputDevices() throws -> [InputDevice] {
        let defaultDeviceID = try defaultInputDeviceID()
        let devices = try allDeviceIDs()

        return try devices.compactMap { deviceID in
            guard try hasInputChannels(deviceID) else { return nil }
            let uid = try stringProperty(
                deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            )
            let name = try stringProperty(
                deviceID,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal
            )
            guard shouldDisplayInputDevice(name: name, uid: uid) else { return nil }
            return InputDevice(
                id: deviceID,
                uid: uid,
                name: name,
                isDefault: deviceID == defaultDeviceID
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func setDefaultInputDevice(uid: String) throws {
        guard let target = try inputDevices().first(where: { $0.uid == uid }) else {
            throw DeviceError.deviceNotFound(uid)
        }

        var deviceID = target.id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )
        guard status == noErr else {
            throw DeviceError.updateDefaultFailed
        }
    }

    static func defaultInputDeviceUID() throws -> String? {
        let defaultID = try defaultInputDeviceID()
        guard defaultID != 0 else { return nil }
        return try stringProperty(
            defaultID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw DeviceError.propertyQueryFailed("kAudioHardwarePropertyDevices.size")
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else {
            throw DeviceError.propertyQueryFailed("kAudioHardwarePropertyDevices")
        }
        return deviceIDs
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr else {
            throw DeviceError.propertyQueryFailed("kAudioHardwarePropertyDefaultInputDevice")
        }
        return deviceID
    }

    private static func hasInputChannels(_ deviceID: AudioDeviceID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw DeviceError.propertyQueryFailed("kAudioDevicePropertyStreamConfiguration.size")
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer)
        guard status == noErr else {
            throw DeviceError.propertyQueryFailed("kAudioDevicePropertyStreamConfiguration")
        }

        let bufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let audioBuffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let channelCount = audioBuffers.reduce(0) { partialResult, buffer in
            partialResult + Int(buffer.mNumberChannels)
        }
        return channelCount > 0
    }

    private static func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfValue: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfValue) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        guard status == noErr else {
            throw DeviceError.propertyQueryFailed("selector=\(selector)")
        }
        return (cfValue ?? "" as CFString) as String
    }

    private static func shouldDisplayInputDevice(name: String, uid: String) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !normalizedName.isEmpty, !normalizedUID.isEmpty else { return false }

        let hiddenMarkers = [
            "aggregate",
            "cadefaultdeviceaggregate",
            "defaultdeviceaggregate"
        ]

        return !hiddenMarkers.contains { marker in
            normalizedName.contains(marker) || normalizedUID.contains(marker)
        }
    }
}
