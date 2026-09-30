import Foundation
import CoreAudio

/// CoreAudio-backed control for the default input device.
/// Handles Aggregate Devices by dispatching mute/volume to their input sub-devices,
/// since AppleScript `set volume input volume` is a no-op on most aggregates.
enum AudioInputController {

    // MARK: - Public API

    static func setMuted(_ muted: Bool) {
        guard let deviceID = defaultInputDeviceID() else { return }
        applyMute(deviceID: deviceID, muted: muted)
    }

    static func isMuted() -> Bool? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return readMute(deviceID: deviceID)
    }

    /// `volume` is 0.0 ... 1.0
    static func setVolume(_ volume: Float32) {
        guard let deviceID = defaultInputDeviceID() else { return }
        applyVolume(deviceID: deviceID, volume: volume)
    }

    /// Returns 0.0 ... 1.0, or nil if no readable volume property is present.
    static func volume() -> Float32? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return readVolume(deviceID: deviceID)
    }

    /// The default input device's display name (e.g. "MacBook Pro Microphone",
    /// "Jabra Elite 7 Pro"), or nil if it can't be read.
    static func deviceName() -> String? {
        guard let deviceID = defaultInputDeviceID() else { return nil }
        return readDeviceName(deviceID: deviceID)
    }

    // MARK: - Change listeners

    private static var onDevicesChanged: (() -> Void)?
    private static var onStateChanged: (() -> Void)?
    private static var watchedDeviceIDs: [AudioDeviceID] = []

    // Stored once so the identical block can be passed to the remove call.
    private static let devicesListener: AudioObjectPropertyListenerBlock = { _, _ in
        refreshWatchedDevices()
        onDevicesChanged?()
    }
    private static var stateSyncScheduled = false
    // One write notifies once per channel and sub-device; one sync covers the burst.
    private static let stateListener: AudioObjectPropertyListenerBlock = { _, _ in
        guard !stateSyncScheduled else { return }
        stateSyncScheduled = true
        DispatchQueue.main.async {
            stateSyncScheduled = false
            onStateChanged?()
        }
    }

    private static let systemAddresses = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDevices,
    ].map { AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain) }

    private static let stateAddresses = [
        kAudioDevicePropertyMute,
        kAudioDevicePropertyVolumeScalar,
    ].map { AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementWildcard) }

    /// Calls `devicesChanged` when the default input may have changed
    /// (switched, device plugged in or removed) and `stateChanged` when mute
    /// or input volume of the default input changes, e.g. from a headset's hardware mute button. Both run on main.
    static func startMonitoring(devicesChanged: @escaping () -> Void, stateChanged: @escaping () -> Void) {
        onDevicesChanged = devicesChanged
        onStateChanged = stateChanged
        for var address in systemAddresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, devicesListener)
        }
        refreshWatchedDevices()
    }

    /// Moves the state listeners to the current default input device.
    private static func refreshWatchedDevices() {
        for deviceID in watchedDeviceIDs {
            for var address in stateAddresses {
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, stateListener)
            }
        }
        watchedDeviceIDs = defaultInputDeviceID().map(expandedTargets) ?? []
        for deviceID in watchedDeviceIDs {
            for var address in stateAddresses {
                AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, stateListener)
            }
        }
    }

    // MARK: - Device lookup

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// The devices that actually carry mute/volume: the input sub-devices of
    /// an aggregate, or the device itself.
    private static func expandedTargets(_ deviceID: AudioDeviceID) -> [AudioDeviceID] {
        let subs = subDeviceIDs(of: deviceID)
        return subs.isEmpty ? [deviceID] : subs.filter(hasInputStream)
    }

    private static func subDeviceIDs(of aggregate: AudioDeviceID) -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(aggregate, &address) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregate, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func hasInputStream(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        var total: UInt32 = 0
        for buffer in abl { total += buffer.mNumberChannels }
        return total
    }

    // MARK: - Mute

    private static func applyMute(deviceID: AudioDeviceID, muted: Bool) {
        let targets = expandedTargets(deviceID)
        for target in targets {
            if !setMuteProperty(target, muted: muted) {
                // Fallback when the device exposes no writable mute: drive volume to 0/1.
                _ = setVolumeProperty(target, volume: muted ? 0 : 1)
            }
        }
    }

    private static func setMuteProperty(_ deviceID: AudioDeviceID, muted: Bool) -> Bool {
        if writeMute(deviceID, channel: kAudioObjectPropertyElementMain, muted: muted) {
            return true
        }
        let channels = inputChannelCount(deviceID)
        guard channels > 0 else { return false }
        var anyOK = false
        for ch in 1...channels {
            if writeMute(deviceID, channel: ch, muted: muted) { anyOK = true }
        }
        return anyOK
    }

    private static func writeMute(_ deviceID: AudioDeviceID, channel: UInt32, muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: channel
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }

    private static func readMute(deviceID: AudioDeviceID) -> Bool? {
        let targets = expandedTargets(deviceID)

        var mutePropertyResult: Bool?
        for target in targets {
            if let m = readMuteOnDevice(target) {
                mutePropertyResult = m
                break
            }
        }

        if mutePropertyResult == true {
            return true
        }

        // Some devices (many USB/Bluetooth headsets, e.g. Jabra) implement
        // their hardware mute button by zeroing the input gain rather than
        // flipping CoreAudio's mute property. A genuine hardware mute press
        // can therefore leave the mute property reporting a definite
        // false — not absent — so the fallback below has to run even when
        // mutePropertyResult is a known false, not just when it's nil.
        for target in targets {
            if let v = readVolumeOnDevice(target), v < 0.05 {
                return true
            }
        }

        return mutePropertyResult
    }

    private static func readMuteOnDevice(_ deviceID: AudioDeviceID) -> Bool? {
        if let v = queryMute(deviceID, channel: kAudioObjectPropertyElementMain) { return v }
        let channels = inputChannelCount(deviceID)
        guard channels > 0 else { return nil }
        for ch in 1...channels {
            if let v = queryMute(deviceID, channel: ch) { return v }
        }
        return nil
    }

    private static func queryMute(_ deviceID: AudioDeviceID, channel: UInt32) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: channel
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    // MARK: - Volume

    private static func applyVolume(deviceID: AudioDeviceID, volume: Float32) {
        let clamped = max(0, min(1, volume))
        let targets = expandedTargets(deviceID)
        for target in targets {
            _ = setVolumeProperty(target, volume: clamped)
        }
    }

    private static func setVolumeProperty(_ deviceID: AudioDeviceID, volume: Float32) -> Bool {
        if writeVolume(deviceID, channel: kAudioObjectPropertyElementMain, volume: volume) {
            return true
        }
        let channels = inputChannelCount(deviceID)
        guard channels > 0 else { return false }
        var anyOK = false
        for ch in 1...channels {
            if writeVolume(deviceID, channel: ch, volume: volume) { anyOK = true }
        }
        return anyOK
    }

    private static func writeVolume(_ deviceID: AudioDeviceID, channel: UInt32, volume: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: channel
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
    }

    private static func readVolume(deviceID: AudioDeviceID) -> Float32? {
        let targets = expandedTargets(deviceID)
        for target in targets {
            if let v = readVolumeOnDevice(target) { return v }
        }
        return nil
    }

    private static func readVolumeOnDevice(_ deviceID: AudioDeviceID) -> Float32? {
        if let v = queryVolume(deviceID, channel: kAudioObjectPropertyElementMain) { return v }
        let channels = inputChannelCount(deviceID)
        guard channels > 0 else { return nil }
        for ch in 1...channels {
            if let v = queryVolume(deviceID, channel: ch) { return v }
        }
        return nil
    }

    private static func queryVolume(_ deviceID: AudioDeviceID, channel: UInt32) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: channel
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    // MARK: - Device name

    private static func readDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        // kAudioObjectPropertyName hands back an already-retained CFStringRef.
        // A plain `var name: CFString` target doesn't reliably line up with
        // what CoreAudio writes into that memory (Swift's CFString bridging
        // isn't guaranteed to match a raw pointer-sized C write) — Unmanaged
        // is the correct, documented way to receive CF "Get" properties.
        var unmanagedName: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanagedName)
        guard status == noErr, let unmanagedName = unmanagedName else { return nil }
        return unmanagedName.takeRetainedValue() as String
    }
}
