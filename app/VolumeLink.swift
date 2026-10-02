import CoreAudio
import Foundation

/// Keeps a single volume for the listener. The system volume, which macOS applies to the OpenSpatial device,
/// drives the headphones' own volume; changing the headphones' volume moves the system volume to match.
/// The driver reports volume and mute without applying them, so mute and headphones without a volume
/// control of their own are handled by `applyGain` inside the app.
@MainActor
final class VolumeLink {
    /// Sets a linear gain on the app's output.
    var applyGain: (Float) -> Void = { _ in }

    private var driver: AudioObjectID = 0
    private var headphones: AudioObjectID = 0
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    /// Links the system volume on `driver` to the volume of `headphones`; does nothing when the pair is unchanged.
    func connect(driver: AudioObjectID, headphones: AudioObjectID) {
        guard driver != self.driver || headphones != self.headphones else { return }
        disconnect()
        self.driver = driver
        self.headphones = headphones
        guard driver != 0, headphones != 0 else {
            applyGain(1)
            return
        }
        // Start from the headphones' volume so the loudness doesn't jump.
        if let volume = Self.volume(of: headphones) {
            Self.setVolume(volume, of: driver)
        }
        driverChanged()
        for element in Self.volumeElements(of: driver) {
            listen(driver, kAudioDevicePropertyVolumeScalar, element) { $0.driverChanged() }
        }
        listen(driver, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain) { $0.driverChanged() }
        for element in Self.volumeElements(of: headphones) {
            listen(headphones, kAudioDevicePropertyVolumeScalar, element) { $0.headphonesChanged() }
        }
    }

    private func disconnect() {
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
        }
        listeners = []
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement, _ changed: @escaping (VolumeLink) -> Void) {
        var address = Self.address(selector, element)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                if let self { changed(self) }
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func driverChanged() {
        let volume = Self.volume(of: driver) ?? 1
        let muted = Self.isMuted(driver)
        if Self.canSetVolume(of: headphones) {
            if abs((Self.volume(of: headphones) ?? -1) - volume) > 0.001 {
                Self.setVolume(volume, of: headphones)
            }
            applyGain(muted ? 0 : 1)
        } else {
            applyGain(muted ? 0 : Self.gain(of: driver) ?? volume)
        }
    }

    private func headphonesChanged() {
        guard let volume = Self.volume(of: headphones), abs((Self.volume(of: driver) ?? -1) - volume) > 0.001 else { return }
        Self.setVolume(volume, of: driver)
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    /// Where a device keeps its output volume: one main control, or one per channel.
    private static func volumeElements(of device: AudioObjectID) -> [AudioObjectPropertyElement] {
        var main = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &main) { return [kAudioObjectPropertyElementMain] }
        return (1...16).filter { element in
            var channel = address(kAudioDevicePropertyVolumeScalar, AudioObjectPropertyElement(element))
            return AudioObjectHasProperty(device, &channel)
        }.map { AudioObjectPropertyElement($0) }
    }

    /// The volume scalar, 0 to 1; for per-channel controls, the first channel's.
    private static func volume(of device: AudioObjectID) -> Float32? {
        guard let element = volumeElements(of: device).first else { return nil }
        return read(device, kAudioDevicePropertyVolumeScalar, element, as: Float32.self)
    }

    private static func canSetVolume(of device: AudioObjectID) -> Bool {
        volumeElements(of: device).contains { element in
            var target = address(kAudioDevicePropertyVolumeScalar, element)
            var settable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(device, &target, &settable) == noErr && settable.boolValue
        }
    }

    private static func setVolume(_ volume: Float32, of device: AudioObjectID) {
        for element in volumeElements(of: device) {
            var target = address(kAudioDevicePropertyVolumeScalar, element)
            var value = volume
            AudioObjectSetPropertyData(device, &target, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool {
        read(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain, as: UInt32.self) ?? 0 != 0
    }

    /// The volume as a linear gain, from the device's decibel value.
    private static func gain(of device: AudioObjectID) -> Float? {
        guard let element = volumeElements(of: device).first,
              let decibels = read(device, kAudioDevicePropertyVolumeDecibels, element, as: Float32.self)
        else { return nil }
        return pow(10, decibels / 20)
    }

    private static func read<T: BitwiseCopyable>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement, as type: T.Type) -> T? {
        var target = address(selector, element)
        guard AudioObjectHasProperty(device, &target) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &target, 0, nil, &size, raw) == noErr else { return nil }
        return raw.load(as: type)
    }
}
