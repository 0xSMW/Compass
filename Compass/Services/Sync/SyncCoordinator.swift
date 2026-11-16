import Foundation
import Observation
import UIKit
import CompassCore

/// Which device wrote something. Features store "This iPhone" on what they record; the save path
/// (`LocalEdits.stamp`) replaces it with this install's `deviceID` and model, and E5 compares those ids
/// through `DeviceIdentity`, so "This iPhone" is only shown for things recorded here.
@MainActor
enum SyncDevice {
    static var model: String { UIDevice.current.model }
    /// "This iPhone"
    static var thisDeviceLabel: String { "This \(model)" }
    /// Stored on items created here until the save path stamps them with the device id.
    static var label: String { thisDeviceLabel }
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
    /// A first goal onboarding made here before any backup was merged; it wins over the backup's goal
    /// (`SyncApplyInput.freshGoalID`). Cleared after the first pass that promotes it or reads another
    /// device's goals, or seven days after the goal was made.
    var freshGoalID: UUID?

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compass/sync-state.json")
    }

    /// nil on first launch with sync (or after Delete everything cleared it).
    static func load() -> SyncState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONFileStore.decoder().decode(SyncState.self, from: data)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONFileStore.encoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}

/// Keeps the app's snapshot and audio in step with the user's other devices through iCloud.
///
/// - `AppModel`'s single save path stamps every local change (`LocalEdits`: per-item `updatedAt`, this
///   device's id on new recordings) and calls `noteLocalChange()`; this pushes this device's envelope
///   2 s after the last change, and when the app goes to the background.
/// - Pulls when the app becomes active and whenever iCloud reports changed files (NSMetadataQuery),
///   merges every device's envelope with `SnapshotMerger` and puts the result back into the model.
///   Two devices recording the same evening surface as E5 (`Day.mergeCandidates`).
/// - Audio: only recordings the snapshot uses travel (`AudioSyncPlan`); deletions travel as audio
///   tombstones and are removed from iCloud and every device.
/// - "Delete everything" is a generation boundary (`SnapshotMerger`): a device that edited offline after
///   the wipe keeps only what it made after it, and checks for a newer wipe before every push.
/// - Does nothing at all when iCloud is unavailable (no account, iCloud Drive off, unsigned build):
///   Compass keeps working on this device only.
@MainActor
final class SyncCoordinator {
    private weak var model: AppModel?
    private let drive = ICloudDrive()
    private let io = DispatchQueue(label: "app.compass.icloud", qos: .utility)
    private var state: SyncState
    /// The wipe fields `sync-state.json` holds now. They lag `state` while the store file doesn't hold the
    /// snapshot that carried a new wipe out (`saveState`, CompassCore `WipeRecord`).
    private var wipeOnDisk: WipeRecord
    private var root: URL?
    private var query: NSMetadataQuery?
    private var pushTask: Task<Void, Never>?
    private var pullTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private(set) var iCloudAvailable = false

    init(model: AppModel) {
        self.model = model
        let loaded: SyncState
        if let saved = SyncState.load() {
            loaded = saved
        } else {
            var fresh = SyncState()
            if !model.snapshot.isBlank { fresh.lastLocalChange = Date() }
            fresh.save()
            loaded = fresh
        }
        state = loaded
        wipeOnDisk = WipeRecord(wipedAt: loaded.wipedAt, appliedWipe: loaded.appliedWipe)
    }

    /// Write `sync-state.json`. A wipe this device carried out is recorded only once the store file holds
    /// the snapshot that carried it out (`storeHoldsModel`, by default the model's last save went through):
    /// until then the file keeps the wipe it had, so a relaunch over a stale store filters it again instead
    /// of exempting pre-wipe data (CompassCore `WipeRecord`). Memory keeps the new wipe either way.
    private func saveState(storeHoldsModel: Bool? = nil) {
        let holds = storeHoldsModel ?? (model.map { !$0.saveFailed } ?? true)
        let record = WipeRecord.toSave(inMemory: WipeRecord(wipedAt: state.wipedAt, appliedWipe: state.appliedWipe),
                                       onDisk: wipeOnDisk, storeHoldsModel: holds)
        var file = state
        file.wipedAt = record.wipedAt
        file.appliedWipe = record.appliedWipe
        file.save()
        wipeOnDisk = record
    }

    /// This install, for stamping items and labelling E5.
    var deviceIdentity: DeviceIdentity { DeviceIdentity(id: state.deviceID, model: SyncDevice.model) }

    func start() {
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

    func noteLocalChange() {
        state.lastLocalChange = Date()
        saveState()
        pushSoon()
    }

    /// The store file holds the model again after failed saves (a retry on becoming active went through):
    /// write the state now, so a wipe held back while it didn't (`saveState`) is recorded before the next
    /// change or merge, which a kill could otherwise beat.
    func storeCaughtUp() {
        saveState()
    }

    private func pushSoon() {
        pushTask?.cancel()
        pushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.pushNow()
        }
    }

    /// This device's envelope exactly as its file reads back (`asStored`: dates in whole seconds), so the
    /// merge compares its `savedAt`, tombstones and wipe with other devices' decoded ones on equal terms.
    /// The model's snapshot is already in that form (`AppModel.commit`), so only the rest makes the trip.
    private func envelope() -> SyncEnvelope? {
        guard let model else { return nil }
        return JSONFileStore.asStored(SyncEnvelope(deviceID: state.deviceID, deviceName: SyncDevice.model, savedAt: state.lastLocalChange,
                                                   snapshot: model.snapshot, tombstones: state.tombstones, wipedAt: state.wipedAt,
                                                   audioTombstones: AudioTombstoneLog.shared.all),
                                      snapshotIsStored: true)
    }

    func pushNow() {
        pushTask?.cancel()
        guard let root, let envelope = envelope() else { return }
        let drive = self.drive
        let knownWipe = state.appliedWipe ?? .distantPast
        let referenced = envelope.snapshot.referencedAudioFiles
        io.async { [weak self] in
            // Another device wiped since this one last merged: merge first, so nothing from before the
            // wipe goes back up (neither the envelope nor its recordings).
            if let remoteWipe = drive.readEnvelopes(root: root).compactMap(\.wipedAt).max(), remoteWipe > knownWipe {
                Task { @MainActor in self?.pullSoon(delay: 0) }
                return
            }
            try? drive.write(envelope, root: root)
            let tombstones = envelope.audioTombstones
            drive.deleteAudio(named: Set(tombstones.map(\.name)), root: root)
            let local = MemoAudio.allFiles()
            let names = AudioSyncPlan.toUpload(local: Set(local.map(\.lastPathComponent)), remote: drive.audioNames(root: root),
                                               referenced: referenced, tombstones: tombstones)
            drive.upload(audio: local.filter { names.contains($0.lastPathComponent) }, root: root)
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
            Task { @MainActor in self?.apply(remote) }
        }
    }

    /// Merge what other devices wrote into the model (on the main actor, against the latest local state).
    /// What to do is decided by `SyncApply.plan` (CompassCore, tested branch by branch); this carries it out.
    private func apply(_ remote: [SyncEnvelope]) {
        guard let model, let local = envelope() else { return }
        let input = SyncApplyInput(local: local, remote: remote, appliedWipe: state.appliedWipe,
                                   isOnboarding: model.current.flow == .onboarding, freshGoalID: state.freshGoalID,
                                   now: Date())
        guard let plan = SyncApply.plan(input) else { return }
        let before = model.snapshot
        let merged = plan.merged

        state.tombstones = merged.tombstones
        state.wipedAt = merged.wipedAt
        if plan.newWipe { state.appliedWipe = merged.wipedAt }
        state.freshGoalID = plan.freshGoalID

        switch plan.action {
        case .eraseLocal:
            // "Delete everything" on another device and nothing made here since: erase here too.
            state.tombstones = []
            DataEraser.eraseLocalData()
            AudioTombstoneLog.shared.reset(keeping: merged.audioTombstones)
            // The eraser removed the store file: nothing from before the wipe is left on disk.
            saveState(storeHoldsModel: true)
            model.deleteEverything()
            syncAudio(referencedBefore: before.referencedAudioFiles, merged: merged)
            return
        case .adopt(let snapshot, let source):
            AudioTombstoneLog.shared.adopt(merged.audioTombstones)
            let phaseBefore = model.phase
            // `.merge` saves and reloads the widget without counting as this device's own change; a fresh
            // goal put back on top (`.localChange`) is this device's decision and is stamped and pushed.
            model.commit(snapshot, origin: source == .localChange ? .local : .remote)
            // Only now, after the store write: a new wipe is recorded only if the filtered snapshot reached
            // the disk (`saveFailed` false). Saving the state first left a window where a crash kept the
            // pre-wipe store under a state that said the wipe was carried out.
            saveState()
            // Today's phase changed elsewhere (morning done on the iPad): judge the screen again,
            // unless an answer is in progress (then once it ends). F2.
            model.system.mergeApplied(phaseBefore: phaseBefore)
            // Our envelope should now carry the merged result too.
            pushSoon()
        case .keep:
            AudioTombstoneLog.shared.adopt(merged.audioTombstones)
            saveState()
        }
        // Only what this device made after a wipe is left; open wherever that leads. A goal arriving
        // mid-onboarding never ends it: finishing sets the new goal on top (`onboardingFinish`).
        if plan.openEntry { model.goToEntry() }
        var after = merged
        after.snapshot = model.snapshot
        syncAudio(referencedBefore: before.referencedAudioFiles, merged: after)
    }

    // MARK: Starting fresh over a backup (S2)

    /// Onboarding finished here with a first goal before this device had merged the user's iCloud data:
    /// the next merges put it back on top of the backup's goal (`SyncApply`).
    func markFreshGoal(_ id: UUID) {
        state.freshGoalID = id
        saveState()
    }

    /// Read iCloud now (A1 "Start a new goal": bring the backup in while the user onboards).
    func pullNow() { pullSoon(delay: 0) }

    /// After a merge: drop local recordings the merge removed, remove deleted recordings from iCloud,
    /// clear recordings from before a wipe, and bring in recordings the merged snapshot uses.
    private func syncAudio(referencedBefore: Set<String>, merged: SyncEnvelope) {
        guard let root else { return }
        let drive = self.drive
        let referenced = merged.snapshot.referencedAudioFiles
        let tombstones = AudioTombstoneLog.shared.all
        let wipe = merged.wipedAt
        io.async {
            let local = MemoAudio.allNames()
            let remove = AudioSyncPlan.toRemoveLocally(local: local, referencedBefore: referencedBefore,
                                                       referencedAfter: referenced, tombstones: tombstones)
            for name in remove { MemoAudio.removeLocalCopy(name) }
            drive.deleteAudio(named: Set(tombstones.map(\.name)), root: root)
            if let wipe { drive.purgeAudio(recordedBefore: wipe, keeping: referenced, root: root) }
            let wanted = AudioSyncPlan.toDownload(remote: drive.audioNames(root: root), local: local.subtracting(remove),
                                                  referenced: referenced, tombstones: tombstones)
            drive.download(wanted, into: MemoAudio.syncedAudioDirectory, root: root)
        }
    }

    // MARK: Deletions

    func recordDeletion(of key: DayKey, at date: Date) {
        state.tombstones.removeAll { $0.key == key }
        state.tombstones.append(DayTombstone(key: key, deletedAt: date))
        noteLocalChange()
    }

    /// H2: wipe iCloud and leave a marker so every other device erases too. Called before the model is
    /// cleared. The wipe is dated at `now` unless this device holds something stamped later, or knows a wipe
    /// that late (a clock set back, or a fast clock elsewhere): then just after it (`SyncEnvelope.wipeDate`),
    /// so everything deleted here stays deleted and the wipe outranks every earlier one.
    func wipeEverywhere(at now: Date) {
        pushTask?.cancel()
        pullTask?.cancel()
        let deviceID = state.deviceID
        let deleting = envelope() ?? SyncEnvelope(deviceID: deviceID, deviceName: SyncDevice.model, savedAt: state.lastLocalChange,
                                                  snapshot: .empty, tombstones: state.tombstones, wipedAt: state.wipedAt)
        let date = deleting.wipeDate(now: now, knownWipe: state.appliedWipe)
        state = SyncState(deviceID: deviceID, lastLocalChange: date, tombstones: [], wipedAt: date, appliedWipe: date, freshGoalID: nil)
        AudioTombstoneLog.shared.reset()
        let marker = SyncEnvelope(deviceID: deviceID, deviceName: SyncDevice.model, savedAt: date, snapshot: .empty, wipedAt: date)
        if let root {
            let drive = self.drive
            io.async {
                drive.wipe(root: root)
                try? drive.write(marker, root: root)
            }
        }
        // The eraser clears Application Support right after this call; write the state back afterwards
        // (the store file is gone by then, so the wipe is recorded).
        Task { @MainActor [weak self] in self?.saveState(storeHoldsModel: true) }
    }
}

/// R1–R3 against the user's iCloud: what's there (waiting for files that are still in the cloud), then
/// bring it and its recordings back.
// @unchecked Sendable: `cancelled` and `lastRead` are guarded by `lock`; `drive` is immutable and stateless.
final class ICloudBackupRestorer: BackupRestoring, @unchecked Sendable {
    private let drive = ICloudDrive()
    private let lock = NSLock()
    private var cancelled = false
    /// The last read, so R1's restore doesn't wait for the same downloads twice.
    private var lastRead: (read: BackupRead, root: URL?)?

    func availability() async -> BackupAvailability {
        await availability(progress: { _ in })
    }

    func availability(progress: @escaping @Sendable (Double) -> Void) async -> BackupAvailability {
        lock.withLock { cancelled = false }
        return await read(progress: progress).read.availability
    }

    private func read(progress: @escaping @Sendable (Double) -> Void) async -> (read: BackupRead, root: URL?) {
        let drive = self.drive
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let source = ICloudEnvelopeSource(drive: drive)
                let read = BackupReader().read(from: source, isCancelled: { self?.isCancelled ?? true }, progress: progress)
                let result = (read: read, root: source.rootURL)
                self?.lock.withLock { self?.lastRead = result }
                continuation.resume(returning: result)
            }
        }
    }

    func restore(progress: @escaping @Sendable (Double) -> Void) async throws -> CompassSnapshot {
        lock.withLock { cancelled = false }
        let cached = lock.withLock { () -> (read: BackupRead, root: URL?)? in
            defer { lastRead = nil }
            return lastRead
        }
        let found: (read: BackupRead, root: URL?)
        if let cached { found = cached } else { found = await read { p in progress(0.3 * p) } }
        guard found.read.available, let root = found.root else { throw RestoreError.iCloudUnavailable }
        guard let merged = found.read.merged, !merged.snapshot.isBlank else { throw RestoreError.nothingToRestore }
        progress(0.3)
        if isCancelled { throw RestoreError.cancelled }

        let drive = self.drive
        let wanted = AudioSyncPlan.toDownload(remote: drive.audioNames(root: root), local: MemoAudio.allNames(),
                                              referenced: merged.snapshot.referencedAudioFiles, tombstones: merged.audioTombstones)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // Placeholders keep downloading; sync copies them in when they land.
                drive.download(wanted, into: MemoAudio.syncedAudioDirectory, root: root) { p in progress(0.3 + 0.7 * p) }
                continuation.resume()
            }
        }
        if isCancelled { throw RestoreError.cancelled }
        progress(1)
        return merged.snapshot
    }

    func cancel() { lock.withLock { cancelled = true } }

    private var isCancelled: Bool { lock.withLock { cancelled } }
}
