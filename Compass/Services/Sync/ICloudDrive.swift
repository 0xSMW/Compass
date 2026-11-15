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
///   Audio files are write-once with unique names, so they never conflict either; deleting one leaves an
///   `AudioTombstone` in the deleting device's envelope.
/// - The folder sits at the container root, not in `Documents`, so it stays out of the Files app.
///
/// Layout: `<container>/Compass/Devices/<deviceID>.json`, `<container>/Compass/Audio/<file>`.
/// All methods block (file coordination, downloads): call them off the main thread.
// @unchecked Sendable: no mutable state; its only property is a private FileManager instance (thread-safe).
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
    /// download; the metadata query reports them when they land. (R1 waits for them instead: see
    /// `envelopeSource` and `BackupReader`.)
    func readEnvelopes(root: URL) -> [SyncEnvelope] {
        envelopeFiles(root: root).compactMap { file in
            guard file.isDownloaded else {
                requestEnvelopeDownload(file.name, root: root)
                return nil
            }
            return readEnvelope(file.name, root: root)
        }
    }

    func envelopeFiles(root: URL) -> [EnvelopeFile] {
        let dir = root.appendingPathComponent("Devices", isDirectory: true)
        return allNames(in: dir).filter { $0.hasSuffix(".json") }.sorted().map { name in
            EnvelopeFile(name: name, isDownloaded: isDownloaded(dir.appendingPathComponent(name)))
        }
    }

    func requestEnvelopeDownload(_ name: String, root: URL) {
        try? fm.startDownloadingUbiquitousItem(at: root.appendingPathComponent("Devices/\(name)"))
    }

    func readEnvelope(_ name: String, root: URL) -> SyncEnvelope? {
        let url = root.appendingPathComponent("Devices/\(name)")
        var result: SyncEnvelope?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { target in
            if let data = try? Data(contentsOf: target) {
                result = try? JSONFileStore.decoder().decode(SyncEnvelope.self, from: data)
            }
        }
        return result
    }

    /// For R1: the envelopes as a `BackupReader` source (waits for placeholders to download).
    func envelopeSource() -> EnvelopeSource { ICloudEnvelopeSource(drive: self) }

    // MARK: Audio

    /// Names in iCloud's audio folder, including files that are only placeholders.
    func audioNames(root: URL) -> Set<String> {
        Set(allNames(in: root.appendingPathComponent("Audio", isDirectory: true)))
    }

    /// Copy local recordings that iCloud doesn't have yet. Names are unique per recording. The caller
    /// passes only recordings the snapshot uses (`AudioSyncPlan.toUpload`).
    func upload(audio files: [URL], root: URL) {
        let dir = root.appendingPathComponent("Audio", isDirectory: true)
        let remote = audioNames(root: root)
        for file in files where !remote.contains(file.lastPathComponent) {
            let target = dir.appendingPathComponent(file.lastPathComponent)
            var coordError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { t in
                try? fm.copyItem(at: file, to: t)
                copyDates(from: file, to: t)
            }
        }
    }

    /// Bring the named recordings into `localDir`. Placeholders are asked to download and counted;
    /// the next pull copies them. Returns how many are still downloading.
    @discardableResult
    func download(_ names: Set<String>, into localDir: URL, root: URL, progress: ((Double) -> Void)? = nil) -> Int {
        let dir = root.appendingPathComponent("Audio", isDirectory: true)
        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        var pending = 0
        for (i, name) in names.sorted().enumerated() {
            let source = dir.appendingPathComponent(name)
            let target = localDir.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) {
                // Already here.
            } else if isDownloaded(source) {
                var coordError: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [], error: &coordError) { s in
                    try? fm.copyItem(at: s, to: target)
                    copyDates(from: s, to: target)
                }
            } else {
                try? fm.startDownloadingUbiquitousItem(at: source)
                pending += 1
            }
            progress?(Double(i + 1) / Double(max(1, names.count)))
        }
        if names.isEmpty { progress?(1) }
        return pending
    }

    /// Remove recordings deleted on some device (audio tombstones) from iCloud.
    func deleteAudio(named names: Set<String>, root: URL) {
        guard !names.isEmpty else { return }
        let dir = root.appendingPathComponent("Audio", isDirectory: true)
        for name in audioNames(root: root).intersection(names) {
            remove(dir.appendingPathComponent(name))
        }
    }

    /// After "Delete everything": remove recordings made before the wipe that a device which hadn't heard
    /// of it copied back up. Judged by the recording's own dates (kept on every copy); placeholders whose
    /// dates aren't known yet are left for a device that has them.
    func purgeAudio(recordedBefore wipe: Date, root: URL) {
        let dir = root.appendingPathComponent("Audio", isDirectory: true)
        for name in allNames(in: dir) {
            let url = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path), let attrs = try? fm.attributesOfItem(atPath: url.path) else { continue }
            let dates = [attrs[.creationDate], attrs[.modificationDate]].compactMap { $0 as? Date }
            if let recorded = dates.max(), recorded < wipe { remove(url) }
        }
    }

    // MARK: Wipe (H2)

    /// Remove every device's envelope and all audio. The caller then writes its own (empty) envelope
    /// carrying `wipedAt`, so devices that were offline erase too when they next sync.
    func wipe(root: URL) {
        for sub in ["Devices", "Audio"] {
            let dir = root.appendingPathComponent(sub, isDirectory: true)
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                remove(url)
            }
        }
    }

    // MARK: Helpers

    private func remove(_ url: URL) {
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { t in
            try? fm.removeItem(at: t)
        }
        // A placeholder has its own hidden name.
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path) { try? fm.removeItem(at: placeholder) }
    }

    /// Real names in a folder, including files that are only placeholders (".name.icloud").
    private func allNames(in dir: URL) -> [String] {
        let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return Array(Set(items.compactMap { name -> String? in
            if name.hasPrefix("."), name.hasSuffix(".icloud") { return String(name.dropFirst().dropLast(".icloud".count)) }
            return name.hasPrefix(".") ? nil : name
        }))
    }

    /// A fresh URL each time, so the download status isn't a cached value.
    private func isDownloaded(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        guard fm.fileExists(atPath: fresh.path) else { return false }
        let values = try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        guard let status = values?.ubiquitousItemDownloadingStatus else { return true }
        return status == .current || status == .downloaded
    }

    /// Keep the recording's dates on the copy.
    private func copyDates(from source: URL, to target: URL) {
        guard let attrs = try? fm.attributesOfItem(atPath: source.path) else { return }
        var keep: [FileAttributeKey: Any] = [:]
        if let m = attrs[.modificationDate] { keep[.modificationDate] = m }
        if let c = attrs[.creationDate] { keep[.creationDate] = c }
        try? fm.setAttributes(keep, ofItemAtPath: target.path)
    }
}

/// `ICloudDrive`'s envelope folder as a `BackupReader` source. Finds the container on first use.
// @unchecked Sendable: `root` is guarded by `lock`; `drive` is an immutable, stateless ICloudDrive.
final class ICloudEnvelopeSource: EnvelopeSource, @unchecked Sendable {
    private let drive: ICloudDrive
    private let lock = NSLock()
    private var root: URL?

    init(drive: ICloudDrive) { self.drive = drive }

    var rootURL: URL? { lock.withLock { root } }

    func isAvailable() -> Bool {
        let r = drive.rootURL()
        lock.withLock { root = r }
        return r != nil
    }

    func listEnvelopes() -> [EnvelopeFile] {
        guard let root = rootURL else { return [] }
        return drive.envelopeFiles(root: root)
    }

    func requestDownload(_ name: String) {
        guard let root = rootURL else { return }
        drive.requestEnvelopeDownload(name, root: root)
    }

    func readEnvelope(_ name: String) -> SyncEnvelope? {
        guard let root = rootURL else { return nil }
        return drive.readEnvelope(name, root: root)
    }
}
