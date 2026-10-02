import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os
import Synchronization

struct CaptureError: LocalizedError {
    let errorDescription: String?
}

/// An audio device as Core Audio reports it.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    /// Stays the same across launches and reconnections, unlike `id`.
    let uid: String

    /// The UID of the OpenSpatial driver's device: the driver's name followed by "_UID", set in driver/build.sh.
    static let driverUID = "OpenSpatial_UID"
    let name: String
    let inputChannels: Int
    let outputChannels: Int

    /// Devices that carry sound themselves. Aggregate devices are left out: they only combine other
    /// devices, and Core Audio creates private ones inside this process that appear only to it.
    static func all() -> [AudioDevice] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { !isAggregate($0) }.map { id in
            AudioDevice(
                id: id,
                uid: string(of: id, kAudioDevicePropertyDeviceUID) ?? "",
                name: string(of: id, kAudioObjectPropertyName) ?? String(localized: "device.unnamed"),
                inputChannels: channels(of: id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: channels(of: id, scope: kAudioObjectPropertyScopeOutput)
            )
        }
    }

    private static func isAggregate(_ id: AudioObjectID) -> Bool {
        var address = Self.address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeAutoAggregate
    }

    static var defaultOutput: AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    /// Makes the device the one apps play to.
    func makeDefaultOutput() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }

    /// Calls `change` on the main queue whenever devices appear or disappear or the system output changes.
    static func observeChanges(_ change: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in change() }
        }
    }

    /// Speaker labels of the channels apps play to, from the device's speaker configuration in Audio MIDI Setup.
    func outputChannelLabels() -> [AudioChannelLabel] {
        var address = Self.address(kAudioDevicePropertyPreferredChannelLayout, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return [] }
        return Self.labels(of: raw.assumingMemoryBound(to: AudioChannelLayout.self))
    }

    /// Sets the device's sample rate and confirms the device accepted it.
    func setSampleRate(_ rate: Float64) throws {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        var actual: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &actual)
        guard actual == rate else {
            throw CaptureError(errorDescription: String(localized: "error.sampleRate \(name) \(Int(rate))"))
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(of id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channels(of id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Channel labels of a layout given by descriptions, a bitmap or a layout tag.
    private static func labels(of layout: UnsafeMutablePointer<AudioChannelLayout>) -> [AudioChannelLabel] {
        let tag = layout.pointee.mChannelLayoutTag
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            let descriptions = layout.pointer(to: \.mChannelDescriptions)!
            return UnsafeBufferPointer(start: descriptions, count: Int(layout.pointee.mNumberChannelDescriptions)).map(\.mChannelLabel)
        }
        let property: AudioFormatPropertyID
        var specifier: UInt32
        if tag == kAudioChannelLayoutTag_UseChannelBitmap {
            property = kAudioFormatProperty_ChannelLayoutForBitmap
            specifier = layout.pointee.mChannelBitmap.rawValue
        } else {
            property = kAudioFormatProperty_ChannelLayoutForTag
            specifier = tag
        }
        let specifierSize = UInt32(MemoryLayout<UInt32>.size)
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(property, specifierSize, &specifier, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioFormatGetProperty(property, specifierSize, &specifier, &size, raw) == noErr else { return [] }
        let expanded = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        guard expanded.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions else { return [] }
        return labels(of: expanded)
    }
}

extension SurroundChannel {
    /// The surround source for a speaker label within a layout.
    /// Core Audio's 7.1 layouts pair surround with rear surround, where surround is the side pair;
    /// Windows-style layouts pair surround with surround direct, where surround is the back pair.
    init?(label: AudioChannelLabel, in layout: [AudioChannelLabel]) {
        let windowsStyle = layout.contains(kAudioChannelLabel_LeftSurroundDirect) || layout.contains(kAudioChannelLabel_RightSurroundDirect)
        switch label {
        case kAudioChannelLabel_Left: self = .frontLeft
        case kAudioChannelLabel_Right: self = .frontRight
        case kAudioChannelLabel_Center: self = .center
        case kAudioChannelLabel_LeftSurround: self = windowsStyle ? .backLeft : .sideLeft
        case kAudioChannelLabel_RightSurround: self = windowsStyle ? .backRight : .sideRight
        case kAudioChannelLabel_LeftSurroundDirect: self = .sideLeft
        case kAudioChannelLabel_RightSurroundDirect: self = .sideRight
        case kAudioChannelLabel_RearSurroundLeft: self = .backLeft
        case kAudioChannelLabel_RearSurroundRight: self = .backRight
        default: return nil
        }
    }
}

/// Single-producer, single-consumer ring of interleaved frames between two real-time audio threads.
final class SampleRing {
    let channels: Int
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Frames written and read since creation; they only grow.
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)

    init(channels: Int, capacity: Int) {
        self.channels = channels
        self.capacity = capacity
        storage = .allocate(capacity: channels * capacity)
        storage.initialize(repeating: 0, count: channels * capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Frames ready to read.
    var available: Int {
        written.load(ordering: .acquiring) - read.load(ordering: .relaxed)
    }

    /// Producer: appends `frames` frames, each zeroed and then filled by `mix(frame, index)`;
    /// drops them when the reader lags a full ring behind.
    func write(frames: Int, mix: (UnsafeMutablePointer<Float>, Int) -> Void) {
        let start = written.load(ordering: .relaxed)
        guard start + frames - read.load(ordering: .acquiring) <= capacity else { return }
        for f in 0..<frames {
            let frame = storage + ((start + f) % capacity) * channels
            frame.update(repeating: 0, count: channels)
            mix(frame, f)
        }
        written.store(start + frames, ordering: .releasing)
    }

    /// Consumer: copies `frames` frames into planar `out`, channel after channel.
    func read(frames: Int, into out: UnsafeMutablePointer<Float>) {
        let start = read.load(ordering: .relaxed)
        for f in 0..<frames {
            let frame = storage + ((start + f) % capacity) * channels
            for channel in 0..<channels {
                out[channel * frames + f] = frame[channel]
            }
        }
        read.store(start + frames, ordering: .releasing)
    }

    /// Consumer: skips frames so that only `keep` remain.
    func discard(keeping keep: Int) {
        let end = written.load(ordering: .acquiring)
        read.store(max(end - keep, read.load(ordering: .relaxed)), ordering: .releasing)
    }
}

/// Captures what apps play to a loopback device and supplies it as 7.1 surround sources.
final class SystemCapture: BlockSource {
    /// Where one captured channel goes: a surround source and its gain.
    private typealias Route = (source: Int, gain: Float)

    /// Frames buffered before playback starts, and the most allowed before the backlog is dropped.
    /// The two devices run on separate clocks, so the buffer drifts and is corrected at these bounds.
    private static let target = 2 * BinauralConvolver.blockSize
    private static let limit = 6 * BinauralConvolver.blockSize

    private let block = BinauralConvolver.blockSize
    /// Routed device frames, waiting for the worker.
    private let ring = SampleRing(channels: SurroundChannel.allCases.count, capacity: 48000)
    /// Speaker frames the worker has prepared, waiting for the render thread.
    private let prepared = SampleRing(channels: SurroundChannel.allCases.count, capacity: 48000)
    private var device: AudioObjectID?
    private var procID: AudioDeviceIOProcID?
    /// Render thread only: whether playback has a full buffer to start from.
    private var primed = false
    /// Upmixing and separation run on their own thread, which the capture callback wakes:
    /// separation can't run on a real-time audio thread.
    private let wake = DispatchSemaphore(value: 0)
    private let running = Atomic<Bool>(false)
    private var workerDone: DispatchSemaphore?
    /// Worker only: the block being prepared, one plane per speaker.
    private let planes: UnsafeMutablePointer<Float>
    /// A separator waiting to replace the worker's, applied at the next block.
    private let handoff = OSAllocatedUnfairLock<SeparatorHandoff>(uncheckedState: SeparatorHandoff())
    /// Worker only: moves every speaker's bass into the subwoofer.
    private let crossover = BassCrossover()
    private let sounds = SoundSources()

    /// The sounds that stand out in the input and where they come from.
    var soundSources: [SoundSource] { sounds.current }
    /// Worker only: the separator in use, and whether it was fed the previous block.
    private var separator: VocalSeparator?
    private var separatorFed = false

    private struct SeparatorHandoff {
        var pending = false
        var separator: VocalSeparator?
    }

    init() {
        planes = .allocate(capacity: SurroundChannel.allCases.count * BinauralConvolver.blockSize)
        planes.initialize(repeating: 0, count: SurroundChannel.allCases.count * BinauralConvolver.blockSize)
    }

    deinit {
        stop()
        planes.deallocate()
    }

    /// Separates the vocals of stereo with `separator` from the next block on; nil spreads stereo without it.
    func setSeparator(_ separator: VocalSeparator?) {
        handoff.withLock { $0 = SeparatorHandoff(pending: true, separator: separator) }
    }
    /// Peak level of each speaker after routing and upmixing, decaying between blocks.
    private let peaks = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: SurroundChannel.allCases.count))
    /// Peak level of the device's first 16 channels as apps deliver them, decaying between callbacks.
    private let devicePeaks = OSAllocatedUnfairLock(initialState: SIMD16<Float>(repeating: 0))
    /// Number of channels the capture device delivers.
    private(set) var deviceChannels = 0

    /// Current peak level of each delivered device channel, 0 to 1, at most 16.
    var deviceLevels: [Float] {
        let levels = devicePeaks.withLock { $0 }
        return (0..<min(deviceChannels, levels.scalarCount)).map { levels[$0] }
    }
    private let filler = SpeakerFiller()
    private let fillEnabled = Atomic<Bool>(true)
    /// The only speaker left playing, by `SurroundChannel` index, or -1 for all.
    private let solo = Atomic<Int>(-1)

    /// Bit per speaker in `SurroundChannel` order; a set bit silences that speaker.
    private let muted = Atomic<Int>(0)

    /// Plays one speaker alone, or all of them when `speaker` is nil.
    func setSolo(_ speaker: Int?) {
        solo.store(speaker ?? -1, ordering: .relaxed)
    }

    /// Silences the given speakers, by `SurroundChannel` index.
    func setMuted(_ speakers: Set<Int>) {
        muted.store(speakers.reduce(0) { $0 | 1 << $1 }, ordering: .relaxed)
    }
    /// Worker only: consecutive blocks with no sound at all.
    private var silentBlocks = 0
    /// What the input currently carries, as an `InputLayout` raw value.
    private let layout = Atomic<Int>(InputLayout.silent.rawValue)

    var inputLayout: InputLayout {
        InputLayout(rawValue: layout.load(ordering: .relaxed)) ?? .silent
    }

    /// Worker only: consecutive blocks with nothing outside the front pair.
    private var stereoBlocks = 0
    /// Worker only: consecutive blocks with sound on the sides and none behind.
    private var emptyBackBlocks = 0
    /// Blocks of silence, about 100 ms, before speakers count as empty.
    private static let emptyAfter = 10
    private static let frontLeft = SurroundChannel.allCases.firstIndex(of: .frontLeft)!
    private static let frontRight = SurroundChannel.allCases.firstIndex(of: .frontRight)!
    private static let sideLeft = SurroundChannel.allCases.firstIndex(of: .sideLeft)!
    private static let sideRight = SurroundChannel.allCases.firstIndex(of: .sideRight)!
    private static let backLeft = SurroundChannel.allCases.firstIndex(of: .backLeft)!
    private static let backRight = SurroundChannel.allCases.firstIndex(of: .backRight)!
    /// Blocks of sound behind with silent sides, about 2 s, before the input counts as 5.1.
    private static let fivePointOneAfter = 190
    /// Worker only: consecutive blocks with sound behind and none on the sides.
    private var fivePointOneBlocks = 0

    /// Feeds speakers the input leaves silent: stereo spreads to all seven, 5.1 gains the back pair;
    /// full 7.1 always plays as it arrives.
    func setFill(_ on: Bool) {
        fillEnabled.store(on, ordering: .relaxed)
    }

    /// Current peak level of each speaker in `SurroundChannel` order, 0 to 1.
    var levels: [Float] {
        peaks.withLock { $0 }
    }

    /// Starts capturing at 48 kHz and routes channels by the device's speaker configuration;
    /// a device without one plays its first two channels as front left and right.
    func start(_ device: AudioDevice) throws {
        stop()
        try device.setSampleRate(48000)
        let subwoofer = SurroundChannel.allCases.firstIndex(of: .subwoofer)!
        let labels = device.outputChannelLabels()
        var labeled: [Route?] = labels.map { label in
            if label == kAudioChannelLabel_LFEScreen || label == kAudioChannelLabel_LFE2 {
                // LFE plays at -3 dB.
                return (subwoofer, 0.707)
            }
            return SurroundChannel(label: label, in: labels).map { (SurroundChannel.allCases.firstIndex(of: $0)!, 1) }
        }
        if labeled.allSatisfy({ $0 == nil }) {
            labeled = [(SurroundChannel.allCases.firstIndex(of: .frontLeft)!, 1), (SurroundChannel.allCases.firstIndex(of: .frontRight)!, 1)]
        }
        let routes = labeled
        deviceChannels = device.inputChannels
        let devicePeaks = self.devicePeaks
        devicePeaks.withLock { $0 = SIMD16(repeating: 0) }
        let ring = self.ring
        let wake = self.wake
        ring.discard(keeping: 0)
        prepared.discard(keeping: 0)
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mNumberChannels > 0 else { return }
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
            ring.write(frames: frames) { frame, f in
                var channel = 0
                for buffer in buffers {
                    let count = Int(buffer.mNumberChannels)
                    if let samples = buffer.mData?.assumingMemoryBound(to: Float.self) {
                        for k in 0..<count where channel + k < routes.count {
                            if let route = routes[channel + k] {
                                frame[route.source] += route.gain * samples[f * count + k]
                            }
                        }
                    }
                    channel += count
                }
            }
            var block = SIMD16<Float>(repeating: 0)
            var channel = 0
            for buffer in buffers {
                let count = Int(buffer.mNumberChannels)
                if let samples = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    for k in 0..<count where channel + k < block.scalarCount {
                        var peak: Float = 0
                        vDSP_maxmgv(samples + k, vDSP_Stride(count), &peak, vDSP_Length(frames))
                        block[channel + k] = min(peak, 1)
                    }
                }
                channel += count
            }
            devicePeaks.withLockIfAvailable { [block] peaks in
                peaks = pointwiseMax(peaks * 0.9, block)
            }
            wake.signal()
        }
        guard status == noErr, let procID else {
            throw CaptureError(errorDescription: String(localized: "error.capture \(device.name) \(Int(status))"))
        }
        status = AudioDeviceStart(device.id, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device.id, procID)
            throw CaptureError(errorDescription: String(localized: "error.captureStart \(device.name) \(Int(status))"))
        }
        self.device = device.id
        self.procID = procID
        running.store(true, ordering: .relaxed)
        let done = DispatchSemaphore(value: 0)
        workerDone = done
        let worker = Thread { [unowned self] in
            runWorker()
            done.signal()
        }
        worker.name = "OpenSpatial upmix"
        worker.qualityOfService = .userInteractive
        worker.start()
    }

    func stop() {
        guard let device, let procID else { return }
        AudioDeviceStop(device, procID)
        AudioDeviceDestroyIOProcID(device, procID)
        self.device = nil
        self.procID = nil
        running.store(false, ordering: .relaxed)
        wake.signal()
        workerDone?.wait()
        workerDone = nil
    }

    func fill(_ inputs: UnsafeMutablePointer<Float>, sources: Int, frames: Int) -> Bool {
        if prepared.available > Self.limit {
            prepared.discard(keeping: Self.target)
        }
        let available = prepared.available
        if !primed {
            guard available >= Self.target else { return false }
            primed = true
        }
        guard available >= frames else {
            primed = false
            return false
        }
        prepared.read(frames: frames, into: inputs)
        return true
    }

    private func runWorker() {
        while running.load(ordering: .relaxed) {
            _ = wake.wait(timeout: .now() + .milliseconds(100))
            while ring.available >= block {
                prepareBlock()
            }
        }
    }

    /// Turns one block of routed frames into speaker frames for the render thread.
    private func prepareBlock() {
        let sources = SurroundChannel.allCases.count
        ring.read(frames: block, into: planes)
        // Nil when the lock is busy, and nil inside when nothing is waiting.
        if let taken = handoff.withLockIfAvailable({ state -> SeparatorHandoff? in
            defer { state.pending = false }
            return state.pending ? state : nil
        }), let replacement = taken {
            separator = replacement.separator
            separatorFed = false
        }
        placeFivePointOneSurrounds(planes, frames: block)
        classify(planes, sources: sources, frames: block)
        sounds.analyze(planes)
        let fill = fillEnabled.load(ordering: .relaxed)
        if fill, stereoBlocks >= Self.emptyAfter, let separator {
            // Separated stereo plays about two seconds late, through silences too; the speakers stay quiet until it starts.
            if separator.process(planes + Self.frontLeft * block, planes + Self.frontRight * block) {
                filler.spreadStems(planes, stems: separator.stems)
            } else {
                planes.update(repeating: 0, count: sources * block)
            }
            separatorFed = true
        } else {
            if separatorFed {
                separator?.reset()
                separatorFed = false
            }
            if fill {
                if stereoBlocks >= Self.emptyAfter {
                    filler.spreadStereo(planes)
                } else if emptyBackBlocks >= Self.emptyAfter {
                    filler.fillBack(planes)
                }
            }
        }
        crossover.process(planes)
        meter(planes, sources: sources, frames: block)
        let soloed = solo.load(ordering: .relaxed)
        let silenced = muted.load(ordering: .relaxed)
        for source in 0..<sources where (soloed >= 0 && source != soloed) || silenced & (1 << source) != 0 {
            (planes + source * block).update(repeating: 0, count: block)
        }
        let planes = self.planes, block = self.block
        prepared.write(frames: block) { frame, f in
            for source in 0..<sources {
                frame[source] = planes[source * block + f]
            }
        }
    }

    private func meter(_ inputs: UnsafeMutablePointer<Float>, sources: Int, frames: Int) {
        // A fixed-size vector carries the block's peaks into the lock without allocating.
        var block = SIMD8<Float>(repeating: 0)
        for source in 0..<min(sources, block.scalarCount) {
            var peak: Float = 0
            vDSP_maxmgv(inputs + source * frames, 1, &peak, vDSP_Length(frames))
            block[source] = min(peak, 1)
        }
        peaks.withLockIfAvailable { [block] peaks in
            for source in 0..<min(peaks.count, block.scalarCount) {
                peaks[source] = max(peaks[source] * 0.9, block[source])
            }
        }
    }

    /// 5.1 surrounds stand near 110°, closer to the side speakers than the back ones. A layout whose
    /// surround pair means the back in 7.1 delivers 5.1 surrounds there, so while the sides stay silent
    /// and the back carries sound, the back pair moves to the sides; any sound on the sides restores 7.1 at once.
    private func placeFivePointOneSurrounds(_ inputs: UnsafeMutablePointer<Float>, frames: Int) {
        let sides = max(peak(inputs, Self.sideLeft, frames: frames), peak(inputs, Self.sideRight, frames: frames))
        let backs = max(peak(inputs, Self.backLeft, frames: frames), peak(inputs, Self.backRight, frames: frames))
        if sides >= Self.silence {
            fivePointOneBlocks = 0
        } else if backs >= Self.silence {
            fivePointOneBlocks += 1
        }
        guard fivePointOneBlocks >= Self.fivePointOneAfter else { return }
        (inputs + Self.sideLeft * frames).update(from: inputs + Self.backLeft * frames, count: frames)
        (inputs + Self.sideRight * frames).update(from: inputs + Self.backRight * frames, count: frames)
        (inputs + Self.backLeft * frames).update(repeating: 0, count: frames)
        (inputs + Self.backRight * frames).update(repeating: 0, count: frames)
    }

    /// Tracks which speakers the input fills: stereo has nothing outside the front pair,
    /// 5.1 has sound on the sides and none behind, 7.1 has both.
    private func classify(_ inputs: UnsafeMutablePointer<Float>, sources: Int, frames: Int) {
        let fronts = max(peak(inputs, Self.frontLeft, frames: frames), peak(inputs, Self.frontRight, frames: frames))
        var others: Float = 0
        for source in 0..<sources where source != Self.frontLeft && source != Self.frontRight {
            others = max(others, peak(inputs, source, frames: frames))
        }
        let sides = max(peak(inputs, Self.sideLeft, frames: frames), peak(inputs, Self.sideRight, frames: frames))
        let backs = max(peak(inputs, Self.backLeft, frames: frames), peak(inputs, Self.backRight, frames: frames))
        silentBlocks = max(fronts, others) < Self.silence ? silentBlocks + 1 : 0
        stereoBlocks = others < Self.silence ? stereoBlocks + 1 : 0
        if backs >= Self.silence {
            emptyBackBlocks = 0
        } else if sides >= Self.silence {
            emptyBackBlocks += 1
        }
        let current: InputLayout =
            if silentBlocks >= Self.emptyAfter { .silent }
            else if stereoBlocks >= Self.emptyAfter { .stereo }
            else if emptyBackBlocks >= Self.emptyAfter { .fivePointOne }
            else { .sevenPointOne }
        layout.store(current.rawValue, ordering: .relaxed)
    }

    private static let silence: Float = 1e-6

    private func peak(_ inputs: UnsafeMutablePointer<Float>, _ source: Int, frames: Int) -> Float {
        var value: Float = 0
        vDSP_maxmgv(inputs + source * frames, 1, &value, vDSP_Length(frames))
        return value
    }
}
