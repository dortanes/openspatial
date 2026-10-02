import AVFoundation
import CoreAudio

/// Renders captured system audio from 7.1 loudspeakers around the listener in the measured room.
final class SpatialAudio {
    private let engine = AVAudioEngine()
    private let capture = SystemCapture()
    /// Positions on the measured ring; nil when the room data is missing from the bundle.
    private let ringPositions: Int?
    /// One re-aimed loudspeaker per `SurroundChannel`, all sharing the ring's filters.
    private let speakers: BinauralPlayer?
    /// Tone shaping in its two bands; its global gain is the listener's boost.
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    /// Brings quiet passages up and settles loud ones near one level.
    private let stabilizer = SpatialAudio.appleEffect(kAudioUnitSubType_DynamicsProcessor)
    /// Keeps peaks under full scale, where a boost would otherwise clip.
    private let limiter = SpatialAudio.appleEffect(kAudioUnitSubType_PeakLimiter)
    private var started = false
    /// The device the listener chose; hardware changes can stop the engine or move it elsewhere.
    private var outputDevice: AudioObjectID = 0

    var hasMeasuredRoom: Bool { speakers != nil }

    /// The time-domain room data lives only here; the filter bank keeps its spectra.
    init() {
        let capture = self.capture
        let roomData = Bundle.main.resourceURL.flatMap { try? MeasuredRoomData.load(from: $0) }
        ringPositions = roomData?.ring.positions
        speakers = roomData.map { roomData in
            let ring = FilterBank(table: roomData.ring)
            return BinauralPlayer(
                filters: SurroundChannel.allCases.map { _ in ring },
                source: capture,
                downmix: SurroundChannel.allCases.map(\.stereoDownmix)
            )
        }
    }

    func start() throws {
        guard let speakers else { return }
        for node in [speakers.node, stabilizer, eq, limiter] as [AVAudioNode] {
            engine.attach(node)
        }
        for band in eq.bands {
            band.filterType = .parametric
            band.bandwidth = 1
        }
        // Measured offline with a 440 Hz tone on macOS 27: inputs from -23 to -3 dB RMS leave at -20 dB RMS,
        // quieter ones rise by 10 dB.
        for (parameter, value) in [
            (kDynamicsProcessorParam_Threshold, -30),
            (kDynamicsProcessorParam_HeadRoom, 3),
            (kDynamicsProcessorParam_ExpansionRatio, 1),
            (kDynamicsProcessorParam_AttackTime, 0.02),
            (kDynamicsProcessorParam_ReleaseTime, 1),
            (kDynamicsProcessorParam_OverallGain, 10),
        ] as [(AudioUnitParameterID, Float)] {
            AudioUnitSetParameter(stabilizer.audioUnit, parameter, kAudioUnitScope_Global, 0, value, 0)
        }
        connectGraph()
        try engine.start()
        speakers.setActive(true)
        started = true
    }

    /// Plays the rendered sound on a device other than the system output, which carries apps' audio into the capture.
    func setOutputDevice(_ id: AudioObjectID) throws {
        guard id != 0 else { return }
        outputDevice = id
        engine.stop()
        try engine.outputNode.auAudioUnit.setDeviceID(id)
        guard started else { return }
        connectGraph()
        try engine.start()
    }

    /// Whether sound still reaches the chosen device; false after a hardware change stopped the engine or moved it.
    var isPlayingOnOutputDevice: Bool {
        !started || (engine.isRunning && engine.outputNode.auAudioUnit.deviceID == outputDevice)
    }

    /// Calls `change` on the main queue whenever the engine stops itself after an output hardware change.
    func observeConfigurationChanges(_ change: @escaping () -> Void) {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            change()
        }
    }

    /// A linear gain on everything the app plays, for mute and headphones without a volume control.
    func setOutputGain(_ gain: Float) {
        engine.mainMixerNode.outputVolume = gain
    }

    /// Spatial rendering on, or plain stereo that still plays everything the apps send.
    func setEnabled(_ on: Bool) {
        speakers?.setBypass(!on)
    }

    func startCapture(_ device: AudioDevice) throws {
        try capture.start(device)
    }

    func stopCapture() {
        capture.stop()
    }

    func setFill(_ on: Bool) {
        capture.setFill(on)
    }

    func setSeparator(_ separator: VocalSeparator?) {
        capture.setSeparator(separator)
    }

    func setSolo(_ speaker: Int?) {
        capture.setSolo(speaker)
    }

    func setMuted(_ speakers: Set<Int>) {
        capture.setMuted(speakers)
    }

    var captureLevels: [Float] { capture.levels }
    var captureDeviceLevels: [Float] { capture.deviceLevels }
    var inputLayout: InputLayout { capture.inputLayout }
    var soundSources: [SoundSource] { capture.soundSources }

    /// Connects the renderer and effects at their own 48 kHz; the main mixer converts to the output device's rate.
    /// The stabilizer comes first so the boost and the limiter work on an even level.
    private func connectGraph() {
        guard let speakers else { return }
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.connect(speakers.node, to: stabilizer, format: nil)
        engine.connect(stabilizer, to: eq, format: nil)
        engine.connect(eq, to: limiter, format: nil)
        engine.connect(limiter, to: engine.mainMixerNode, format: nil)
    }

    private static func appleEffect(_ subtype: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
    }

    /// Level of each speaker in decibels, in `SurroundChannel` order.
    func setSpeakerLevels(_ decibels: [Double]) {
        speakers?.setGains(decibels.map { Float(pow(10, $0 / 20)) })
    }

    /// Scales the measured room's late reverberation; 1 keeps the room as measured.
    func setRoomReverb(_ amount: Double) {
        speakers?.setLateGain(Float(amount))
    }

    func setToneShaping(_ enabled: Bool) {
        for band in eq.bands {
            band.bypass = !enabled
        }
    }

    /// Boost in decibels on top of the system volume.
    func setGain(_ decibels: Double) {
        eq.globalGain = Float(decibels)
    }

    func setStabilizer(_ on: Bool) {
        stabilizer.bypass = !on
    }

    func setLimiter(_ on: Bool) {
        limiter.bypass = !on
    }

    func setBand(_ index: Int, _ band: EQBand) {
        eq.bands[index].frequency = Float(band.frequency)
        eq.bands[index].gain = Float(band.gain)
    }

    /// Positive degrees turn the listener to the right; the speakers stay where they are in the room.
    func turnListener(degrees: Double) {
        guard let size = ringPositions else { return }
        for (source, channel) in SurroundChannel.allCases.enumerated() {
            let relative = Int((channel.azimuth - degrees).rounded()) % size
            speakers?.setPosition((relative + size) % size, source: source)
        }
    }
}
