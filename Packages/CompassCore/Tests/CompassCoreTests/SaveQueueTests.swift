import Foundation
import Dispatch
import Synchronization
import XCTest
@testable import CompassCore

/// A store whose writes can be held at the door, so a test can queue several while one is in progress.
final class GatedStore: Store, Sendable {
    let inner: InMemoryStore
    private let holding = Mutex(false)
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    init(_ snapshot: CompassSnapshot = .empty) { inner = InMemoryStore(snapshot) }

    /// The next write waits for `release()` (after signalling that it started).
    func holdNextWrite() { holding.withLock { $0 = true } }
    func waitUntilAWriteIsHeld() { entered.wait() }
    func release() { released.signal() }

    func load() throws -> CompassSnapshot { try inner.load() }
    func save(_ snapshot: CompassSnapshot) throws { try inner.save(snapshot) }
    var modifiedAt: Date? { inner.modifiedAt }
    var stamp: StoreStamp? { inner.stamp }

    func write(replacingUnreadable: Bool, _ body: (StoreStamp?, () throws -> CompassSnapshot) throws -> CompassSnapshot) throws -> StoreWrite {
        let hold = holding.withLock { h -> Bool in
            defer { h = false }
            return h
        }
        if hold {
            entered.signal()
            released.wait()
        }
        return try inner.write(replacingUnreadable: replacingUnreadable, body)
    }
}

/// `SaveQueue`: the app's store writes off the main actor, in order, coalesced, never dropping the last one,
/// reporting each outcome, holding sync's wipe record back until the store holds the wipe, and flushing.
final class SaveQueueTests: XCTestCase {
    let key = Fixtures.todayKey

    /// The fixture with `n` notes today, so every version differs and can be told apart.
    func version(_ n: Int) -> CompassSnapshot {
        let notes = (0..<n).map { Note(text: "note \($0)", createdAt: Fixtures.date(key, 9, $0 % 60)) }
        return Fixtures.snapshot(today: Fixtures.today(notes: notes))
    }

    func noteCount(_ s: CompassSnapshot) -> Int { s.day(key)?.notes.count ?? -1 }

    func drained(_ queue: SaveQueue) -> [SaveOutcome] {
        var all: [SaveOutcome] = []
        queue.drain { all.append($0) }
        return all
    }

    // MARK: Ordering and coalescing

    func testQueuedWritesAreCoalescedAndTheNewestIsWritten() throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        store.holdNextWrite()
        queue.enqueue(version(1))
        store.waitUntilAWriteIsHeld()
        // Three more while the first is on its way: only the newest needs writing.
        queue.enqueue(version(2))
        queue.enqueue(version(3))
        let last = queue.enqueue(version(4))
        store.release()
        queue.waitUntilIdle()

        XCTAssertEqual(noteCount(try store.load()), 4)
        XCTAssertEqual(store.inner.saveCount, 2, "version 1, then version 4 for 2–4")
        let outcomes = drained(queue)
        XCTAssertEqual(outcomes.map(\.ticket), [1, last])
        XCTAssertEqual(outcomes.map(\.write), [.succeeded, .succeeded])
        XCTAssertTrue(queue.isIdle)
    }

    func testTheLastOfManyQuickWritesIsNeverDropped() throws {
        for round in 0..<8 {
            let store = InMemoryStore(version(0))
            let queue = SaveQueue(store: store, knownStamp: nil)
            let count = 50 + round
            for n in 1...count { queue.enqueue(version(n)) }
            queue.waitUntilIdle()
            XCTAssertEqual(noteCount(try store.load()), count, "round \(round)")
            XCTAssertEqual(drained(queue).last?.ticket, UInt64(count))
        }
    }

    /// Work after writes runs once everything queued before it is on disk, in the order it was queued,
    /// and never sees an older store than the snapshot queued before it.
    func testWorkAfterWritesSeesEverythingQueuedBeforeIt() throws {
        let store = InMemoryStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        let seen = Mutex<[(order: Int, queuedBefore: Int, stored: Int, holds: Bool)]>([])
        for n in 1...200 {
            queue.enqueue(version(n))
            if n % 7 == 0 {
                let order = n
                queue.afterWrites { holds in
                    let stored = (try? store.load()).map { $0.day(Fixtures.todayKey)?.notes.count ?? -1 } ?? -1
                    seen.withLock { $0.append((order, order, stored, holds)) }
                }
            }
        }
        queue.waitUntilIdle()
        let all = seen.withLock { $0 }
        XCTAssertEqual(all.map(\.order), Array(stride(from: 7, through: 200, by: 7)))
        for s in all {
            XCTAssertGreaterThanOrEqual(s.stored, s.queuedBefore)
            XCTAssertTrue(s.holds)
        }
        XCTAssertEqual(all.map(\.stored), all.map(\.stored).sorted(), "the store never goes back")
        XCTAssertEqual(noteCount(try store.load()), 200)
    }

    // MARK: Failures and retries

    func testAFailedWriteIsReportedAndTheNextOneRetries() throws {
        let store = InMemoryStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        store.failsSaving = true
        queue.enqueue(version(1))
        queue.waitUntilIdle()
        let failed = drained(queue)
        XCTAssertEqual(failed.count, 1)
        guard case .failed = failed.first?.write else { return XCTFail("expected a failure, got \(failed)") }
        XCTAssertNil(failed.first?.modifiedAt)
        XCTAssertEqual(noteCount(try store.load()), 0, "the store kept what it had")

        store.failsSaving = false
        queue.enqueue(version(2))
        queue.waitUntilIdle()
        let ok = drained(queue)
        XCTAssertEqual(ok.map(\.write), [.succeeded])
        XCTAssertEqual(ok.first?.modifiedAt, store.modifiedAt)
        XCTAssertFalse(ok.first?.caughtUp ?? true, "a change that saves after a failure is not the becoming-active retry")
        XCTAssertEqual(noteCount(try store.load()), 2)
    }

    func testBecomingActiveRetriesAFailedWriteAndSaysWhenItCaughtUp() throws {
        let store = InMemoryStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        store.failsSaving = true
        queue.enqueue(version(1))
        queue.retryOrCheck(memory: version(1))
        queue.waitUntilIdle()
        XCTAssertFalse(drained(queue).contains { $0.write == .succeeded || $0.caughtUp })

        store.failsSaving = false
        queue.retryOrCheck(memory: version(1))
        queue.waitUntilIdle()
        let retried = drained(queue)
        XCTAssertEqual(retried.map(\.write), [.succeeded])
        XCTAssertEqual(retried.map(\.caughtUp), [true])
        XCTAssertEqual(noteCount(try store.load()), 1)

        // Nothing failed and nobody else wrote: becoming active again does nothing at all.
        let saves = store.saveCount, loads = store.loadCount
        queue.retryOrCheck(memory: version(1))
        queue.waitUntilIdle()
        XCTAssertTrue(drained(queue).isEmpty)
        XCTAssertEqual(store.saveCount, saves)
        XCTAssertEqual(store.loadCount, loads)
    }

    // MARK: The widget's writes

    func completed(_ s: CompassSnapshot, at hour: Int) -> CompassSnapshot {
        var s = s
        s.updateDay(key) {
            $0.step?.completedAt = Fixtures.date(key, hour)
            $0.step?.completionChangedAt = Fixtures.date(key, hour)
        }
        return s
    }

    func testAFileNobodyElseWroteIsNeverReadAgain() throws {
        let store = InMemoryStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        for n in 1...5 {
            queue.enqueue(version(n))
            queue.waitUntilIdle()
        }
        XCTAssertEqual(store.loadCount, 0, "every write found the stamp it left")

        // The widget writes: the next write reads the file once and takes the step's completion in.
        store.writeExternally(completed(try store.load(), at: 15), at: Date().addingTimeInterval(60))
        let loads = store.loadCount
        queue.enqueue(version(6))
        queue.waitUntilIdle()
        XCTAssertEqual(store.loadCount, loads + 1, "the write read it once")
        XCTAssertTrue(try store.load().day(key)?.step?.isDone ?? false)
        XCTAssertEqual(noteCount(try store.load()), 6)
        let outcome = try XCTUnwrap(drained(queue).last)
        XCTAssertEqual(outcome.fileChanges.flatMap { $0.day(key)?.step?.isDone }, true)
    }

    /// A completion the widget wrote is kept by a write queued before the owner took it into memory.
    func testATakenChangeIsCarriedIntoWritesQueuedBeforeItWasApplied() throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        queue.enqueue(version(1))
        queue.waitUntilIdle()
        _ = drained(queue)
        store.inner.writeExternally(completed(try store.load(), at: 15), at: Date().addingTimeInterval(60))

        store.holdNextWrite()
        queue.enqueue(version(2)) // takes the widget's completion in
        store.waitUntilAWriteIsHeld()
        store.release()
        queue.waitUntilIdle()
        // Queued from memory that doesn't have the completion yet (the outcome wasn't applied).
        queue.enqueue(version(3))
        queue.waitUntilIdle()
        XCTAssertTrue(try store.load().day(key)?.step?.isDone ?? false, "never overwritten by a write queued before it was applied")

        // Applied; memory now carries it, and undoing it later in the app wins as usual.
        _ = drained(queue)
        var undone = completed(version(4), at: 15)
        undone.updateDay(key) { $0.step?.completedAt = nil; $0.step?.completionChangedAt = Fixtures.date(key, 16) }
        queue.enqueue(undone)
        queue.waitUntilIdle()
        XCTAssertFalse(try store.load().day(key)?.step?.isDone ?? true)
    }

    func testBecomingActiveReadsWhatTheWidgetWroteOnce() throws {
        let store = InMemoryStore(version(1))
        let queue = SaveQueue(store: store, knownStamp: nil)
        queue.enqueue(version(1))
        queue.waitUntilIdle()
        _ = drained(queue)
        let widget = completed(version(1), at: 15)
        store.writeExternally(widget, at: Date().addingTimeInterval(60))
        queue.retryOrCheck(memory: version(1))
        queue.waitUntilIdle()
        let read = drained(queue)
        XCTAssertEqual(read.count, 1)
        XCTAssertNil(read.first?.write)
        XCTAssertEqual(read.first?.fileChanges, widget)
        XCTAssertEqual(read.first?.modifiedAt, store.modifiedAt)

        queue.retryOrCheck(memory: version(1))
        queue.waitUntilIdle()
        XCTAssertTrue(drained(queue).isEmpty, "read once")
    }

    func testAFileStoreSkipsTheDecodeOnlyWhileNobodyElseWrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SaveQueueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Compass/compass.json")
        let app = JSONFileStore(url: url)
        try app.save(version(0))
        let queue = SaveQueue(store: app, knownStamp: app.stamp)
        queue.enqueue(version(1))
        queue.waitUntilIdle()
        let stampAfter = app.stamp
        XCTAssertNotNil(stampAfter?.size)

        // The widget's process completes the step right away (same second): the stamp changes all the same.
        let widget = JSONFileStore(url: url)
        try widget.setStepDone(true, on: key, at: Date())
        XCTAssertNotEqual(widget.stamp, stampAfter)
        queue.enqueue(version(2))
        queue.waitUntilIdle()
        let stored = try app.load()
        XCTAssertEqual(noteCount(stored), 2)
        XCTAssertTrue(stored.day(key)?.step?.isDone ?? false, "the widget's completion was read and kept")
        XCTAssertEqual(drained(queue).map(\.write), [.succeeded, .succeeded])
    }

    // MARK: Sync's wipe record

    /// The sync state records a new wipe only after the store write holding the filtered snapshot went
    /// through; while it fails, the state file keeps the wipe it had (`WipeRecord.toSave`).
    func testAWipeIsRecordedOnlyOnceTheStoreHoldsTheFilteredSnapshot() throws {
        let old = WipeRecord(wipedAt: Fixtures.date(key, 8), appliedWipe: Fixtures.date(key, 8))
        let new = WipeRecord(wipedAt: Fixtures.date(key, 10), appliedWipe: Fixtures.date(key, 10))
        let ledger = WipeLedger(onDisk: old)
        let store = InMemoryStore(version(3))
        let queue = SaveQueue(store: store, knownStamp: nil)
        let filtered = version(0)
        let written = Mutex<[(WipeRecord, Int)]>([])
        func saveState() {
            queue.afterWrites { holds in
                let record = ledger.record(new, storeHoldsModel: holds)
                let stored = (try? store.load()).map { $0.day(Fixtures.todayKey)?.notes.count ?? -1 } ?? -1
                written.withLock { $0.append((record, stored)) }
            }
        }

        store.failsSaving = true
        queue.enqueue(filtered)
        saveState()
        queue.waitUntilIdle()
        XCTAssertEqual(ledger.recorded, old, "the store still holds the pre-wipe snapshot")

        store.failsSaving = false
        queue.retryOrCheck(memory: filtered)
        saveState()
        queue.waitUntilIdle()
        XCTAssertEqual(ledger.recorded, new)
        let all = written.withLock { $0 }
        XCTAssertEqual(all.map(\.0), [old, new])
        XCTAssertEqual(all.last?.1, 0, "recorded after the filtered snapshot was on disk")
    }

    func testWorkAfterADroppedWriteIsToldTheStoreDoesNotHoldIt() throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        store.holdNextWrite()
        queue.enqueue(version(1))
        store.waitUntilAWriteIsHeld()
        queue.enqueue(version(2))
        let told = Mutex<Bool?>(nil)
        queue.afterWrites { holds in told.withLock { $0 = holds } }
        let done = expectation(description: "discarded")
        DispatchQueue.global().async {
            queue.discardPendingWrites()
            done.fulfill()
        }
        // Version 2 is dropped before the held write finishes.
        while queue.hasPendingWrite { Thread.sleep(forTimeInterval: 0.001) }
        store.release()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(noteCount(try store.load()), 1, "version 2 was dropped")
        XCTAssertEqual(told.withLock { $0 }, false)

        // Delete everything: the store is replaced, no outcome from before is left to apply.
        queue.replacingContents { try? store.save(.empty) }
        XCTAssertEqual(try store.load(), .empty)
        XCTAssertTrue(drained(queue).isEmpty)
        queue.enqueue(version(5))
        queue.afterWrites { holds in told.withLock { $0 = holds } }
        queue.waitUntilIdle()
        XCTAssertEqual(noteCount(try store.load()), 5)
        XCTAssertEqual(told.withLock { $0 }, true)
    }

    // MARK: Flushing

    func testWaitingAndCallingBackWhenIdle() throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        let notified = Mutex(0)
        queue.setNotify { notified.withLock { $0 += 1 } }
        store.holdNextWrite()
        queue.enqueue(version(1))
        store.waitUntilAWriteIsHeld()
        queue.enqueue(version(2))
        let idle = expectation(description: "idle")
        let storedWhenIdle = Mutex(-1)
        queue.whenIdle {
            storedWhenIdle.withLock { $0 = (try? store.load()).map { $0.day(Fixtures.todayKey)?.notes.count ?? -1 } ?? -1 }
            idle.fulfill()
        }
        XCTAssertFalse(queue.isIdle)
        store.release()
        wait(for: [idle], timeout: 5)
        XCTAssertEqual(storedWhenIdle.withLock { $0 }, 2, "called back after the last write")
        queue.waitUntilIdle()
        XCTAssertTrue(queue.isIdle)
        XCTAssertEqual(notified.withLock { $0 }, 2, "once per outcome")
        XCTAssertEqual(drained(queue).count, 2)
    }
}
