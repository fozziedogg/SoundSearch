import CoreAudio
import Foundation

/// A single CoreAudio output device visible to the system.
struct AudioOutputDevice: Identifiable, Hashable {
    let deviceID: AudioDeviceID
    /// Stable string identifier — persists across reboots even if deviceID changes.
    let uid:  String
    let name: String

    var id: String { uid }
}

/// Utilities for enumerating and resolving CoreAudio output devices.
enum AudioDeviceManager {

    // MARK: - Device list

    /// All currently available CoreAudio devices that have at least one output channel.
    static func outputDevices() -> [AudioOutputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids.compactMap { id in
            guard hasOutputChannels(id) else { return nil }
            let name = deviceName(id)
            let uid  = deviceUID(id)
            guard !name.isEmpty, !uid.isEmpty else { return nil }
            return AudioOutputDevice(deviceID: id, uid: uid, name: name)
        }
    }

    // MARK: - Lookups

    /// Resolves a stable UID back to a runtime AudioDeviceID, or nil if the device is gone.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var cfUID    = uid as CFString
        var deviceID = AudioDeviceID(kAudioDeviceUnknown)
        var size     = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<CFString>.size), &cfUID,
            &size, &deviceID)
        guard err == noErr, deviceID != kAudioDeviceUnknown else { return nil }
        return deviceID
    }

    /// The current system-default output device, or nil on failure.
    static func systemDefaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioDeviceUnknown)
        var size     = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard err == noErr, deviceID != kAudioDeviceUnknown else { return nil }
        return deviceID
    }

    // MARK: - Private helpers

    private static func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope:    kAudioDevicePropertyScopeOutput,
            mElement:  kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size
        else { return false }

        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 4)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr) == noErr
        else { return false }

        let list = ptr.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var cf   = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cf) == noErr
        else { return "" }
        return cf as String
    }

    private static func deviceUID(_ deviceID: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope:    kAudioObjectPropertyScopeGlobal,
            mElement:  kAudioObjectPropertyElementMain
        )
        var cf   = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cf) == noErr
        else { return "" }
        return cf as String
    }
}
