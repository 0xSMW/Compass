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
        if fixture == nil {
            LiveSync.wipeEverywhere(at: now)
            DataEraser.eraseLocalData()
        }
        HistorySelection.shared.day = nil
        HistorySelection.shared.weekEnd = nil
        HistorySelection.shared.goalID = nil
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

/// "Export everything": a readable JSON file of the whole snapshot plus every recording on the device.
enum DataExport {
    static func makeExport(_ snapshot: CompassSnapshot, now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        let stamp = HistoryFormat.formatter("yyyy-MM-dd", calendar: Calendar(identifier: .gregorian)).string(from: now)
        let folder = fm.temporaryDirectory.appendingPathComponent("Compass export \(stamp)", isDirectory: true)
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        let json = folder.appendingPathComponent("Compass \(stamp).json")
        if let data = try? JSONFileStore.encoder().encode(snapshot), (try? data.write(to: json, options: .atomic)) != nil {
            urls.append(json)
        }
        urls += MemoAudio.allFiles()
        return urls
    }
}
