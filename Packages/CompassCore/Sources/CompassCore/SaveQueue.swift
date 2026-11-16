import Foundation
import Dispatch
import Synchronization

/// The app's store writes, off the main actor, in order (`AppModel` owns one).
///
/// The model's snapshot stays the source of truth and changes at once; `enqueue` hands a copy to a serial
/// worker that writes it with one coordinated `Store.write`. Writes queued while one runs are coalesced:
/// only the newest snapshot is written, and it is always written. What each write did comes back as a
/// `SaveOutcome`, in order, through `drain` on the owner's actor (`notify` says when to drain).
///
/// - **Others' writes.** The widget writes the same file. A write takes the widget's change in when the file
///   changed after this queue last wrote or read it (`StoreReload.shouldRead`), never after a failed write,
///   exactly as the app's save always did. The decode that needs is skipped when the file's stamp is still
///   the one this queue saw right after its own last write or read: nobody else wrote, so the file holds what
///   it knows. A change taken in is reported (`SaveOutcome.fileChanges`) and carried into every write queued
///   before the owner applied it, so a write already queued never drops it.
/// - **Work after a write** (`afterWrites`): runs on the worker once every snapshot queued before it has been
///   written, with whether the store holds the newest of them. Sync writes its state this way, so a wipe is
///   recorded only once the store holds the snapshot that carried it out (`WipeRecord`, `WipeLedger`).
/// - **Becoming active** (`retryOrCheck`): writes again after a failed write, else reads the file if another
///   process changed it.
/// - **Waiting.** `waitUntilIdle` blocks until everything queued so far is done (tests, the app ending);
///   `whenIdle` calls back instead (a background task while the app goes to the background).
public final class SaveQueue: Sendable {
    public let store: Store
    private let queue: DispatchQueue
    private let pending: Mutex<Pending>
    private let worker: Mutex<Worker>
    private let outcomes = Mutex<[SaveOutcome]>([])
    private let notify = Mutex<(@Sendable () -> Void)?>(nil)

    private struct Pending: Sendable {
        /// The newest snapshot to write; anything queued before it is covered by it.
        var write: Job?
        /// `retryOrCheck`: memory then, written only if the last write failed.
        var check: Job?
        var afterWrites: [@Sendable (Bool) -> Void] = []
        /// Writes were dropped (`discardPendingWrites`): work after them can't count on the store.
        var discarded = false
        var lastTicket: UInt64 = 0
        var running = false

        var isEmpty: Bool { write == nil && check == nil && afterWrites.isEmpty }
    }

    private struct Job: Sendable {
        var ticket: UInt64
        var snapshot: CompassSnapshot
    }

    /// Touched only by the worker, and by `drain` / `replacingContents` for single fields.
    private struct Worker: Sendable {
        /// The store's stamp right after this queue's last successful write or read (`lastSavedAt`).
        var known: StoreStamp?
        var failed = false
        /// What another process wrote that a write took in or a check read, until the owner has applied it.
        var external: External?
        var externalCount: UInt64 = 0
    }

    private struct External: Sendable {
        var id: UInt64
        var file: CompassSnapshot
        /// Set once the owner applied it: snapshots queued after this ticket already carry it.
        var appliedThrough: UInt64?
    }

    /// - Parameters:
    ///   - knownStamp: the store's stamp when the owner last read it (launch), or nil to take any file's changes.
    public init(store: Store, knownStamp: StoreStamp?, label: String = "app.compass.save") {
        self.store = store
        queue = DispatchQueue(label: label, qos: .userInitiated)
        pending = Mutex(Pending())
        worker = Mutex(Worker(known: knownStamp))
    }

    /// Called on the worker after each outcome is posted; the owner schedules a `drain` on its actor.
    public func setNotify(_ body: @escaping @Sendable () -> Void) {
        notify.withLock { $0 = body }
    }

    // MARK: Queueing

    /// Write `snapshot` (in order, after everything queued before). Returns its ticket.
    @discardableResult
    public func enqueue(_ snapshot: CompassSnapshot) -> UInt64 {
        schedule { p in
            p.lastTicket += 1
            p.write = Job(ticket: p.lastTicket, snapshot: snapshot)
        }
    }

    /// Becoming active: if the last write failed, write `memory` (a retry; `SaveOutcome.caughtUp` when it goes
    /// through); otherwise read the file if another process changed it since this queue last wrote or read it.
    public func retryOrCheck(memory: CompassSnapshot) {
        schedule { p in
            p.lastTicket += 1
            p.check = Job(ticket: p.lastTicket, snapshot: memory)
        }
    }

    /// Run `body` on the worker once every snapshot queued so far is written, with whether the store holds
    /// the newest of them (false when that write failed or was dropped).
    public func afterWrites(_ body: @escaping @Sendable (_ storeHoldsQueued: Bool) -> Void) {
        schedule { $0.afterWrites.append(body) }
    }

    /// Call `body` (on the worker) once everything queued so far is done.
    public func whenIdle(_ body: @escaping @Sendable () -> Void) {
        afterWrites { _ in body() }
    }

    @discardableResult
    private func schedule(_ change: (inout Pending) -> Void) -> UInt64 {
        let (ticket, start) = pending.withLock { p -> (UInt64, Bool) in
            change(&p)
            if p.running { return (p.lastTicket, false) }
            p.running = true
            return (p.lastTicket, true)
        }
        if start { queue.async { self.run() } }
        return ticket
    }

    // MARK: Waiting

    /// Block until everything queued so far is done. Never call it from the worker (`afterWrites`).
    public func waitUntilIdle() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {}
    }

    /// True when nothing is queued or running.
    public var isIdle: Bool { pending.withLock { !$0.running && $0.isEmpty } }

    /// Drop snapshots not yet written and wait for the write in progress and the work queued after writes
    /// (which is told the store doesn't hold what was queued). Nothing writes the store after this returns
    /// until something new is queued: Delete everything removes the file next.
    public func discardPendingWrites() {
        pending.withLock { p in
            if (p.write != nil || p.check != nil) && !p.afterWrites.isEmpty { p.discarded = true }
            p.write = nil
            p.check = nil
        }
        waitUntilIdle()
    }

    /// A snapshot is waiting to be written (tests).
    var hasPendingWrite: Bool { pending.withLock { $0.write != nil } }

    /// Delete everything: `discardPendingWrites`, then `body` replaces what is stored (removes the file), then
    /// the queue starts over from what is stored then: no failure, its stamp, no outcome left to apply.
    public func replacingContents(_ body: () -> Void) {
        discardPendingWrites()
        body()
        let stamp = store.stamp
        worker.withLock { w in
            w.known = stamp
            w.failed = false
            w.external = nil
        }
        outcomes.withLock { $0 = [] }
    }

    // MARK: Outcomes

    /// Apply what the worker reported since the last drain, in order, on the owner's actor. Snapshots queued
    /// after this returns are taken to carry every file change `apply` was given. Returns how many there were.
    @discardableResult
    public func drain(_ apply: (SaveOutcome) -> Void) -> Int {
        let list = outcomes.withLock { o -> [SaveOutcome] in
            defer { o = [] }
            return o
        }
        for outcome in list { apply(outcome) }
        if let id = list.last(where: { $0.fileChanges != nil })?.changesID {
            let through = pending.withLock { $0.lastTicket }
            worker.withLock { w in
                if w.external?.id == id { w.external?.appliedThrough = through }
            }
        }
        return list.count
    }

    // MARK: Worker

    private func run() {
        while true {
            let batch = pending.withLock { p -> Pending? in
                if p.isEmpty {
                    p.running = false
                    return nil
                }
                let batch = p
                p.write = nil
                p.check = nil
                p.afterWrites = []
                p.discarded = false
                return batch
            }
            guard let batch else { return }
            process(batch)
        }
    }

    private func process(_ batch: Pending) {
        let wasFailed = worker.withLock { $0.failed }
        var target = batch.write
        if let check = batch.check, (target != nil || wasFailed), check.ticket > (target?.ticket ?? 0) { target = check }

        if let target {
            post(write(target, retried: batch.check != nil && wasFailed))
        } else if batch.check != nil, let outcome = checkFile() {
            post(outcome)
        }
        let holds = !batch.discarded && !worker.withLock { $0.failed }
        for body in batch.afterWrites { body(holds) }
    }

    private func write(_ job: Job, retried: Bool) -> SaveOutcome {
        let (known, failed, carried) = worker.withLock { w -> (StoreStamp?, Bool, CompassSnapshot?) in
            if let e = w.external, let through = e.appliedThrough, job.ticket > through { w.external = nil }
            return (w.known, w.failed, w.external?.file)
        }
        var tookFrom: CompassSnapshot?
        do {
            let written = try store.write(replacingUnreadable: true) { stamp, read in
                var next = job.snapshot
                // A change taken in earlier that the owner hadn't applied when this was queued.
                if let carried { next = next.takingWidgetChanges(from: carried) }
                // Unchanged since this queue last wrote or read it: nothing to take, nothing to decode.
                guard stamp != known else { return next }
                let stored = try read()
                if StoreReload.shouldRead(fileModifiedAt: stamp?.modifiedAt, lastSavedAt: known?.modifiedAt, saveFailed: failed) {
                    let taken = next.takingWidgetChanges(from: stored)
                    if taken != next {
                        tookFrom = stored
                        next = taken
                    }
                }
                return next
            }
            let changesID = worker.withLock { w -> UInt64 in
                w.known = written.stamp
                w.failed = false
                guard let tookFrom else { return 0 }
                w.externalCount += 1
                w.external = External(id: w.externalCount, file: tookFrom)
                return w.externalCount
            }
            return SaveOutcome(write: .succeeded, ticket: job.ticket, modifiedAt: written.modifiedAt, fileChanges: tookFrom,
                               caughtUp: retried && StoreReload.afterRetry(saveFailed: false).recordSyncState, changesID: changesID)
        } catch {
            worker.withLock { $0.failed = true }
            return SaveOutcome(write: .failed(String(describing: error)), ticket: job.ticket, modifiedAt: nil, fileChanges: nil,
                               caughtUp: false, changesID: 0)
        }
    }

    /// Becoming active with nothing to write: read the file only if another process changed it.
    private func checkFile() -> SaveOutcome? {
        let known = worker.withLock { $0.known }
        // Taken before the read: a write landing in between is read again next time, never missed.
        let stamp = store.stamp
        guard StoreReload.shouldRead(fileModifiedAt: stamp?.modifiedAt, lastSavedAt: known?.modifiedAt, saveFailed: false),
              let file = try? store.load() else { return nil }
        let changesID = worker.withLock { w -> UInt64 in
            w.known = stamp
            w.externalCount += 1
            w.external = External(id: w.externalCount, file: file)
            return w.externalCount
        }
        return SaveOutcome(write: nil, ticket: 0, modifiedAt: stamp?.modifiedAt, fileChanges: file, caughtUp: false, changesID: changesID)
    }

    private func post(_ outcome: SaveOutcome) {
        outcomes.withLock { $0.append(outcome) }
        notify.withLock { $0 }?()
    }
}

/// What one step of `SaveQueue`'s worker did, applied by the owner on its actor (`SaveQueue.drain`).
public struct SaveOutcome: Equatable, Sendable {
    public enum Write: Equatable, Sendable {
        case succeeded
        /// The store kept what it had (full disk, a newer-schema file). The description is for logs.
        case failed(String)
    }

    /// The write this step made; nil for a check that only read the file (`retryOrCheck`).
    public var write: Write?
    /// The newest queued snapshot the write held (`SaveQueue.enqueue`'s ticket); 0 for a check.
    public var ticket: UInt64
    /// The store's modification date after this step (the app's `lastSavedAt`); nil after a failure.
    public var modifiedAt: Date?
    /// What another process (the widget) wrote, read inside this step: the write took its changes in
    /// (`takingWidgetChanges`), or a check read it. The owner takes the same changes into memory.
    public var fileChanges: CompassSnapshot?
    /// A retry asked for by `retryOrCheck` went through after a failed write: the store holds memory again,
    /// and sync records what it held back (`StoreReload.afterRetry`).
    public var caughtUp: Bool
    let changesID: UInt64
}

/// The wipe fields `sync-state.json` holds, for the sync state written after a store write
/// (`SaveQueue.afterWrites`): a wipe held in memory is recorded only when the store holds the snapshot that
/// carried it out; otherwise the file keeps what it had (`WipeRecord.toSave`).
public final class WipeLedger: Sendable {
    private let onDisk: Mutex<WipeRecord>

    public init(onDisk: WipeRecord) {
        self.onDisk = Mutex(onDisk)
    }

    /// What the state file holds now.
    public var recorded: WipeRecord { onDisk.withLock { $0 } }

    /// What to write to the state file, remembered as written.
    public func record(_ inMemory: WipeRecord, storeHoldsModel: Bool) -> WipeRecord {
        onDisk.withLock { disk in
            disk = WipeRecord.toSave(inMemory: inMemory, onDisk: disk, storeHoldsModel: storeHoldsModel)
            return disk
        }
    }
}
