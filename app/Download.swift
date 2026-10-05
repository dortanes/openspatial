import CryptoKit
import Foundation
import os

/// Data too large to ship inside the app, downloaded on first use from the repository's releases.
enum Download {
    /// Where downloaded data lives.
    static let folder = URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "OpenSpatial")

    /// Downloads the zip archive at `url`, checks it against its pinned SHA-256 `digest` and unpacks it into
    /// `destination`, an existing folder. Throws `damaged` as the message when the archive doesn't match or
    /// doesn't unpack. Reports download progress from 0 to 1 at most once per percent.
    static func unpack(
        _ url: URL,
        digest: String,
        into destination: URL,
        damaged: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let archive = destination.appending(path: UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        let running = OSAllocatedUnfairLock<URLSessionDownloadTask?>(initialState: nil)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var observation: NSKeyValueObservation?
                let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                    observation?.invalidate()
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard error == nil, let file, status == 200 else {
                        continuation.resume(throwing: error ?? ModelError(message: HTTPURLResponse.localizedString(forStatusCode: status)))
                        return
                    }
                    // The system deletes the downloaded file once this handler returns.
                    do {
                        try FileManager.default.moveItem(at: file, to: archive)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let percent = OSAllocatedUnfairLock(initialState: -1)
                observation = task.progress.observe(\.fractionCompleted) { reported, _ in
                    let now = Int(reported.fractionCompleted * 100)
                    if percent.withLock({ last in defer { last = now }; return last != now }) {
                        progress(Double(now) / 100)
                    }
                }
                running.withLock { $0 = task }
                task.resume()
            }
        } onCancel: {
            running.withLock { $0?.cancel() }
        }
        guard try sha256(of: archive) == digest else {
            throw ModelError(message: damaged)
        }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, destination.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw ModelError(message: damaged)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
