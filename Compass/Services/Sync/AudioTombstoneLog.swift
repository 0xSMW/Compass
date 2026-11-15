import Foundation
import CompassCore

/// Recordings deleted on this device or reported deleted by another one
/// (`Application Support/Compass/audio-tombstones.json`). `VoiceStorage.delete` records every deletion
/// (E4 delete, evening redo, discarded takes); sync carries the list in this device's envelope, removes
/// those files from iCloud and never copies them back. Thread-safe: deletions happen on any queue.
final class AudioTombstoneLog: @unchecked Sendable {
    static let shared = AudioTombstoneLog()

    private let lock = NSLock()
    private var entries: [String: Date]?
    private let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compass/audio-tombstones.json")
    }

    /// Every tombstone, sorted by name.
    var all: [AudioTombstone] {
        lock.withLock { loaded().map { AudioTombstone(name: $0.key, deletedAt: $0.value) }.sorted { $0.name < $1.name } }
    }

    func record(_ name: String, at date: Date = Date()) {
        lock.withLock {
            var e = loaded()
            e[name] = max(e[name] ?? date, date)
            entries = e
            persist(e)
        }
    }

    /// Take in what the merge knows (other devices' deletions). Saves only when something is new.
    func adopt(_ tombstones: [AudioTombstone]) {
        lock.withLock {
            var e = loaded()
            var changed = false
            for t in tombstones where (e[t.name] ?? .distantPast) < t.deletedAt {
                e[t.name] = t.deletedAt
                changed = true
            }
            guard changed else { return }
            entries = e
            persist(e)
        }
    }

    /// After a wipe: only deletions from after it matter.
    func reset(keeping tombstones: [AudioTombstone] = []) {
        lock.withLock {
            let e = Dictionary(tombstones.map { ($0.name, $0.deletedAt) }, uniquingKeysWith: max)
            entries = e
            persist(e)
        }
    }

    private func loaded() -> [String: Date] {
        if let entries { return entries }
        let list = (try? Data(contentsOf: url)).flatMap { try? JSONFileStore.decoder().decode([AudioTombstone].self, from: $0) } ?? []
        let e = Dictionary(list.map { ($0.name, $0.deletedAt) }, uniquingKeysWith: max)
        entries = e
        return e
    }

    private func persist(_ e: [String: Date]) {
        let list = e.map { AudioTombstone(name: $0.key, deletedAt: $0.value) }.sorted { $0.name < $1.name }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONFileStore.encoder().encode(list) { try? data.write(to: url, options: .atomic) }
    }
}
