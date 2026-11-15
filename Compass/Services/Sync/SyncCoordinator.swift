import Foundation
import Observation
import UIKit
import CompassCore

/// Which device wrote something. Items written on this device carry "This iPhone" (as the rest of the
/// app stores them); the envelope names the device by model ("iPhone", "iPad").
@MainActor
enum SyncDevice {
    static var model: String { UIDevice.current.model }
    /// "This iPhone"
    static var thisDeviceLabel: String { "This \(model)" }
    /// Stored on items created here.
    static var label: String { thisDeviceLabel }

    static func isThisDevice(_ device: String?) -> Bool {
        guard let device else { return true }
        return device.hasPrefix("This ")
    }
}

/// Bookkeeping kept on this device only (Application Support/Compass/sync-state.json).
struct SyncState: Codable, Equatable {
    var deviceID: String = UUID().uuidString
    /// Last time this device changed the snapshot itself (not by applying a merge). Envelope `savedAt`.
    var lastLocalChange: Date = .distantPast
    var tombstones: [DayTombstone] = []
    var wipedAt: Date?
    /// Newest wipe this device has already carried out.
    var appliedWipe: Date?

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compass/sync-state.json")
    }

    static func load() -> SyncState {
        guard let data = try? Data(contentsOf: url), let s = try? JSONFileStore.decoder().decode(SyncState.self, from: data) else { return SyncState() }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONFileStore.encoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}

/// Keeps the app's snapshot and audio in step with the user's other devices through iCloud.
///
/// - Watches `AppModel.snapshot` (Observation) and pushes this device's envelope 2 s after the last change,
///   and when the app goes to the background.
/// - Pulls when the app becomes active and whenever iCloud reports changed files (NSMetadataQuery),
///   merges every device's envelope with `SnapshotMerger` and puts the result back into the model.
///   Two devices editing the same day surface as E5 (`Day.mergeCandidates`).
/// - Does nothing at all when iCloud is unavailable (no account, iCloud Drive off, unsigned build):
///   Compass keeps working on this device only.
@MainActor
final class SyncCoordinator {
    private weak var model: AppModel?
    private let drive = ICloudDrive()
    private let io = DispatchQueue(label: "app.compass.icloud", qos: .utility)
    private var state = SyncState.load()
    private var root: URL?
    private var query: NSMetadataQuery?
    private var pushTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    private var applyingRemote = false
    private var observers: [NSObjectProtocol] = []

    private(set) var iCloudAvailable = false

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        observeSnapshot()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pullSoon(delay: 0) }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pushNow() }
        })
        observers.append(center.addObserver(forName: .NSUbiquityIdentityDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.connect() }
        })
        connect()
    }

    // MARK: Availability

    /// Look up the container off the main thread; start watching if iCloud is there.
    private func connect() {
        let drive = self.drive
        io.async { [weak self] in
            let root = drive.rootURL()
            Task { @MainActor in
                guard let self else { return }
                self.root = root
                self.iCloudAvailable = root != nil
                if root != nil {
                    self.startQuery()
                    self.pullSoon(delay: 0)
                } else {
                    self.query?.stop()
                    self.query = nil
                }
            }
        }
    }

    private func startQuery() {
        guard query == nil else { return }
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        q.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, root?.path ?? "/")
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pullSoon(delay: 1) }
            })
        }
        q.start()
        query = q
    }

    // MARK: Local changes → push

    private func observeSnapshot() {
        guard let model else { return }
        withObservationTracking {
            _ = model.snapshot
        } onChange: { [weak self] in
            // Called synchronously from the mutation, which always happens on the main actor (AppModel
            // is @MainActor), so the applyingRemote flag read here belongs to this very change.
            MainActor.assumeIsolated {
                guard let self else { return }
                let fromRemote = self.applyingRemote
                Task { @MainActor in
                    if !fromRemote {
                        self.state.lastLocalChange = Date()
                        self.state.save()
                        self.pushSoon()
                    }
                    self.observeSnapshot()
                }
            }
        }
    }

    func noteLocalChange() {
        state.lastLocalChange = Date()
        state.save()
        pushSoon()
    }

    private func pushSoon() {
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.pushNow()
        }
    }

    private func envelope() -> SyncEnvelope? {
        guard let model else { return nil }
        return SyncEnvelope(deviceID: state.deviceID, deviceName: SyncDevice.model, savedAt: state.lastLocalChange,
                            snapshot: model.snapshot, tombstones: state.tombstones, wipedAt: state.wipedAt)
    }

    func pushNow() {
        pushTask?.cancel()
        guard let root, let envelope = envelope() else { return }
        let drive = self.drive
        io.async {
            try? drive.write(envelope, root: root)
            drive.upload(audio: MemoAudio.allFiles(), root: root)
        }
    }

    // MARK: Remote changes → pull

    private func pullSoon(delay: Double) {
        guard root != nil else { return }
        pullTask?.cancel()
        pullTask = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.pull()
        }
    }

    private func pull() {
        guard let root else { return }
        let drive = self.drive
        io.async { [weak self] in
            let remote = drive.readEnvelopes(root: root)
            drive.download(audioInto: MemoAudio.syncedAudioDirectory, root: root)
            Task { @MainActor in self?.apply(remote) }
        }
    }

    /// Merge what other devices wrote into the model (on the main actor, against the latest local state).
    private func apply(_ remote: [SyncEnvelope]) {
        guard let model, let local = envelope() else { return }
        let others = remote.filter { $0.deviceID != state.deviceID }
        guard let merged = SnapshotMerger.merge([local] + others) else { return }

        if let wipe = merged.wipedAt, wipe > (state.appliedWipe ?? .distantPast) {
            // "Delete everything" on another device: erase here too.
            state.wipedAt = wipe
            state.appliedWipe = wipe
            state.tombstones = []
            DataEraser.eraseLocalData()
            state.save()
            applyingRemote = true
            model.deleteEverything()
            applyingRemote = false
            return
        }

        state.tombstones = merged.tombstones
        state.wipedAt = merged.wipedAt
        state.save()
        if merged.snapshot != model.snapshot {
            applyingRemote = true
            model.snapshot = merged.snapshot
            try? model.store.save(merged.snapshot)
            applyingRemote = false
            // Our envelope should now carry the merged result too.
            pushSoon()
        }
    }

    // MARK: Deletions

    func recordDeletion(of key: DayKey, at date: Date) {
        state.tombstones.removeAll { $0.key == key }
        state.tombstones.append(DayTombstone(key: key, deletedAt: date))
        noteLocalChange()
    }

    /// H2: wipe iCloud and leave a marker so every other device erases too.
    func wipeEverywhere(at date: Date) {
        pushTask?.cancel()
        pullTask?.cancel()
        let deviceID = state.deviceID
        state = SyncState(deviceID: deviceID, lastLocalChange: date, tombstones: [], wipedAt: date, appliedWipe: date)
        let marker = SyncEnvelope(deviceID: deviceID, deviceName: SyncDevice.model, savedAt: date, snapshot: .empty, wipedAt: date)
        if let root {
            let drive = self.drive
            io.async {
                drive.wipe(root: root)
                try? drive.write(marker, root: root)
            }
        }
        // The eraser clears Application Support right after this call; write the state back afterwards.
        Task { @MainActor [weak self] in self?.state.save() }
    }

    // MARK: Restore (R1–R3)

    /// Every readable envelope, merged, plus how many audio files are still downloading.
    nonisolated static func readBackup(drive: ICloudDrive) -> (root: URL?, merged: SyncEnvelope?) {
        guard let root = drive.rootURL() else { return (nil, nil) }
        return (root, SnapshotMerger.merge(drive.readEnvelopes(root: root)))
    }
}

/// R1–R3 against the user's iCloud: what's there, then bring it (and its audio) back.
final class ICloudBackupRestorer: BackupRestoring, @unchecked Sendable {
    private let drive = ICloudDrive()
    private let lock = NSLock()
    private var cancelled = false

    func availability() async -> BackupAvailability {
        let drive = self.drive
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (root, merged) = SyncCoordinator.readBackup(drive: drive)
                guard root != nil else { return continuation.resume(returning: .nothing(.iCloudUnavailable)) }
                guard let merged, merged.snapshot.goal != nil || !merged.snapshot.days.isEmpty else {
                    return continuation.resume(returning: .nothing(.empty))
                }
                continuation.resume(returning: .available(BackupSummary(snapshot: merged.snapshot, savedAt: merged.savedAt, deviceName: merged.deviceName)))
            }
        }
    }

    func restore(progress: @escaping @Sendable (Double) -> Void) async throws -> CompassSnapshot {
        lock.withLock { cancelled = false }
        let drive = self.drive
        let snapshot: CompassSnapshot = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                progress(0.1)
                let (root, merged) = SyncCoordinator.readBackup(drive: drive)
                guard let root else { return continuation.resume(throwing: RestoreError.iCloudUnavailable) }
                guard let merged, merged.snapshot.goal != nil || !merged.snapshot.days.isEmpty else {
                    return continuation.resume(throwing: RestoreError.nothingToRestore)
                }
                progress(0.3)
                if self?.isCancelled == true { return continuation.resume(throwing: RestoreError.cancelled) }
                drive.download(audioInto: MemoAudio.syncedAudioDirectory, root: root) { p in progress(0.3 + 0.7 * p) }
                if self?.isCancelled == true { return continuation.resume(throwing: RestoreError.cancelled) }
                progress(1)
                continuation.resume(returning: merged.snapshot)
            }
        }
        return snapshot
    }

    func cancel() { lock.withLock { cancelled = true } }

    private var isCancelled: Bool { lock.withLock { cancelled } }
}
