import Foundation
import Dispatch
import XCTest
@testable import CompassCore

/// Stands in for UIKit's background tasks: hands out identifiers, keeps each expiration handler, and
/// records what was begun and ended.
@MainActor
final class FakeBackgroundTasks {
    var begun: [Int] = []
    var ended: [Int] = []
    var expirations: [Int: @MainActor @Sendable () -> Void] = [:]
    /// iOS gives no task (`.invalid`).
    var refuse = false
    /// iOS runs the expiration handler before `begin` returns.
    var expireAtOnce = false
    /// Runs as each task ends (to look at the store then).
    var onEnd: (Int) -> Void = { _ in }
    private var next = 100

    var held: Int { begun.count - ended.count }
    private(set) var mostHeld = 0

    func begin(_ expired: @escaping @MainActor @Sendable () -> Void) -> Int? {
        if refuse { return nil }
        next += 1
        begun.append(next)
        expirations[next] = expired
        mostHeld = max(mostHeld, held)
        if expireAtOnce { expired() }
        return next
    }

    func end(_ id: Int) {
        XCTAssertTrue(begun.contains(id), "ended a task never begun")
        XCTAssertFalse(ended.contains(id), "ended twice")
        ended.append(id)
        onEnd(id)
    }

    func expire(_ id: Int) { expirations[id]?() }
}

/// `SaveBackgroundGuard`: a background task while the save queue has work and the app is not active,
/// begun on the first busy spell in the background, one at a time, ended when the queue is idle or when
/// iOS's time runs out, never while the app is active.
@MainActor
final class SaveBackgroundGuardTests: XCTestCase {
    let key = Fixtures.todayKey

    func version(_ n: Int) -> CompassSnapshot {
        let notes = (0..<n).map { Note(text: "note \($0)", createdAt: Fixtures.date(key, 9, $0 % 60)) }
        return Fixtures.snapshot(today: Fixtures.today(notes: notes))
    }

    func noteCount(_ store: Store) -> Int { (try? store.load())?.day(key)?.notes.count ?? -1 }

    final class AppState {
        var active: Bool
        init(active: Bool) { self.active = active }
    }

    func makeGuard(_ queue: SaveQueue, _ tasks: FakeBackgroundTasks, _ app: AppState) -> SaveBackgroundGuard {
        SaveBackgroundGuard(queue: queue, isActive: { app.active },
                            begin: { tasks.begin($0) }, end: { tasks.end($0) })
    }

    /// Let the main actor run what the worker sent it (the idle report) for a moment.
    func settle() async throws {
        for _ in 0..<50 { try await Task.sleep(nanoseconds: 1_000_000) }
    }

    /// Let the main actor run until `condition` holds, or 5 s.
    func settle(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    }

    // MARK: Foreground

    func testNoTaskWhileTheAppIsActive() async throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: true)
        let guarded = makeGuard(queue, tasks, app)
        store.holdNextWrite()
        queue.enqueue(version(1))
        store.waitUntilAWriteIsHeld()
        queue.enqueue(version(2))
        guarded.check()
        XCTAssertEqual(tasks.begun, [])
        store.release()
        queue.waitUntilIdle()
        try await settle()
        XCTAssertEqual(tasks.begun, [])
        XCTAssertFalse(guarded.isHolding)
    }

    func testNoTaskWhenTheQueueIsIdle() async throws {
        let queue = SaveQueue(store: InMemoryStore(version(0)), knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: false)
        let guarded = makeGuard(queue, tasks, app)
        guarded.check() // entering the background with nothing queued
        XCTAssertEqual(tasks.begun, [])
        XCTAssertFalse(guarded.isHolding)
    }

    // MARK: Background

    /// A write queued while the app is in the background (an evening summary arriving): one task from the
    /// moment it is queued, however much more is queued, ended only once everything is written.
    func testAWriteQueuedInTheBackgroundIsCoveredUntilTheQueueIsIdle() async throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: false)
        let guarded = makeGuard(queue, tasks, app)
        var storedAtEnd = -1
        tasks.onEnd = { _ in storedAtEnd = self.noteCount(store) }
        store.holdNextWrite()
        queue.enqueue(version(1))
        XCTAssertEqual(tasks.begun.count, 1, "begun as the write is queued")
        XCTAssertTrue(guarded.isHolding)
        store.waitUntilAWriteIsHeld()
        queue.enqueue(version(2))
        queue.afterWrites { _ in }
        queue.enqueue(version(3))
        guarded.check()
        XCTAssertEqual(tasks.begun.count, 1, "one task while busy")
        store.release()
        try await settle(until: { tasks.ended.count == 1 })
        XCTAssertEqual(tasks.ended, tasks.begun)
        XCTAssertEqual(storedAtEnd, 3, "ended after the last write")
        XCTAssertTrue(queue.isIdle)
        XCTAssertFalse(guarded.isHolding)
        XCTAssertEqual(tasks.mostHeld, 1)
    }

    /// Work queued after the queue reported idle but before the main actor heard it keeps the same task.
    func testWorkQueuedWhileTheIdleReportIsOnItsWayKeepsTheTask() async throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: false)
        let guarded = makeGuard(queue, tasks, app)
        queue.enqueue(version(1))
        queue.waitUntilIdle() // the idle report is queued for the main actor, which hasn't run it yet
        store.holdNextWrite()
        queue.enqueue(version(2))
        store.waitUntilAWriteIsHeld()
        try await settle() // the idle report arrives: the queue is busy again
        XCTAssertTrue(guarded.isHolding)
        XCTAssertEqual(tasks.begun.count, 1)
        XCTAssertEqual(tasks.ended, [])
        store.release()
        try await settle(until: { tasks.ended.count == 1 })
        XCTAssertEqual(tasks.ended, tasks.begun)
        XCTAssertEqual(noteCount(store), 2)
    }

    /// Writes queued while the app was active and still running when it enters the background.
    func testEnteringTheBackgroundWithWritesQueuedBeginsATask() async throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: true)
        let guarded = makeGuard(queue, tasks, app)
        store.holdNextWrite()
        queue.enqueue(version(1))
        store.waitUntilAWriteIsHeld()
        XCTAssertEqual(tasks.begun, [])
        app.active = false
        guarded.check() // didEnterBackground
        guarded.check()
        XCTAssertEqual(tasks.begun.count, 1)
        store.release()
        try await settle(until: { tasks.ended.count == 1 })
        XCTAssertEqual(tasks.ended, tasks.begun)
    }

    /// Each busy spell in the background gets its own task, never more than one at a time.
    func testEachBusySpellInTheBackgroundHasItsOwnTask() async throws {
        let queue = SaveQueue(store: InMemoryStore(version(0)), knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: false)
        let guarded = makeGuard(queue, tasks, app)
        for n in 1...5 {
            queue.enqueue(version(n))
            try await settle(until: { tasks.ended.count == n && queue.isIdle })
        }
        XCTAssertEqual(tasks.begun.count, 5)
        XCTAssertEqual(tasks.ended, tasks.begun)
        XCTAssertEqual(tasks.mostHeld, 1)
        XCTAssertFalse(guarded.isHolding)
    }

    // MARK: Expiration

    /// iOS's time runs out: the task is ended then, once; more work in the same busy spell begins nothing,
    /// and the idle report after it ends nothing again. The next busy spell begins a new one.
    func testExpirationEndsTheTaskOnceAndNothingStacks() async throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: false)
        let guarded = makeGuard(queue, tasks, app)
        store.holdNextWrite()
        queue.enqueue(version(1))
        store.waitUntilAWriteIsHeld()
        let first = try XCTUnwrap(tasks.begun.first)
        tasks.expire(first)
        XCTAssertEqual(tasks.ended, [first])
        XCTAssertFalse(guarded.isHolding)
        tasks.expire(first)
        XCTAssertEqual(tasks.ended, [first], "a second expiration call ends nothing")
        queue.enqueue(version(2))
        XCTAssertEqual(tasks.begun, [first], "still the same busy spell")
        store.release()
        queue.waitUntilIdle()
        try await settle()
        XCTAssertEqual(tasks.ended, [first], "the idle report ends nothing again")

        queue.enqueue(version(3))
        XCTAssertEqual(tasks.begun.count, 2)
        try await settle(until: { tasks.ended.count == 2 })
        XCTAssertEqual(tasks.ended, tasks.begun)
        XCTAssertEqual(tasks.mostHeld, 1)
        tasks.expire(first)
        XCTAssertEqual(tasks.ended.count, 2, "an old expiration handler ends nothing")
    }

    /// The expiration handler runs before `begin` returns (no time left): the task is ended at once.
    func testAnExpirationDuringBeginEndsTheTaskAtOnce() async throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: false)
        tasks.expireAtOnce = true
        let guarded = makeGuard(queue, tasks, app)
        store.holdNextWrite()
        queue.enqueue(version(1))
        XCTAssertEqual(tasks.begun.count, 1)
        XCTAssertEqual(tasks.ended, tasks.begun)
        XCTAssertFalse(guarded.isHolding)
        store.waitUntilAWriteIsHeld()
        store.release()
        queue.waitUntilIdle()
        try await settle()
        XCTAssertEqual(tasks.ended, tasks.begun)
    }

    /// iOS gives no task: nothing is held and nothing is ended.
    func testARefusedTaskIsNeverEnded() async throws {
        let queue = SaveQueue(store: InMemoryStore(version(0)), knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: false)
        tasks.refuse = true
        let guarded = makeGuard(queue, tasks, app)
        queue.enqueue(version(1))
        XCTAssertFalse(guarded.isHolding)
        queue.waitUntilIdle()
        try await settle()
        XCTAssertEqual(tasks.ended, [])
    }

    // MARK: Threads

    /// Queued off the main thread: the busy report hops to the main actor and still begins a task.
    func testWorkQueuedOffTheMainThreadIsCoveredToo() async throws {
        let store = GatedStore(version(0))
        let queue = SaveQueue(store: store, knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: false)
        let guarded = makeGuard(queue, tasks, app)
        store.holdNextWrite()
        let snapshot = version(1)
        DispatchQueue.global().async { queue.enqueue(snapshot) }
        store.waitUntilAWriteIsHeld()
        try await settle(until: { tasks.begun.count == 1 })
        XCTAssertEqual(tasks.begun.count, 1)
        XCTAssertEqual(tasks.ended, [])
        store.release()
        try await settle(until: { tasks.ended.count == 1 })
        XCTAssertEqual(tasks.ended, tasks.begun)
        XCTAssertFalse(guarded.isHolding)
    }

    /// The guard going away stops the reports reaching it (the queue holds it weakly).
    func testTheQueueDoesNotKeepTheGuardAlive() async throws {
        let queue = SaveQueue(store: InMemoryStore(version(0)), knownStamp: nil)
        let tasks = FakeBackgroundTasks(), app = AppState(active: false)
        weak var weakGuard: SaveBackgroundGuard?
        do {
            let guarded = makeGuard(queue, tasks, app)
            weakGuard = guarded
        }
        XCTAssertNil(weakGuard)
        queue.enqueue(version(1))
        queue.waitUntilIdle()
        try await settle()
        XCTAssertEqual(tasks.begun, [])
    }
}
