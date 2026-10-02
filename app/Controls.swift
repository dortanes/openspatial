import SwiftUI

/// A level meter on a decibel scale from -60 dB to full scale, drawn without animation so it follows the signal.
struct LevelBar: View {
    /// Linear peak level, 0 to 1.
    let level: Double

    private var fraction: Double {
        guard level > 0 else { return 0 }
        return min(max((20 * log10(level) + 60) / 60, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
        .transaction { $0.animation = nil }
    }
}

/// Marks what an AI model does, wherever it appears.
enum AIStyle {
    static let gradient = LinearGradient(colors: [.purple, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct EQBand: Equatable, Codable {
    var frequency: Double
    var gain: Double
}

struct BandControls: View {
    let title: LocalizedStringKey
    @Binding var band: EQBand
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent {
            // Frequency moves on a log scale so each octave takes the same slider length.
            Slider(
                value: Binding(get: { log2(band.frequency) }, set: { band.frequency = pow(2, $0) }),
                in: log2(range.lowerBound)...log2(range.upperBound)
            )
        } label: {
            Text(title) + Text(verbatim: " " + Self.format(band.frequency))
        }
        LabeledContent("settings.tone.gain \(band.gain, specifier: "%+.0f")") {
            Slider(value: $band.gain, in: -10...10, step: 1)
        }
    }

    private static func format(_ frequency: Double) -> String {
        frequency >= 1000
            ? String(localized: "settings.tone.kilohertz \(frequency / 1000, specifier: "%.1f")")
            : String(localized: "settings.tone.hertz \(Int(frequency.rounded()))")
    }
}
