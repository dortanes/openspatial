import AVFoundation
import AppKit

/// Access to devices macOS guards.
enum Permission: CaseIterable {
    /// Required: apps' sound arrives through the driver, which macOS treats as a microphone.
    case microphone
    /// Optional: head tracking reads the head turn from the camera.
    case camera

    var title: String {
        switch self {
        case .microphone: String(localized: "permission.microphone")
        case .camera: String(localized: "permission.camera")
        }
    }

    var reason: String {
        switch self {
        case .microphone: String(localized: "permission.microphone.reason")
        case .camera: String(localized: "permission.camera.reason")
        }
    }

    var settings: URL {
        switch self {
        case .microphone: AppLinks.microphoneSettings
        case .camera: AppLinks.cameraSettings
        }
    }

    var isAllowed: Bool {
        AVCaptureDevice.authorizationStatus(for: mediaType) == .authorized
    }

    private var mediaType: AVMediaType {
        switch self {
        case .microphone: .audio
        case .camera: .video
        }
    }

    /// Asks macOS for access if it hasn't asked yet; returns whether access is allowed.
    func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: mediaType)
    }

    /// Explains why the app can't run without this access, offers the privacy settings and quits.
    @MainActor
    func explainAndQuit() {
        let alert = NSAlert()
        alert.messageText = String(localized: "permission.alert.title")
        alert.informativeText = [reason, String(localized: "permission.alert.detail")].joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "permission.openSettings"))
        alert.addButton(withTitle: String(localized: "permission.alert.quit"))
        NSApplication.shared.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(settings)
        }
        NSApplication.shared.terminate(nil)
    }
}
