import SwiftUI

/// A small window for the driver install: first it says what is about to happen, since macOS then asks for a
/// password on its own; then it stays up while the driver installs and Core Audio restarts, so the wait doesn't
/// look like a hang.
@MainActor
enum DriverSetupPanel {
    private static var panel: NSPanel?
    /// The listener's pending answer; taken by the first click, so a double click answers once.
    private static var answer: CheckedContinuation<Bool, Never>?

    /// Explains the coming install and waits for the listener's answer: true to install now.
    static func ask(_ pending: DriverInstaller.Pending) async -> Bool {
        await withCheckedContinuation { continuation in
            answer = continuation
            present(WelcomeView(pending: pending) { install in
                guard let waiting = answer else { return }
                answer = nil
                if !install {
                    hide()
                }
                waiting.resume(returning: install)
            })
            NSApplication.shared.activate()
            panel?.makeKeyAndOrderFront(nil)
            panel?.orderFrontRegardless()
        }
    }

    static func showProgress() {
        present(InstallingView())
        panel?.orderFrontRegardless()
    }

    static func hide() {
        panel?.close()
        panel = nil
    }

    private static func present(_ view: some View) {
        let content = NSHostingView(rootView: view)
        let panel = panel ?? NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = String(localized: "app.name")
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.isReleasedWhenClosed = false
        // A menu bar app is rarely active at launch, and a panel hides whenever its app isn't.
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.center()
        self.panel = panel
    }
}

private struct WelcomeView: View {
    let pending: DriverInstaller.Pending
    let answer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 6) {
                Text(pending == .install ? "driver.welcome.title" : "driver.update.title")
                    .font(.title3.bold())
                Text(pending == .install ? "driver.welcome.detail" : "driver.update.detail")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            HStack {
                Button("driver.later") { answer(false) }
                    .keyboardShortcut(.cancelAction)
                Button("popover.installDriver") { answer(true) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 360)
    }
}

private struct InstallingView: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("driver.installing")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 360)
    }
}
