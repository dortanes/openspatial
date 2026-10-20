import CoreAudio
import SwiftUI

struct ChannelLevel: Identifiable {
    /// Speaker or device channel index, from zero.
    let id: Int
    let name: String
    let level: Double
}

/// Values that change many times a second, kept apart so only the views showing them redraw.
/// They update only while a window of the app is on screen.
@MainActor
final class LiveState: ObservableObject {
    /// Level of each virtual speaker, after filling empty speakers.
    @Published fileprivate(set) var speakerLevels: [ChannelLevel] = []
    /// Level of each capture device channel before routing.
    @Published fileprivate(set) var deviceLevels: [ChannelLevel] = []
    /// The sounds that stand out in the input and where they come from.
    @Published fileprivate(set) var soundSources: [SoundSource] = []
    /// Smoothed head turn in degrees, positive to the right.
    @Published fileprivate(set) var yaw = 0.0
    /// Metres the listener has moved toward the front speakers by leaning in; negative when leaning back.
    @Published fileprivate(set) var lean = 0.0
    /// Metres the listener has moved to the right; negative to the left.
    @Published fileprivate(set) var shift = 0.0
    @Published fileprivate(set) var framesPerSecond = 0
}

/// Where the chosen room is on its way to the speakers.
enum RoomStatus: Equatable {
    case ready
    /// Download progress from 0 to 1.
    case downloading(Double)
    case loading
    case failed(String)
}

enum SeparationStatus: Equatable {
    case off
    /// Download progress from 0 to 1.
    case downloading(Double)
    case starting
    case on
    case failed(String)
}

@MainActor
final class Model: ObservableObject {
    /// Spatial rendering on, or plain stereo with the camera off.
    @Published var enabled: Bool {
        didSet {
            audio.setEnabled(enabled)
            updateTracking()
            save()
        }
    }
    @Published var tracking: Bool { didSet { updateTracking(); save() } }
    /// Late reverberation of the measured room, from none to as measured.
    @Published var roomReverb: Double { didSet { audio.setRoomReverb(roomReverb); save() } }
    /// Multiplies the measured head turn before it reaches the renderer.
    @Published var turnGain: Double { didSet { applyOrientation(); save() } }
    /// Camera frames per second; more follows quick turns sooner and costs more CPU.
    @Published var trackingRate: Int { didSet { tracker.setFrameRate(trackingRate); save() } }
    @Published var toneShaping: Bool { didSet { audio.setToneShaping(toneShaping); save() } }
    @Published var upperBand: EQBand { didSet { audio.setBand(0, upperBand); save() } }
    @Published var lowerBand: EQBand { didSet { audio.setBand(1, lowerBand); save() } }
    /// Boost in decibels for when the system volume at its top isn't loud enough.
    @Published var gain: Double { didSet { audio.setGain(gain); save() } }
    @Published var stabilizer: Bool { didSet { audio.setStabilizer(stabilizer); save() } }
    @Published var limiter: Bool { didSet { audio.setLimiter(limiter); save() } }
    /// Feeds speakers system audio leaves silent: stereo spreads to all seven, 5.1 gains the back pair.
    @Published var fillSpeakers: Bool { didSet { audio.setFill(fillSpeakers); save() } }
    /// Splits stereo into the voice and the rest with a downloaded model before spreading it.
    @Published var separateStems: Bool { didSet { updateSeparation(); save() } }
    @Published private(set) var separation = SeparationStatus.off
    /// Level of each speaker in decibels, in `SurroundChannel` order; it calibrates the listener's own headphones.
    @Published var speakerLevels: [Double] { didSet { audio.setSpeakerLevels(speakerLevels); save() } }
    /// Where the speakers stand; a room not inside the app downloads when chosen.
    @Published var room: Room { didSet { updateRoom(); save() } }
    @Published private(set) var roomStatus = RoomStatus.ready
    /// Hertz below which every speaker's bass plays from the subwoofer.
    @Published var crossover: Int { didSet { audio.setCrossover(crossover); save() } }
    /// The subwoofer with its polarity flipped, which cancels bass around the crossover.
    @Published var subwooferInverted: Bool { didSet { audio.setSubwooferInverted(subwooferInverted); save() } }
    /// Capture restarts with it, because the channels it reads follow the driver's labels.
    @Published var channelLayout: ChannelLayout { didSet { updateCapture(); save() } }
    /// Devices the rendered sound can play on; never the driver, which would feed back.
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published var outputDeviceID: AudioObjectID = 0 {
        didSet {
            applyOutputDevice()
            rememberChoice()
        }
    }
    /// The OpenSpatial driver's device, which carries apps' sound to the app; 0 while it isn't installed.
    @Published private(set) var driverDeviceID: AudioObjectID = 0 { didSet { updateCapture() } }
    /// Whether apps play to the driver, which is what lets the app hear them.
    @Published private(set) var systemOutputIsDriver = false
    /// The one speaker playing while testing, by `SurroundChannel` index; nil plays all. Not saved.
    @Published var soloSpeaker: Int? { didSet { audio.setSolo(soloSpeaker) } }
    /// Speakers silenced while testing, by `SurroundChannel` index. Not saved.
    @Published var mutedSpeakers: Set<Int> = [] { didSet { audio.setMuted(mutedSpeakers) } }
    @Published private(set) var audioError: String?
    @Published private(set) var trackingError: String?
    @Published private(set) var installingDriver = false
    @Published private(set) var driverError: String?
    /// Without the camera the app runs with head tracking unavailable.
    @Published private(set) var cameraAllowed = Permission.camera.isAllowed
    /// What apps are playing, set only when it changes.
    @Published private(set) var inputLayout = InputLayout.silent
    /// Whether the camera sees a face, set only when it changes.
    @Published private(set) var faceFound = false

    let live = LiveState()

    /// Set once the microphone is allowed; capture waits for it.
    private var microphoneAllowed = false
    private var driverDevice: AudioDevice?
    /// The output device the listener picked, by UID; automatic fallbacks while it is missing don't replace it.
    private var preferredOutputUID: String?
    /// Where the system output returns when the app quits, by UID.
    private var previousSystemOutputUID: String?
    /// Set once the app has moved the system output to the driver in this run; a later change by the listener stands.
    private var tookSystemOutput = false
    /// Set while the app picks the output itself, so the pick isn't remembered as the listener's choice.
    private var choosingDevices = false
    /// Exponential smoothing factor per camera frame; lower is steadier but lags more.
    private let smoothing = 0.5
    private var yaw = 0.0
    private var rawYaw = 0.0
    private var centerYaw = 0.0
    /// Moving in front of the screen moves the listener among the speakers. Against where the face was when
    /// centered, about `cameraDistance` metres from a camera with a horizontal field of view of about
    /// `fieldOfView` degrees, its width gives the move toward the screen and its place across the frame the move
    /// sideways. The listener moves `moveScale` times as far, ignoring the first `moveDeadzone` metres and stopping
    /// at `maxMove` either way. The face's size and place are noisier than its turn, so they are smoothed more.
    private static let cameraDistance = 0.6
    private static let fieldOfView = 70.0
    private static let moveScale = 2.0
    private static let moveDeadzone = 0.05
    private static let maxMove = 0.8
    private static let moveSmoothing = 0.15
    /// Metres toward the front speakers and to the right.
    private var lean = 0.0
    private var shift = 0.0
    private var rawSize = 0.0
    private var rawAcross = 0.5
    /// Zero until the first face sets it.
    private var centerSize = 0.0
    private var centerAcross = 0.5
    private var frameCount = 0
    private var rateWindowStart = Date()
    private var meterTimer: Timer?
    private var separationTask: Task<Void, Never>?
    private var roomTask: Task<Void, Never>?
    private let audio = SpatialAudio()
    private let tracker = HeadTracker()
    private let volume = VolumeLink()

    init() {
        let saved = Preferences.load()
        enabled = saved.enabled
        tracking = saved.tracking
        roomReverb = saved.roomReverb
        turnGain = saved.turnGain
        trackingRate = saved.trackingRate
        toneShaping = saved.toneShaping
        upperBand = saved.upperBand
        lowerBand = saved.lowerBand
        gain = saved.gain
        stabilizer = saved.stabilizer
        limiter = saved.limiter
        fillSpeakers = saved.fillSpeakers
        separateStems = saved.separateStems
        speakerLevels = saved.speakerLevels
        room = saved.room
        crossover = saved.crossover
        subwooferInverted = saved.subwooferInverted
        channelLayout = saved.channelLayout
        preferredOutputUID = saved.outputDeviceUID
        previousSystemOutputUID = saved.previousSystemOutputUID

        let audio = self.audio
        volume.applyGain = { audio.setOutputGain($0) }
        refreshDevices()
        do {
            guard audio.hasMeasuredRoom else {
                throw CaptureError(errorDescription: String(localized: "error.roomMissing"))
            }
            try audio.setOutputDevice(outputDeviceID)
            try audio.start()
        } catch {
            audioError = String(localized: "error.outputStart \(error.localizedDescription)")
        }
        audio.setEnabled(enabled)
        audio.setRoomReverb(roomReverb)
        audio.setToneShaping(toneShaping)
        audio.setBand(0, upperBand)
        audio.setBand(1, lowerBand)
        audio.setGain(gain)
        audio.setStabilizer(stabilizer)
        audio.setLimiter(limiter)
        audio.setFill(fillSpeakers)
        audio.setSpeakerLevels(speakerLevels)
        audio.setCrossover(crossover)
        audio.setSubwooferInverted(subwooferInverted)
        updateSeparation()
        if room != .standard {
            updateRoom()
        }
        applyOrientation()
        AudioDevice.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        audio.observeConfigurationChanges { [weak self] in
            MainActor.assumeIsolated { self?.restoreOutput() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreSystemOutput() }
        }
        tracker.setFrameRate(trackingRate)
        tracker.onPose = { [weak self] pose in
            Task { @MainActor in self?.update(pose) }
        }
        tracker.onError = { [weak self] message in
            Task { @MainActor in self?.trackingError = message }
        }
        Task { [weak self] in
            if let pending = DriverInstaller.pending, await DriverSetupPanel.ask(pending) {
                await self?.installDriver()
            }
            guard await Permission.microphone.request() else {
                Permission.microphone.explainAndQuit()
                return
            }
            let camera = await Permission.camera.request()
            guard let self else { return }
            microphoneAllowed = true
            cameraAllowed = camera
            updateCapture()
            updateTracking()
        }
    }

    var outputDeviceName: String? {
        outputDevices.first { $0.id == outputDeviceID }?.name
    }

    /// Takes where the listener is now as straight ahead, in the middle of the speakers.
    func recenter() {
        centerYaw = rawYaw
        centerSize = rawSize
        centerAcross = rawAcross
        yaw = 0
        lean = 0
        shift = 0
        live.yaw = 0
        live.lean = 0
        live.shift = 0
        applyOrientation()
    }

    /// Installs the driver the app carries, then waits up to 5 s for Core Audio to come back with it.
    func installDriver() async {
        guard !installingDriver else { return }
        installingDriver = true
        driverError = nil
        DriverSetupPanel.showProgress()
        defer {
            installingDriver = false
            DriverSetupPanel.hide()
        }
        do {
            try await DriverInstaller.install()
        } catch is CancellationError {
            return
        } catch {
            driverError = String(localized: "error.driverInstall \(error.localizedDescription)")
            return
        }
        for _ in 0..<10 {
            refreshDevices()
            if driverDeviceID != 0 { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    func resetSpeakerLevels() {
        speakerLevels = Preferences().speakerLevels
    }

    private func save() {
        var preferences = Preferences()
        preferences.enabled = enabled
        preferences.tracking = tracking
        preferences.roomReverb = roomReverb
        preferences.turnGain = turnGain
        preferences.trackingRate = trackingRate
        preferences.toneShaping = toneShaping
        preferences.upperBand = upperBand
        preferences.lowerBand = lowerBand
        preferences.gain = gain
        preferences.stabilizer = stabilizer
        preferences.limiter = limiter
        preferences.fillSpeakers = fillSpeakers
        preferences.separateStems = separateStems
        preferences.speakerLevels = speakerLevels
        preferences.room = room
        preferences.crossover = crossover
        preferences.subwooferInverted = subwooferInverted
        preferences.channelLayout = channelLayout
        preferences.outputDeviceUID = preferredOutputUID
        preferences.previousSystemOutputUID = previousSystemOutputUID
        preferences.save()
    }

    /// Remembers an output device the listener picked in settings.
    private func rememberChoice() {
        guard !choosingDevices else { return }
        preferredOutputUID = outputDevices.first { $0.id == outputDeviceID }?.uid ?? preferredOutputUID
        save()
    }

    /// Re-reads the device list, finds the driver and picks the listener's output when present,
    /// otherwise a sensible fallback.
    private func refreshDevices() {
        choosingDevices = true
        defer { choosingDevices = false }
        let devices = AudioDevice.all()
        let driver = devices.first { $0.uid == AudioDevice.driverUID }
        if driver?.id ?? 0 != driverDeviceID {
            driverDevice = driver
            driverDeviceID = driver?.id ?? 0
        }
        outputDevices = devices.filter { $0.outputChannels >= 2 && $0.id != driverDeviceID }
        let output = outputDevices.first { $0.uid == preferredOutputUID }
            ?? outputDevices.first { $0.id == outputDeviceID }
            ?? AudioDevice.defaultOutput.flatMap { id in outputDevices.first { $0.id == id } }
            ?? outputDevices.first
        if output?.id ?? 0 != outputDeviceID {
            outputDeviceID = output?.id ?? 0
        }
        takeSystemOutput(from: devices)
        systemOutputIsDriver = driverDeviceID != 0 && AudioDevice.defaultOutput == driverDeviceID
        volume.connect(driver: driverDeviceID, headphones: outputDeviceID)
        restoreOutput()
    }

    /// Moves the system output to the driver once per run, remembering where it was. When the output is
    /// already on the driver, as after a crash, the device remembered then stays.
    private func takeSystemOutput(from devices: [AudioDevice]) {
        guard !tookSystemOutput, let driver = driverDevice else { return }
        tookSystemOutput = true
        guard let current = AudioDevice.defaultOutput, current != driver.id else { return }
        previousSystemOutputUID = devices.first { $0.id == current }?.uid
        save()
        driver.makeDefaultOutput()
    }

    /// Returns the system output to where it was before the app took it, unless the listener has moved it since.
    private func restoreSystemOutput() {
        defer {
            previousSystemOutputUID = nil
            save()
        }
        guard driverDeviceID != 0, AudioDevice.defaultOutput == driverDeviceID else { return }
        let previous = outputDevices.first { $0.uid == previousSystemOutputUID } ?? outputDevices.first { $0.id == outputDeviceID }
        previous?.makeDefaultOutput()
    }

    /// Switching the system output can stop the engine or move it off the chosen device; this puts it back.
    private func restoreOutput() {
        if !audio.isPlayingOnOutputDevice {
            applyOutputDevice()
        }
    }

    private func applyOutputDevice() {
        do {
            try audio.setOutputDevice(outputDeviceID)
        } catch {
            audioError = String(localized: "error.outputDevice \(error.localizedDescription)")
        }
    }

    /// Downloads the separation model the first time, then starts separating; turning it off stops at once.
    private func updateSeparation() {
        separationTask?.cancel()
        audio.setSeparator(nil)
        guard separateStems else {
            separation = .off
            return
        }
        separationTask = Task { [weak self] in
            do {
                if !VocalModel.isDownloaded {
                    self?.separation = .downloading(0)
                    try await VocalModel.download { fraction in
                        Task { @MainActor in
                            if case .downloading = self?.separation {
                                self?.separation = .downloading(fraction)
                            }
                        }
                    }
                }
                try Task.checkCancellation()
                self?.separation = .starting
                let separator = try await Self.loadSeparator()
                try Task.checkCancellation()
                self?.audio.setSeparator(separator)
                self?.separation = .on
            } catch {
                guard !Task.isCancelled else { return }
                let reason = (error as? ModelError)?.message ?? error.localizedDescription
                self?.separation = .failed(String(localized: "error.separation \(reason)"))
            }
        }
    }

    /// Downloads the chosen room if it isn't here yet, then hands it to the renderer, which crossfades into it.
    private func updateRoom() {
        roomTask?.cancel()
        let room = self.room
        roomTask = Task { [weak self] in
            do {
                if !room.isAvailable {
                    self?.roomStatus = .downloading(0)
                    try await room.download { fraction in
                        Task { @MainActor in
                            if case .downloading = self?.roomStatus {
                                self?.roomStatus = .downloading(fraction)
                            }
                        }
                    }
                }
                try Task.checkCancellation()
                self?.roomStatus = .loading
                let filters = try await Self.loadRoom(room)
                try Task.checkCancellation()
                self?.audio.setRoom(filters)
                self?.roomStatus = .ready
            } catch {
                guard !Task.isCancelled else { return }
                let reason = (error as? ModelError)?.message ?? error.localizedDescription
                self?.roomStatus = .failed(String(localized: "error.room \(reason)"))
            }
        }
    }

    /// Transforming a room's responses takes a moment, so it happens off the main thread.
    private nonisolated static func loadRoom(_ room: Room) async throws -> RoomFilters {
        try room.load()
    }

    /// Loading the model takes a moment, so it happens off the main thread.
    private nonisolated static func loadSeparator() async throws -> VocalSeparator {
        try VocalSeparator(model: VocalModel.location)
    }

    /// Captures the driver and meters it.
    private func updateCapture() {
        audio.stopCapture()
        meterTimer?.invalidate()
        meterTimer = nil
        live.speakerLevels = []
        live.deviceLevels = []
        inputLayout = .silent
        guard microphoneAllowed, let device = driverDevice else { return }
        device.setOutputChannelLabels(channelLayout.labels)
        do {
            try audio.startCapture(device)
            audioError = nil
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateLevels() }
            }
        } catch {
            audioError = error.localizedDescription
        }
    }

    private func updateLevels() {
        if inputLayout != audio.inputLayout {
            inputLayout = audio.inputLayout
        }
        guard showsLiveValues else { return }
        live.speakerLevels = zip(SurroundChannel.allCases, audio.captureLevels).enumerated().map {
            ChannelLevel(id: $0, name: $1.0.title, level: Double($1.1))
        }
        live.soundSources = audio.soundSources
        live.deviceLevels = audio.captureDeviceLevels.enumerated().map {
            ChannelLevel(id: $0, name: String(localized: "speakers.deviceChannel \($0 + 1)"), level: Double($1))
        }
    }

    /// Whether a window of the app is on screen. A closed window keeps its views, which would otherwise
    /// lay out again on every live update. The menu bar icon and panel live in windows above the normal level.
    private var showsLiveValues: Bool {
        NSApplication.shared.windows.contains {
            $0.level == .normal && $0.isVisible && $0.occlusionState.contains(.visible)
        }
    }

    /// The camera runs only while spatial rendering and head tracking are both on.
    private func updateTracking() {
        let on = cameraAllowed && enabled && tracking
        tracker.setRunning(on)
        if !on {
            faceFound = false
            live.framesPerSecond = 0
            trackingError = nil
        }
        applyOrientation()
    }

    private func update(_ pose: HeadPose?) {
        countFrame()
        guard let pose else {
            if faceFound { faceFound = false }
            return
        }
        if !faceFound { faceFound = true }
        rawYaw = pose.yaw
        yaw += (rawYaw - centerYaw - yaw) * smoothing
        rawSize = pose.size
        rawAcross = pose.across
        if centerSize == 0 {
            centerSize = rawSize
            centerAcross = rawAcross
        }
        // Distance scales inversely with the face's width; the frame is wider the farther the face is.
        let distance = Self.cameraDistance * centerSize / rawSize
        let frameWidth = 2 * distance * tan(Self.fieldOfView / 2 * .pi / 180)
        lean += (Self.move(Self.cameraDistance - distance) - lean) * Self.moveSmoothing
        shift += (Self.move((rawAcross - centerAcross) * frameWidth) - shift) * Self.moveSmoothing
        if showsLiveValues {
            live.yaw = yaw
            live.lean = lean
            live.shift = shift
        }
        applyOrientation()
    }

    private func countFrame() {
        frameCount += 1
        let elapsed = Date().timeIntervalSince(rateWindowStart)
        if elapsed >= 1 {
            if showsLiveValues {
                live.framesPerSecond = Int((Double(frameCount) / elapsed).rounded())
            }
            frameCount = 0
            rateWindowStart = Date()
        }
    }

    private func applyOrientation() {
        let follows = enabled && tracking
        audio.placeListener(turn: follows ? yaw * turnGain : 0, right: follows ? shift : 0, forward: follows ? lean : 0)
    }

    /// The listener's move in metres for the face's move: scaled, without the dead zone, and within the limit.
    private static func move(_ metres: Double) -> Double {
        let moved = min(maxMove, max(0, abs(metres * moveScale) - moveDeadzone))
        return metres < 0 ? -moved : moved
    }
}
