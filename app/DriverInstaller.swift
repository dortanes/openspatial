import Foundation

struct DriverError: LocalizedError {
    let errorDescription: String?
}

/// Installs the audio driver the app carries into the system's audio plug-ins, replacing one of another build.
enum DriverInstaller {
    private static let name = "OpenSpatial.driver"
    private static let plugIns = FileManager.default.urls(for: .libraryDirectory, in: .localDomainMask)[0]
        .appending(path: "Audio/Plug-Ins/HAL", directoryHint: .isDirectory)
    private static let carried = Bundle.main.url(forResource: "OpenSpatial", withExtension: "driver")

    enum Pending {
        case install
        case update
    }

    /// What the system needs: the driver installed, or replaced by the build the app carries; nil when up to date.
    static var pending: Pending? {
        guard let carried else { return nil }
        let installed = build(of: plugIns.appending(path: name))
        guard installed != build(of: carried) else { return nil }
        return installed == nil ? .install : .update
    }

    /// Asks for an administrator's password, copies the driver and restarts Core Audio so it loads.
    /// Throws `CancellationError` when the password prompt is dismissed.
    static func install() async throws {
        guard let carried else { throw DriverError(errorDescription: String(localized: "error.driverMissing")) }
        let installed = plugIns.appending(path: name)
        let command = [
            "mkdir -p \(quoted(plugIns.path))",
            "rm -rf \(quoted(installed.path))",
            "cp -R \(quoted(carried.path)) \(quoted(plugIns.path))",
            "killall coreaudiod",
        ].joined(separator: " && ")
        let script = "do shell script \(appleScriptString(command)) with prompt "
            + "\(appleScriptString(String(localized: "driver.install.prompt"))) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else if message.contains("(-128)") {
                    // AppleScript's "User canceled" error.
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: DriverError(errorDescription: message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func build(of driver: URL) -> String? {
        NSDictionary(contentsOf: driver.appending(path: "Contents/Info.plist"))?["CFBundleVersion"] as? String
    }

    /// A shell word holding `text` as is.
    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An AppleScript string literal holding `text` as is.
    private static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
