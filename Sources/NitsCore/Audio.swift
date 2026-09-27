import Foundation
import CoreAudio
import AudioToolbox

/// Volume control for output devices via the public CoreAudio HAL.
///
/// Monitor speakers fed over DisplayPort/HDMI enumerate as real output devices, so
/// where they expose a settable volume this path is far better than DDC VCP 0x62:
/// it is public API, instant, and reports accurate state.
///
/// The catch, and the reason `hasSettableVolume` exists: plenty of monitor audio
/// devices expose NO volume control at all, leaving level entirely to the panel. For
/// those, the caller must fall back to DDC. Which case this Samsung falls into is
/// exactly what `nitsprobe` is for.
public struct AudioDevice: Sendable, Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String?
    public let transport: String
    public let hasSettableVolume: Bool
    public let hasMute: Bool
    public let isDefaultOutput: Bool
}

public enum AudioControl {

    // MARK: - Enumeration

    public static func outputDevices() -> [AudioDevice] {
        let defaultID = defaultOutputDeviceID()
        return allDeviceIDs().compactMap { id in
            guard outputChannelCount(id) > 0 else { return nil }
            return AudioDevice(
                id: id,
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Unknown",
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID),
                transport: transportName(id),
                hasSettableVolume: hasSettableVolume(id),
                hasMute: hasProperty(id, kAudioDevicePropertyMute),
                isDefaultOutput: id == defaultID)
        }
    }

    public static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    // MARK: - Volume

    /// Preferred selector: the HAL's virtual main volume, which maps to whatever
    /// channel layout the device actually has.
    private static let virtualMainVolume: AudioObjectPropertySelector =
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume

    public static func volume(_ id: AudioDeviceID) -> Float? {
        if let value = floatProperty(id, virtualMainVolume) { return value }
        // Fall back to per-channel scalars for devices without a main element.
        let channels = [UInt32(1), UInt32(2)].compactMap {
            floatProperty(id, kAudioDevicePropertyVolumeScalar, element: $0)
        }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float(channels.count)
    }

    @discardableResult
    public static func setVolume(_ id: AudioDeviceID, _ value: Float) -> Bool {
        let clamped = max(0, min(1, value))
        if setFloatProperty(id, virtualMainVolume, clamped) { return true }
        var anySucceeded = false
        for channel in [UInt32(1), UInt32(2)] {
            if setFloatProperty(id, kAudioDevicePropertyVolumeScalar, clamped, element: channel) {
                anySucceeded = true
            }
        }
        return anySucceeded
    }

    public static func isMuted(_ id: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    @discardableResult
    public static func setMuted(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(id, &address, 0, nil, size, &value) == noErr
    }

    public static func hasSettableVolume(_ id: AudioDeviceID) -> Bool {
        if isSettable(id, virtualMainVolume) { return true }
        return [UInt32(1), UInt32(2)].contains {
            isSettable(id, kAudioDevicePropertyVolumeScalar, element: $0)
        }
    }

    // MARK: - Property plumbing

    private static func outputAddress(
        _ selector: AudioObjectPropertySelector, element: UInt32 = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private static func isSettable(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        element: UInt32 = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = outputAddress(selector, element: element)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    private static func hasProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = outputAddress(selector)
        return AudioObjectHasProperty(id, &address)
    }

    private static func floatProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector,
        element: UInt32 = kAudioObjectPropertyElementMain
    ) -> Float? {
        var address = outputAddress(selector, element: element)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func setFloatProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: Float,
        element: UInt32 = kAudioObjectPropertyElementMain
    ) -> Bool {
        guard isSettable(id, selector, element: element) else { return false }
        var address = outputAddress(selector, element: element)
        var value = value
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(id, &address, 0, nil, size, &value) == noErr
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value as String?
    }

    private static func outputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func transportName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else {
            return "unknown"
        }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        default: return "other"
        }
    }
}
