import Foundation
import CompassCore

/// Compass's files in the user's iCloud, through an iCloud Drive **ubiquity container** (no account,
/// no server of ours).
///
/// Why a ubiquity container rather than the CloudKit private database:
/// - Compass's data already is files: one JSON snapshot (the same `JSONFileStore` format the app and
///   widget use) plus audio clips. iCloud Drive syncs both as-is, with no record schema to deploy and no
///   CKAsset plumbing for audio.
/// - It degrades by itself: `url(forUbiquityContainerIdentifier:)` returns nil when there is no iCloud
///   account, iCloud Drive is off for Compass, or the build has no iCloud entitlement (unsigned simulator
///   CI builds). `CKContainer.default()` instead traps at runtime without the entitlement.
/// - Conflicts are avoided by layout instead of resolved by the file system: every device writes only
///   its own `Devices/<deviceID>.json` (one writer per file, so no NSFileVersion conflicts), and every
///   device reads all of them and merges with the pure `SnapshotMerger` in CompassCore (E5 lives there).
///   Audio files are write-once with unique names, so they never conflict either.
/// - The folder sits at the container root, not in `Documents`, so it stays out of the Files app.
///
/// Layout: `<container>/Compass/Devices/<deviceID>.json`, `<container>/Compass/Audio/<file>`.
/// All methods block (file coordination, downloads): call them off the main thread.
final class ICloudDrive: @unchecked Sendable {
    static let containerIdentifier = "iCloud.app.compass.Compass"

    private let fm = FileManager()

    /// nil when iCloud can't be used (see type comment). Slow on first call: never on the main thread.
    func rootURL() -> URL? {
        guard fm.ubiquityIdentityToken != nil,
              let container = fm.url(forUbiquityContainerIdentifier: Self.containerIdentifier) else { return nil }
        let root = container.appendingPathComponent("Compass", isDirectory: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Devices", isDirectory: true), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("Audio", isDirectory: true), withIntermediateDirectories: true)
        return root
    }

    // MARK: Envelopes

    func write(_ envelope: SyncEnvelope, root: URL) throws {
        let url = root.appendingPathComponent("Devices/\(envelope.deviceID).json")
        let data = try JSONFileStore.encoder().encode(envelope)
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { target in
            do { try data.write(to: target, options: .atomic) } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
    }

    /// Every device's envelope that is on this device now. Files still in the cloud are asked to
    /// download; the metadata query reports them when they land.
    func readEnvelopes(root: URL) -> [SyncEnvelope] {
        let dir = root.appendingPathComponent("Devices", isDirectory: true)
        return downloadedFiles(in: dir, ext: "json").compactMap { url in
            var result: SyncEnvelope?
            var coordError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { target in
                if let data = try? Data(contentsOf: target) {
                    result = try? JSONFileStore.decoder().decode(SyncEnvelope.self, from: data)
                }
            }
            return result
        }
    }

    // MARK: Audio

    /// Copy local recordings that iCloud doesn't have yet. Names are unique per recording.
    func upload(audio files: [URL], root: URL) {
        let dir = root.appendingPathComponent("Audio", isDirectory: true)
        let remote = Set(allNames(in: dir))
        for file in files where !remote.contains(file.lastPathComponent) {
            let target = dir.appendingPathComponent(file.lastPathComponent)
            var coordError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { t in
                try? fm.copyItem(at: file, to: t)
                copyDates(from: file, to: t)
            }
        }
    }

    /// Bring recordings from other devices into `localDir`. Returns how many are still downloading.
    @discardableResult
    func download(audioInto localDir: URL, root: URL, progress: ((Double) -> Void)? = nil) -> Int {
        let dir = root.appendingPathComponent("Audio", isDirectory: true)
        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        let localNames = Set(MemoAudio.allFiles().map(\.lastPathComponent))
        let names = allNames(in: dir).filter { !localNames.contains($0) }
        var pending = 0
        for (i, name) in names.enumerated() {
            let source = dir.appendingPathComponent(name)
            if isDownloaded(source) {
                var coordError: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordError) { s in
                    let target = localDir.appendingPathComponent(name)
                    try? fm.copyItem(at: s, to: target)
                    copyDates(from: s, to: target)
                }
            } else {
                try? fm.startDownloadingUbiquitousItem(at: source)
                pending += 1
            }
            progress?(Double(i + 1) / Double(max(1, names.count)))
        }
        return pending
    }

    // MARK: Wipe (H2)

    /// Remove every device's envelope and all audio. The caller then writes its own (empty) envelope
    /// carrying `wipedAt`, so devices that were offline erase too when they next sync.
    func wipe(root: URL) {
        for sub in ["Devices", "Audio"] {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                var coordError: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { t in
                    try? fm.removeItem(at: t)
                }
            }
        }
    }

    // MARK: Helpers

    /// Real names in a folder, including files that are only placeholders (".name.icloud").
    private func allNames(in dir: URL) -> [String] {
        let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.compactMap { name in
            if name.hasPrefix("."), name.hasSuffix(".icloud") { return String(name.dropFirst().dropLast(".icloud".count)) }
            return name.hasPrefix(".") ? nil : name
        }
    }

    private func downloadedFiles(in dir: URL, ext: String) -> [URL] {
        allNames(in: dir).filter { $0.hasSuffix("." + ext) }.compactMap { name in
            let url = dir.appendingPathComponent(name)
            if isDownloaded(url) { return url }
            try? fm.startDownloadingUbiquitousItem(at: url)
            return nil
        }
    }

    private func isDownloaded(_ url: URL) -> Bool {
        guard fm.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else { return true }
        return status == .current || status == .downloaded
    }

    /// Keep the recording's dates: History matches a memo to its file by when it was recorded.
    private func copyDates(from source: URL, to target: URL) {
        guard let attrs = try? fm.attributesOfItem(atPath: source.path) else { return }
        var keep: [FileAttributeKey: Any] = [:]
        if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
        if let c = attrs[.creationDate] { keep[.creationDate] = c }
        try? fm.setAttributes(keep, ofItemAtPath: target.path)
    }
}
