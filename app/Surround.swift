import CoreAudioTypes
import Foundation

/// The 7.1 loudspeakers and the subwoofer that carries everything below the crossover.
enum SurroundChannel: CaseIterable {
    case frontLeft, frontRight, center, backLeft, backRight, sideLeft, sideRight, subwoofer

    var title: String {
        switch self {
        case .frontLeft: String(localized: "speaker.frontLeft")
        case .frontRight: String(localized: "speaker.frontRight")
        case .center: String(localized: "speaker.center")
        case .backLeft: String(localized: "speaker.backLeft")
        case .backRight: String(localized: "speaker.backRight")
        case .sideLeft: String(localized: "speaker.sideLeft")
        case .sideRight: String(localized: "speaker.sideRight")
        case .subwoofer: String(localized: "speaker.subwoofer")
        }
    }

    /// Clockwise degrees from straight ahead; side and back angles sit inside the 7.1 recommended ranges.
    /// The subwoofer stands in front, as hearing can't place sound below the crossover.
    var azimuth: Double {
        switch self {
        case .frontLeft: -30
        case .frontRight: 30
        case .center, .subwoofer: 0
        case .backLeft: -145
        case .backRight: 145
        case .sideLeft: -100
        case .sideRight: 100
        }
    }

    /// Gains into the left and right headphone when the speakers fold down to plain stereo.
    var stereoDownmix: (left: Float, right: Float) {
        switch self {
        case .frontLeft: (1, 0)
        case .frontRight: (0, 1)
        case .center, .subwoofer: (0.707, 0.707)
        case .backLeft, .sideLeft: (0.707, 0)
        case .backRight, .sideRight: (0, 0.707)
        }
    }
}

/// The speaker labels the driver reports, which decide where apps put the side and back pairs of 7.1.
/// Mac apps follow Core Audio's 7.1, where surround is the side pair and rear surround the back pair;
/// Wine knows only surround and surround direct, which it takes as the Windows back and side pairs.
enum ChannelLayout: String, CaseIterable, Codable {
    case mac, windows

    var labels: [AudioChannelLabel] {
        let fronts = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen]
        return switch self {
        case .mac: fronts + [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight]
        case .windows: fronts + [kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround, kAudioChannelLabel_LeftSurroundDirect, kAudioChannelLabel_RightSurroundDirect]
        }
    }
}

/// What the capture device currently carries, as the speaker layout it fills.
enum InputLayout: Int {
    case silent, stereo, fivePointOne, sevenPointOne
}
