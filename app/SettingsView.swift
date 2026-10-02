import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case sound, speakers, headTracking, permissions, about

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .sound: "settings.sound"
        case .speakers: "settings.speakers"
        case .headTracking: "settings.tracking"
        case .permissions: "settings.permissions"
        case .about: "settings.about"
        }
    }

    var symbol: String {
        switch self {
        case .sound: "speaker.wave.2"
        case .speakers: "hifispeaker.2"
        case .headTracking: "face.smiling"
        case .permissions: "hand.raised"
        case .about: "info.circle"
        }
    }
}

/// Settings grouped by category: the categories on the left, the chosen one on the right.
struct SettingsView: View {
    static let windowID = "settings"

    @ObservedObject var model: Model
    /// Not observed here: only the panes that show live values redraw with them.
    let live: LiveState
    @AppStorage("settingsPane") private var pane = SettingsPane.sound.rawValue

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch SettingsPane(rawValue: pane) ?? .sound {
            case .sound: SoundPane(model: model)
            case .speakers: SpeakersPane(model: model, live: live)
            case .headTracking: HeadTrackingPane(model: model, live: live)
            case .permissions: PermissionsPane()
            case .about: AboutPane()
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .showsInDock()
    }

    private var selection: Binding<SettingsPane?> {
        Binding(get: { SettingsPane(rawValue: pane) }, set: { pane = ($0 ?? .sound).rawValue })
    }
}

private struct SoundPane: View {
    @ObservedObject var model: Model

    var body: some View {
        Form {
            Section {
                Picker("settings.sound.output", selection: $model.outputDeviceID) {
                    ForEach(model.outputDevices) { Text(verbatim: $0.name).tag($0.id) }
                }
                if model.driverDeviceID == 0 {
                    Text("notice.noDriver").foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(isOn: $model.fillSpeakers) {
                    Text("settings.sound.fill")
                    Text("settings.sound.fill.detail")
                }
                Toggle(isOn: $model.separateStems) {
                    Text(Image(systemName: "sparkles")).foregroundStyle(AIStyle.gradient) + Text(verbatim: " ") + Text("settings.sound.separate")
                    separationDetail
                }
                .disabled(!model.fillSpeakers)
                LabeledContent("settings.sound.roomReverb \(Int((model.roomReverb * 100).rounded()))") {
                    Slider(value: $model.roomReverb, in: 0...1)
                }
            }
            Section("settings.effects") {
                LabeledContent {
                    Slider(value: $model.gain, in: 0...12, step: 0.5)
                } label: {
                    Text("settings.effects.gain \(model.gain, specifier: "%+.1f")")
                    Text("settings.effects.gain.detail")
                }
                Toggle(isOn: $model.stabilizer) {
                    Text("settings.effects.stabilizer")
                    Text("settings.effects.stabilizer.detail")
                }
                Toggle(isOn: $model.limiter) {
                    Text("settings.effects.limiter")
                    Text("settings.effects.limiter.detail")
                }
            }
            Section("settings.tone") {
                Toggle("settings.tone.enabled", isOn: $model.toneShaping)
                BandControls(title: "settings.tone.upper", band: $model.upperBand, range: 1000...12000)
                BandControls(title: "settings.tone.lower", band: $model.lowerBand, range: 150...1500)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.sound.title)
    }

    private var separationDetail: Text {
        switch model.separation {
        case .off, .on: Text("settings.sound.separate.detail")
        case .downloading(let fraction): Text("settings.sound.separate.downloading \(Int(fraction * 100))")
        case .starting: Text("settings.sound.separate.starting")
        case .failed(let message): Text(verbatim: message).foregroundStyle(.orange)
        }
    }
}

private struct SpeakersPane: View {
    @ObservedObject var model: Model
    @ObservedObject var live: LiveState

    var body: some View {
        Form {
            Section {
                ForEach(Array(SurroundChannel.allCases.enumerated()), id: \.offset) { index, channel in
                    HStack(spacing: 12) {
                        Text(verbatim: channel.title).frame(width: 90, alignment: .leading)
                        LevelBar(level: live.speakerLevels.first { $0.id == index }?.level ?? 0)
                        Slider(value: $model.speakerLevels[index], in: -12...12, step: 0.5)
                            .frame(width: 140)
                        Text("settings.speakers.level \(model.speakerLevels[index], specifier: "%+.1f")")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                        Toggle("settings.speakers.solo", isOn: Binding(
                            get: { model.soloSpeaker == index },
                            set: { model.soloSpeaker = $0 ? index : nil }
                        ))
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(Text("settings.speakers.solo.help"))
                        Toggle("settings.speakers.mute", isOn: Binding(
                            get: { model.mutedSpeakers.contains(index) },
                            set: { muted in
                                if muted {
                                    model.mutedSpeakers.insert(index)
                                } else {
                                    model.mutedSpeakers.remove(index)
                                }
                            }
                        ))
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(Text("settings.speakers.mute.help"))
                    }
                }
                Button("settings.speakers.reset") { model.resetSpeakerLevels() }
            }
            Section("settings.speakers.deviceChannels") {
                ForEach(live.deviceLevels) { channel in
                    LabeledContent {
                        LevelBar(level: channel.level)
                    } label: {
                        Text(verbatim: channel.name)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.speakers.title)
    }
}

private struct HeadTrackingPane: View {
    @ObservedObject var model: Model
    @ObservedObject var live: LiveState

    var body: some View {
        Form {
            if !model.cameraAllowed {
                Section {
                    Text("settings.tracking.noCamera").fixedSize(horizontal: false, vertical: true)
                    Button("permission.openSettings") { NSWorkspace.shared.open(Permission.camera.settings) }
                }
            }
            Section {
                Toggle("settings.tracking.enabled", isOn: $model.tracking)
                LabeledContent("settings.tracking.camera") { Text(verbatim: camera) }
                LabeledContent("settings.tracking.turn") {
                    Text("settings.tracking.degrees \(Int(live.yaw.rounded()))").monospacedDigit()
                }
                Button("settings.tracking.center") { model.recenter() }
            }
            .disabled(!model.cameraAllowed)
            Section {
                Picker(selection: $model.trackingRate) {
                    ForEach(HeadTracker.frameRates, id: \.self) { rate in
                        Text("settings.tracking.rate.value \(rate)").tag(rate)
                    }
                } label: {
                    Text("settings.tracking.rate")
                    Text("settings.tracking.rate.detail")
                }
                .pickerStyle(.segmented)
                LabeledContent {
                    Slider(value: $model.turnGain, in: 1...3)
                } label: {
                    Text("settings.tracking.amplification \(model.turnGain, specifier: "%.1f")")
                    Text("settings.tracking.amplification.detail")
                }
            }
            .disabled(!model.cameraAllowed)
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.headTracking.title)
    }

    private var camera: String {
        if !model.cameraAllowed { return String(localized: "status.tracking.noCamera") }
        if !model.enabled { return String(localized: "settings.tracking.camera.appOff") }
        if !model.tracking { return String(localized: "status.tracking.off") }
        if let error = model.trackingError { return error }
        return model.faceFound
            ? String(localized: "settings.tracking.camera.face \(live.framesPerSecond)")
            : String(localized: "settings.tracking.camera.noFace")
    }
}

private struct PermissionsPane: View {
    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases, id: \.self) { permission in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: permission.title).font(.headline)
                        Text(verbatim: permission.reason).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("settings.permissions.detail").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.permissions.title)
    }
}

private struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    Text("app.name").font(.title2.bold())
                    Text("about.version \(version)").foregroundStyle(.secondary)
                    Text("about.summary").multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Link("about.repository", destination: AppLinks.repository)
                        Link("about.support", destination: AppLinks.support)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section("about.notices") {
                notice(
                    title: "about.notice.driver.title",
                    body: "about.notice.driver.body",
                    links: [("about.notice.driver.source", AppLinks.driverSource), ("about.notice.driver.license", AppLinks.driverLicense)]
                )
                notice(
                    title: "about.notice.room.title",
                    body: "about.notice.room.body",
                    links: [("about.notice.room.source", AppLinks.roomSource), ("about.notice.room.license", AppLinks.roomLicense)]
                )
                notice(
                    title: "about.notice.separation.title",
                    body: "about.notice.separation.body",
                    links: [("about.notice.separation.source", AppLinks.separationSource), ("about.notice.mit", AppLinks.mitLicense)]
                )
                Text("about.copyright").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsPane.about.title)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private func notice(title: LocalizedStringKey, body: LocalizedStringKey, links: [(LocalizedStringKey, URL)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                ForEach(links.indices, id: \.self) { index in
                    Link(links[index].0, destination: links[index].1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
