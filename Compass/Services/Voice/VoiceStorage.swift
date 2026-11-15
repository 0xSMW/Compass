import Foundation

/// Where memos live: `Application Support/Compass/Audio/<id>.m4a`, on this iPhone only.
/// Only text ever leaves the phone (and only with the cloud switch on).
///
/// Naming: a `Recording.fileName` is `<recording id>.m4a`. A `Note` made from a recording keeps the
/// recording's id, so its audio is `<note id>.m4a` (B7 "why" plays back on hard days). A `Reflection`
/// stores its file in `audioFileName`.
struct VoiceStorage: Sendable {
    /// Shared on purpose: a stateless view of one folder on disk (no flow state), the same for every model.
    static let shared = VoiceStorage()

    /// Below this much free space a recording can't start (I4 "Your iPhone is full").
    static let minimumFreeBytes: Int64 = 50_000_000

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compass/Audio", isDirectory: true)
    }

    func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(for fileName: String) -> URL {
        ensureDirectory()
        return directory.appendingPathComponent(fileName, isDirectory: false)
    }

    func fileName(for id: UUID) -> String { "\(id.uuidString).m4a" }

    func exists(_ fileName: String?) -> Bool {
        guard let fileName else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
    }

    /// Remove a recording for good: here, and (through sync's audio tombstones) from iCloud and the
    /// user's other devices, which never copy it back.
    func delete(_ fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        AudioTombstoneLog.shared.record(fileName)
    }

    /// Free space for "important" data on the volume that holds the audio folder.
    var availableBytes: Int64? {
        ensureDirectory()
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    var hasRoomForRecording: Bool {
        guard let free = availableBytes else { return true }
        return free >= Self.minimumFreeBytes
    }
}
