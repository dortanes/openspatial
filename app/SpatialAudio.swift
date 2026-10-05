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
    /// Linear gain of each speaker in `SurroundChannel` order: the listener's calibration, and how much nearer
    /// the listener has moved to it.
    private var levels = [Float](repeating: 1, count: SurroundChannel.allCases.count)
    private var nearness = [Float](repeating: 1, count: SurroundChannel.allCases.count)
    /// Metres from the listener to every speaker, for turning a move of the listener into speaker directions and levels.
    private static let speakerDistance = 2.0

    /// The rooms handed to the renderer lately, newest last. The render thread lets go of a room when it switches
    /// to the next one, so they are released here instead, on the main thread, after it has moved on.
    private var rooms: [RoomFilters] = []

    var hasMeasuredRoom: Bool { speakers != nil }

    /// Starts in the standard room, which the app carries.
    init() {
        let capture = self.capture
        let room = try? Room.standard.load()
        ringPositions = room?.ring.positions
        speakers = room.map { room in
            BinauralPlayer(
                room: room,
                azimuths: SurroundChannel.allCases.map(\.azimuth),
                source: capture,
                downmix: SurroundChannel.allCases.map(\.stereoDownmix)
            )
        }
        rooms = room.map { [$0] } ?? []
    }

    /// Moves the speakers into another room, crossfading at the next block.
    func setRoom(_ room: RoomFilters) {
        speakers?.setRoom(room)
        rooms = (rooms + [room]).suffix(3)
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

    func setCrossover(_ hertz: Int) {
        capture.setCrossover(hertz)
    }

    func setSubwooferInverted(_ on: Bool) {
        capture.setSubwooferInverted(on)
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
        for (speaker, level) in decibels.prefix(levels.count).enumerated() {
            levels[speaker] = Float(pow(10, level / 20))
        }
        speakers?.setGains(zip(levels, nearness).map(*))
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

    /// The listener turns `turn` degrees to the right and moves `right` metres to the right and `forward` metres
    /// toward the front speakers; the speakers stay where they are in the room, and the ones the listener moved
    /// nearer play louder. The subwoofer has no direction and stays as it is.
    func placeListener(turn: Double, right: Double, forward: Double) {
        guard let size = ringPositions else { return }
        for (source, channel) in SurroundChannel.allCases.enumerated() {
            var azimuth = channel.azimuth
            if channel != .subwoofer {
                let radians = azimuth * .pi / 180
                let x = sin(radians) * Self.speakerDistance - right
                let z = cos(radians) * Self.speakerDistance - forward
                azimuth = atan2(x, z) * 180 / .pi
                nearness[source] = Float(Self.speakerDistance / hypot(x, z))
            }
            let relative = Int((azimuth - turn).rounded()) % size
            speakers?.setPosition((relative + size) % size, source: source)
        }
        speakers?.setGains(zip(levels, nearness).map(*))
    }
}
