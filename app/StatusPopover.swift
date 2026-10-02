import SwiftUI

/// The panel that opens from the menu bar icon: what is playing, an on/off switch and the way to settings.
struct StatusPopover: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("app.name").font(.headline)
                Spacer()
                Toggle("popover.enabled", isOn: $model.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 8) {
                status(headphones, symbol: "headphones")
                HStack {
                    if separating {
                        Label {
                            Text("status.source.stereoSeparated")
                        } icon: {
                            Image(systemName: "sparkles").foregroundStyle(AIStyle.gradient)
                        }
                    } else {
                        status(source, symbol: "waveform")
                    }
                    Spacer()
                    Toggle("settings.sound.separate", isOn: $model.separateStems)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(!model.enabled || !model.fillSpeakers)
                }
                HStack {
                    status(tracking, symbol: "face.smiling")
                    Spacer()
                    Toggle("popover.tracking", isOn: $model.tracking)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .disabled(!model.enabled || !model.cameraAllowed)
                }
            }
            if let notice {
                Text(verbatim: notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.driverDeviceID == 0 {
                Button("popover.installDriver") { Task { await model.installDriver() } }
                    .disabled(model.installingDriver)
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    open(SettingsView.windowID)
                } label: {
                    Label("popover.settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                Button {
                    open(SoundStage.windowID)
                } label: {
                    Label("popover.stage", systemImage: "cube.transparent").frame(maxWidth: .infinity)
                }
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("popover.quit", systemImage: "power").labelStyle(.iconOnly)
                }
                .help("popover.quit")
            }
            .lineLimit(1)
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func open(_ window: String) {
        dismiss()
        openWindow(id: window)
        NSApplication.shared.activate()
    }

    private func status(_ text: String, symbol: String) -> some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }

    private var headphones: String {
        model.outputDeviceName.map { String(localized: "status.headphones \($0)") } ?? String(localized: "status.noHeadphones")
    }

    private var source: String {
        guard model.enabled else { return String(localized: "status.off") }
        return switch model.inputLayout {
        case .silent: String(localized: "status.source.silent")
        case .stereo: model.fillSpeakers ? String(localized: "status.source.stereoSpread") : String(localized: "status.source.stereo")
        case .fivePointOne: model.fillSpeakers ? String(localized: "status.source.fivePointOneFilled") : String(localized: "status.source.fivePointOne")
        case .sevenPointOne: String(localized: "status.source.sevenPointOne")
        }
    }

    /// Whether the AI model is splitting what plays right now.
    private var separating: Bool {
        model.enabled && model.fillSpeakers && model.separation == .on && model.inputLayout == .stereo
    }

    private var tracking: String {
        if !model.cameraAllowed { return String(localized: "status.tracking.noCamera") }
        if !model.enabled || !model.tracking { return String(localized: "status.tracking.off") }
        if let error = model.trackingError { return error }
        return model.faceFound ? String(localized: "status.tracking.following") : String(localized: "status.tracking.searching")
    }

    /// The one thing standing between the apps and the listener, if any.
    private var notice: String? {
        if let error = model.audioError { return error }
        if model.driverDeviceID == 0 { return model.driverError ?? String(localized: "notice.noDriver") }
        if !model.systemOutputIsDriver { return String(localized: "notice.outputNotSet") }
        return nil
    }
}
