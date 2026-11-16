import Foundation
import CompassCore

extension AppModel {
    /// The one cloud switch: summaries and step ideas. Off = plain transcripts and no ideas.
    func setCloudHelp(_ on: Bool) {
        updateSettings { $0.cloudAssist = on }
        if let http = cloud as? HTTPCloudAssist { http.switchOn = on }
        if let fake = cloud as? FakeCloudAssist { fake.isEnabled = on }
    }

    /// H2: everything goes — the snapshot, every recording, the widget's copy, sync bookkeeping — on this
    /// iPhone and in iCloud. Screenshot runs only reset the in-memory model.
    func eraseEverything() {
        if fixture == nil, !launch.tapThrough {
            LiveSync.wipeEverywhere(at: now)
            // No queued write may put the store file back after the eraser removes it.
            saves.discardPendingWrites()
            DataEraser.eraseLocalData()
        }
        historySelection.day = nil
        historySelection.weekEnd = nil
        historySelection.goalID = nil
        deleteEverything()
    }
}

/// Removes everything Compass wrote on this device. Audio is wherever the voice services keep it
/// (sandbox Documents / Application Support / Caches / tmp, or the App Group container), so every
/// Compass-owned location is cleared rather than guessing file names.
enum DataEraser {
    static func eraseLocalData() {
        let fm = FileManager.default
        var dirs: [URL] = []
        for d in [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory, .cachesDirectory] {
            if let url = fm.urls(for: d, in: .userDomainMask).first { dirs.append(url) }
        }
        dirs.append(fm.temporaryDirectory)
        for dir in dirs { removeContents(of: dir) }
        // The App Group container is shared with the widget: remove Compass's folder only.
        if let group = fm.containerURL(forSecurityApplicationGroupIdentifier: SharedStorage.appGroup) {
            for name in ["Compass", "Audio", "Recordings"] {
                try? fm.removeItem(at: group.appendingPathComponent(name))
            }
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            let keep = UserDefaults.standard.object(forKey: SoundSetting.key)
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            if let keep { UserDefaults.standard.set(keep, forKey: SoundSetting.key) }
        }
    }

    private static func removeContents(of dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }
}

/// "Export everything": one zip, "Compass export <date>.zip", holding a readable JSON file of the whole
/// snapshot and an Audio folder with every recording on the device. Built in a private temporary
/// folder (`root`) that is removed when the share sheet finishes, when it is dismissed, and at launch.
/// The zip comes from `NSFileCoordinator`'s `.forUploading` read (no third-party code). If zipping
/// fails, the loose files are shared instead, from the same temporary folder.
enum DataExport {
    /// Everything an export writes lives here and nowhere else, so cleaning up never touches real data.
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CompassExport", isDirectory: true)
    }

    /// Build the export off the main thread.
    static func prepare(_ snapshot: CompassSnapshot, now: Date = Date()) async -> [URL] {
        let audio = MemoAudio.allFiles()
        return await Task.detached(priority: .userInitiated) {
            makeExport(snapshot, audio: audio, now: now)
        }.value
    }

    static func makeExport(_ snapshot: CompassSnapshot, audio: [URL], now: Date = Date()) -> [URL] {
        cleanUp()
        let fm = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let stamp = formatter.string(from: now)
        let name = "Compass export \(stamp)"
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let audioFolder = folder.appendingPathComponent("Audio", isDirectory: true)
        try? fm.createDirectory(at: audioFolder, withIntermediateDirectories: true)

        let json = folder.appendingPathComponent("Compass \(stamp).json")
        guard let data = try? JSONFileStore.encoder().encode(snapshot), (try? data.write(to: json, options: .atomic)) != nil else {
            cleanUp()
            return []
        }
        var copies: [URL] = []
        for file in audio {
            let dest = audioFolder.appendingPathComponent(file.lastPathComponent)
            // A hard link costs no space; copy when the volume can't link.
            if (try? fm.linkItem(at: file, to: dest)) != nil || (try? fm.copyItem(at: file, to: dest)) != nil {
                copies.append(dest)
            }
        }
        if let zip = zip(folder, to: root.appendingPathComponent("\(name).zip")) {
            try? fm.removeItem(at: folder)
            return [zip]
        }
        return [json] + copies
    }

    /// Zip a folder with the system's coordinated "for uploading" read.
    static func zip(_ folder: URL, to destination: URL) -> URL? {
        let fm = FileManager.default
        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &error) { zipped in
            // `zipped` only exists inside this block.
            try? fm.removeItem(at: destination)
            if (try? fm.moveItem(at: zipped, to: destination)) != nil || (try? fm.copyItem(at: zipped, to: destination)) != nil {
                result = destination
            }
        }
        return error == nil ? result : nil
    }

    /// Remove every file an export made. Safe to call any time (share sheet done, sheet gone, launch).
    static func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
