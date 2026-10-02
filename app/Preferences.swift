import Foundation

/// Every setting the listener changes, saved as one value whenever any of them changes.
/// A setting missing from the saved value, such as one added in a later version, takes its default.
struct Preferences: Codable {
    var enabled = true
    var tracking = true
    var roomReverb = 0.15
    var turnGain = 1.0
    /// Camera frames per second for head tracking, one of `HeadTracker.frameRates`.
    var trackingRate = 20
    var toneShaping = false
    var upperBand = EQBand(frequency: 4500, gain: 3)
    var lowerBand = EQBand(frequency: 400, gain: 0)
    var gain = 0.0
    var stabilizer = false
    var limiter = true
    var fillSpeakers = true
    /// Off until the listener asks for it, because it downloads a model.
    var separateStems = false
    /// Decibels per speaker, in `SurroundChannel` order.
    var speakerLevels = Array(repeating: 0.0, count: SurroundChannel.allCases.count)
    /// The output device the listener picked, by Core Audio UID.
    var outputDeviceUID: String?
    /// The system output before the app moved it to the driver, by UID; kept until it is restored,
    /// so a launch after a crash still knows where to return.
    var previousSystemOutputUID: String?

    private static let key = "preferences"

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences()
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        tracking = try values.decodeIfPresent(Bool.self, forKey: .tracking) ?? defaults.tracking
        roomReverb = try values.decodeIfPresent(Double.self, forKey: .roomReverb) ?? defaults.roomReverb
        turnGain = try values.decodeIfPresent(Double.self, forKey: .turnGain) ?? defaults.turnGain
        let rate = try values.decodeIfPresent(Int.self, forKey: .trackingRate)
        trackingRate = rate.flatMap { HeadTracker.frameRates.contains($0) ? $0 : nil } ?? defaults.trackingRate
        toneShaping = try values.decodeIfPresent(Bool.self, forKey: .toneShaping) ?? defaults.toneShaping
        upperBand = try values.decodeIfPresent(EQBand.self, forKey: .upperBand) ?? defaults.upperBand
        lowerBand = try values.decodeIfPresent(EQBand.self, forKey: .lowerBand) ?? defaults.lowerBand
        gain = try values.decodeIfPresent(Double.self, forKey: .gain) ?? defaults.gain
        stabilizer = try values.decodeIfPresent(Bool.self, forKey: .stabilizer) ?? defaults.stabilizer
        limiter = try values.decodeIfPresent(Bool.self, forKey: .limiter) ?? defaults.limiter
        fillSpeakers = try values.decodeIfPresent(Bool.self, forKey: .fillSpeakers) ?? defaults.fillSpeakers
        separateStems = try values.decodeIfPresent(Bool.self, forKey: .separateStems) ?? defaults.separateStems
        // Speakers added in a later version start at 0 dB; the saved ones keep their levels.
        let levels = try values.decodeIfPresent([Double].self, forKey: .speakerLevels) ?? []
        speakerLevels = levels.count <= defaults.speakerLevels.count
            ? levels + defaults.speakerLevels.dropFirst(levels.count)
            : defaults.speakerLevels
        outputDeviceUID = try values.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        previousSystemOutputUID = try values.decodeIfPresent(String.self, forKey: .previousSystemOutputUID)
    }

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return Preferences() }
        return saved
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
