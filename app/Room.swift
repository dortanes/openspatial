import Foundation

/// Where the speakers stand: rooms of the WDR broadcast studios measured with a Neumann KU100 dummy head, or the
/// same head with no room around it. room/export.py writes each one's responses.
enum Room: String, CaseIterable, Codable {
    case none
    case controlRoom1
    case controlRoom7
    case smallHall
    case largeHall

    static let standard = Room.controlRoom1

    /// The name of its response files.
    var file: String {
        switch self {
        case .none: "free"
        case .controlRoom1: "cr1"
        case .controlRoom7: "cr7"
        case .smallHall: "sbs"
        case .largeHall: "lbs"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .none: "room.none"
        case .controlRoom1: "room.controlRoom1"
        case .controlRoom7: "room.controlRoom7"
        case .smallHall: "room.smallHall"
        case .largeHall: "room.largeHall"
        }
    }

    /// SHA-256 of the published archive for a room downloaded on first use; nil for one inside the app.
    var digest: String? {
        switch self {
        case .none, .controlRoom1: nil
        case .controlRoom7: "0a05ffb76753a6ecc9af971693262c7d3f9e4f18c86cec9b8f67026d251f510d"
        case .smallHall: "ff935f3114a727bb2f3b21676c343831d92081831e7ac5926ed045ef99bd941d"
        case .largeHall: "922571135ba80dd726baf8825d1b7126b8af2a02dc3628d67f22a35d73ebad62"
        }
    }

    /// Width, length and height in metres, approximate, for the 3D view; nil without a room. The studios'
    /// dimensions aren't published: these are typical of their kind, with the large hall seating 800.
    var size: SIMD3<Float>? {
        switch self {
        case .none: nil
        case .controlRoom1: [7, 7, 3]
        case .controlRoom7: [6, 8, 3.2]
        case .smallHall: [14, 20, 8]
        case .largeHall: [24, 36, 14]
        }
    }

    /// Where its responses are: inside the app, or among the downloads.
    var folder: URL? {
        digest == nil ? Bundle.main.resourceURL : Download.folder.appending(path: "Rooms/\(file)")
    }

    var isAvailable: Bool {
        guard let folder else { return false }
        return FileManager.default.fileExists(atPath: folder.appending(path: "\(file).json").path)
    }

    /// Downloads the room's responses into `folder`.
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let digest, let folder else { return }
        let staging = Download.folder.appending(path: "Rooms/.\(file)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Download.unpack(
            AppLinks.rooms.appending(path: "\(file).zip"),
            digest: digest,
            into: staging,
            damaged: String(localized: "error.room.damaged"),
            progress: progress
        )
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: staging, to: folder)
    }

    /// Reads and transforms the room's responses; takes a moment for a hall, so call it away from the main thread.
    func load() throws -> RoomFilters {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        return RoomFilters(try RoomResponses.load(file, from: folder))
    }
}
