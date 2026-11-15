import Foundation
import CompassCore

/// Where recordings live on disk. The voice services name files by recording; History matches a memo
/// to its file by creation time (the moment recording stopped) within a second.
enum MemoAudio {
    static let extensions: Set<String> = ["m4a", "caf", "wav", "aac", "mp4"]

    /// Folders the app may keep audio in (own sandbox and the App Group container).
    static var directories: [URL] {
        let fm = FileManager.default
        var dirs: [URL] = []
        for base in [fm.urls(for: .documentDirectory, in: .userDomainMask).first,
                     fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                     SharedStorage.directory as URL?] {
            guard let base else { continue }
            dirs.append(base)
            dirs.append(base.appendingPathComponent("Compass"))
            dirs.append(base.appendingPathComponent("Compass/Audio"))
            dirs.append(base.appendingPathComponent("Audio"))
            dirs.append(base.appendingPathComponent("Recordings"))
            dirs.append(base.appendingPathComponent("Compass/Recordings"))
        }
        return dirs
    }

    /// Where recordings from the user's other devices land when they sync down.
    static var syncedAudioDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Compass/Audio", isDirectory: true)
    }

    static func allFiles() -> [URL] {
        let fm = FileManager.default
        var seen = Set<String>()
        var files: [URL] = []
        for dir in directories {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]) else { continue }
            for url in items where extensions.contains(url.pathExtension.lowercased()) && seen.insert(url.path).inserted {
                files.append(url)
            }
        }
        return files
    }

    /// The file recorded at `createdAt` (±2 s on its modification date), if it is on this device.
    static func fileURL(createdAt: Date) -> URL? {
        allFiles().min { distance($0, createdAt) < distance($1, createdAt) }.flatMap { distance($0, createdAt) <= 2 ? $0 : nil }
    }

    private static func distance(_ url: URL, _ date: Date) -> TimeInterval {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let d = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
        return abs(d.timeIntervalSince(date))
    }

    /// Remove the audio of a deleted day (E4).
    static func deleteFiles(for day: Day) {
        var moments = day.notes.compactMap { $0.isSpoken ? $0.createdAt : nil }
        moments += day.reflectionVersions.compactMap { $0.duration != nil ? $0.createdAt : nil }
        if let i = day.intention, i.duration != nil { moments.append(i.createdAt) }
        for m in moments {
            if let url = fileURL(createdAt: m) { try? FileManager.default.removeItem(at: url) }
        }
    }
}
