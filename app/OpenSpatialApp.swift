import SwiftUI

@main
struct OpenSpatialApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            StatusPopover(model: model)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Window("settings.title", id: SettingsView.windowID) {
            SettingsView(model: model, live: model.live)
        }
        .defaultSize(width: 720, height: 540)

        Window("stage.title", id: SoundStage.windowID) {
            SoundStage(model: model, live: model.live)
                .showsInDock()
        }
        .defaultSize(width: 900, height: 640)
    }

    /// The logo as a template image, so the menu bar tints it for light, dark and highlighted states.
    private static let menuBarIcon: NSImage = {
        let image = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg").flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()
}

/// The app lives in the menu bar; it shows in the Dock and the app switcher only while one of its windows is open.
@MainActor
private enum DockPresence {
    static var openWindows = 0
}

extension View {
    func showsInDock() -> some View {
        onAppear {
            DockPresence.openWindows += 1
            NSApplication.shared.setActivationPolicy(.regular)
        }
        .onDisappear {
            DockPresence.openWindows -= 1
            if DockPresence.openWindows == 0 {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }
}

/// Addresses the app links to.
enum AppLinks {
    static let repository = URL(string: "https://github.com/dortanes/openspatial")!
    static let support = URL(string: "https://ko-fi.com/dortanes")!
    static let driverSource = URL(string: "https://github.com/ExistentialAudio/BlackHole")!
    static let driverLicense = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    static let roomSource = URL(string: "https://sofacoustics.org/data/database/thk/")!
    static let roomLicense = URL(string: "https://creativecommons.org/licenses/by-sa/3.0/")!
    /// The Neural Engine version of the separation model, built by separation/export.py.
    static let separationModel = URL(string: "https://github.com/dortanes/openspatial/releases/download/htdemucs-vocals-1/HTDemucsVocals.mlpackage.zip")!
    static let separationSource = URL(string: "https://github.com/facebookresearch/demucs")!
    static let mitLicense = URL(string: "https://opensource.org/license/mit")!
    static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let cameraSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
}
