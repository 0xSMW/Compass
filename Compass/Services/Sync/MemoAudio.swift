import Foundation
import CompassCore

/// The audio side of sync and History, on top of the voice services' `VoiceStorage`
/// (`Application Support/Compass/Audio`): a reflection's file is `audioFileName`, a spoken note's file is
/// `<note id>.m4a`. Files are write-once with unique names, so they sync without conflicts.
enum MemoAudio {
    static let extensions: Set<String> = ["m4a", "caf", "wav", "aac"]

    /// Recordings from the user's other devices land in the same folder, so playback finds them.
    static var syncedAudioDirectory: URL { VoiceStorage.shared.directory }

    /// Every recording on this device.
    static func allFiles() -> [URL] {
        let dir = VoiceStorage.shared.directory
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { extensions.contains($0.pathExtension.lowercased()) }
    }

    /// Names of every recording on this device.
    static func allNames() -> Set<String> { Set(allFiles().map(\.lastPathComponent)) }

    /// Remove a local copy because a merge says it's gone (deleted or wiped on another device). Unlike
    /// `VoiceStorage.delete`, this records no new tombstone: the deletion is already known.
    static func removeLocalCopy(_ name: String) {
        try? FileManager.default.removeItem(at: VoiceStorage.shared.directory.appendingPathComponent(name))
    }

    /// The file behind a spoken note (`<note id>.m4a`).
    static func fileName(for note: Note) -> String? {
        note.isSpoken ? VoiceStorage.shared.fileName(for: note.id) : nil
    }

    /// Every audio file a day refers to.
    static func fileNames(for day: Day) -> [String] {
        day.reflectionVersions.compactMap(\.audioFileName) + day.notes.compactMap(fileName(for:))
    }

    /// E5: a set-aside version becomes a note (`Day.supersededNoteID`); give that note its own copy of
    /// the recording under the note naming, so it stays playable everywhere. The original stays too.
    static func keepRecordings(of versions: [Reflection]) {
        let storage = VoiceStorage.shared
        for r in versions {
            guard let file = r.audioFileName, storage.exists(file) else { continue }
            let target = storage.fileName(for: Day.supersededNoteID(for: r))
            guard !storage.exists(target) else { continue }
            try? FileManager.default.copyItem(at: storage.url(for: file), to: storage.url(for: target))
        }
    }

    /// E4: remove the recordings of a deleted day.
    static func deleteFiles(for day: Day) {
        for name in fileNames(for: day) { VoiceStorage.shared.delete(name) }
    }
}
