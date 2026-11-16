import Foundation
import XCTest
@testable import CompassCore

/// Round-8 sync review. N1: the wiping device holds its wipe date in memory exactly as every file has it
/// (whole seconds), so the exemption for envelopes that carried the wipe out holds there in the same
/// process. N2: the sync state file never records a wipe the store file doesn't hold. Also dates held in
/// memory with fractions of a second elsewhere (the evening entry's `createdAt` keys E5).
final class SyncRound8Tests: XCTestCase {
    let cal = Fixtures.calendar
    let key = DayKey(year: 2026, month: 11, day: 10)
    func d(_ h: Int, _ m: Int = 0) -> Date { key.date(in: cal, hour: h, minute: m) }
    func goalID(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    /// Through a file, the way every other device (and this one after a relaunch) reads it.
    func file<T: Codable>(_ value: T) -> T {
        try! JSONFileStore.decoder().decode(T.self, from: JSONFileStore.encoder().encode(value))
    }

    func env(_ id: String, _ snapshot: CompassSnapshot, savedAt: Date, wipedAt: Date? = nil) -> SyncEnvelope {
        SyncEnvelope(deviceID: id, deviceName: id, savedAt: savedAt, snapshot: snapshot, wipedAt: wipedAt)
    }

    func startedDay(goal: UUID?, at now: Date) -> Day {
        Day(key: key, goalID: goal, intention: Intention(text: "today", createdAt: now), step: Step(title: "step", createdAt: now),
            notes: [Note(text: "memo", duration: 12, createdAt: now)],
            reflection: Reflection(outcome: .moved, transcript: "evening", duration: 30, createdAt: now, audioFileName: "e.m4a"))
    }

    func show(_ s: CompassSnapshot) -> String {
        "cur=\(s.goal?.text ?? "nil") days=\(s.days.count) audio=\(s.referencedAudioFiles.count)"
    }

    // MARK: N1

    /// A wipe date is a whole second, never before `now` or the newest stamp it deletes, and a marker
    /// dated by it reads back from a file unchanged, so the exemption holds between the in-memory value and
    /// the file's.
    func testAWipeDateIsAWholeSecondThatReadsBackUnchanged() {
        let g = Goal(id: goalID(1), text: "G", createdAt: d(7))
        for frac in [0.0, 0.001, 0.2, 0.5, 0.7, 0.999] {
            let now = d(10).addingTimeInterval(frac)
            let wipe = env("A", CompassSnapshot(goal: g), savedAt: d(8)).wipeDate(now: now)
            XCTAssertEqual(wipe.timeIntervalSinceReferenceDate, wipe.timeIntervalSinceReferenceDate.rounded(), "frac \(frac)")
            XCTAssertGreaterThanOrEqual(wipe, now)
            XCTAssertLessThan(wipe.timeIntervalSince(now), 1)

            let marker = env("A", .empty, savedAt: wipe, wipedAt: wipe)
            let read = file(marker)
            XCTAssertEqual(read.wipedAt, wipe, "frac \(frac)")
            XCTAssertEqual(read, marker)
            // Another device's envelope that carried this wipe out, read from its file, is taken whole
            // against the wipe as this device holds it in memory.
            let after = file(env("B", CompassSnapshot(goal: Goal(id: goalID(2), text: "N", createdAt: d(9, 53))),
                                 savedAt: d(9, 55), wipedAt: read.wipedAt))
            XCTAssertEqual(SnapshotMerger.applyingWipe(wipe, to: after), after, "frac \(frac)")
        }
        // Stamped later than the clock (a fast clock elsewhere): one second after it, still whole.
        var s = CompassSnapshot(goal: g)
        s.goal?.updatedAt = d(11).addingTimeInterval(0.4)
        let wipe = env("A", s, savedAt: d(8)).wipeDate(now: d(10).addingTimeInterval(0.3))
        XCTAssertEqual(wipe, d(11).addingTimeInterval(2))
        XCTAssertEqual(file(env("A", .empty, savedAt: wipe, wipedAt: wipe)).wipedAt, wipe)
    }

    /// Probe F1: A deletes everything at 10:00:00.x. B, 10 minutes slow, is erased and the user starts over
    /// on B. A, in the same process as the wipe (its state holds the wipe as `wipeDate` returned it), gets
    /// B's new goal, day and recordings, exactly as after a relaunch.
    func testF1_theWipingDeviceKeepsWhatASlowDeviceMakesAfterTheWipeInTheSameProcess() {
        let g = Goal(id: goalID(1), text: "G", createdAt: d(7))
        for frac in [0.0, 0.2, 0.7] {
            let wipe = env("A", CompassSnapshot(goal: g), savedAt: d(8)).wipeDate(now: d(10).addingTimeInterval(frac))
            let marker = file(env("A", .empty, savedAt: wipe, wipedAt: wipe))

            let erase = SyncApply.plan(SyncApplyInput(local: env("B", CompassSnapshot(goal: g), savedAt: d(8)),
                                                      remote: [marker], now: d(9, 51)))!
            XCTAssertEqual(erase.action, .eraseLocal)
            var s = CompassSnapshot(goal: Goal(id: goalID(2), text: "N", createdAt: d(9, 53)))
            s.days = [startedDay(goal: s.goal?.id, at: d(9, 55))]
            let b = file(env("B", s, savedAt: d(9, 55), wipedAt: erase.merged.wipedAt))
            let bNext = SyncApply.plan(SyncApplyInput(local: b, remote: [marker], appliedWipe: erase.merged.wipedAt, now: d(9, 57)))!
            XCTAssertEqual(bNext.action, .keep, "frac \(frac)")

            let aInMemory = env("A", .empty, savedAt: wipe, wipedAt: wipe)
            let a = SyncApply.plan(SyncApplyInput(local: aInMemory, remote: [marker, b], appliedWipe: wipe, now: d(10, 8)))!
            XCTAssertEqual(show(a.merged.snapshot), "cur=N days=1 audio=2", "frac \(frac)")
            let relaunched = file(aInMemory)
            let aLater = SyncApply.plan(SyncApplyInput(local: relaunched, remote: [marker, b], appliedWipe: relaunched.wipedAt, now: d(10, 8)))!
            XCTAssertEqual(aLater.merged.snapshot, a.merged.snapshot, "frac \(frac)")
        }
    }

    // MARK: N2

    /// Probe F2: B hears of A's wipe and adopts the filtered snapshot, but the store write fails (or the app
    /// ends before it). The state file keeps the wipe it had, so on relaunch B's stale store is filtered
    /// again and A doesn't get the deleted goal back. Once the store write goes through, the wipe is
    /// recorded and nothing pre-wipe is left to exempt.
    func testF2_theStateFileNeverRecordsAWipeTheStoreDoesNotHold() {
        let g = Goal(id: goalID(1), text: "G", createdAt: d(7))
        var old = CompassSnapshot(goal: g)
        old.days = [startedDay(goal: g.id, at: d(8))]
        let marker = file(env("A", .empty, savedAt: d(10), wipedAt: d(10)))
        let onDisk = WipeRecord(wipedAt: nil, appliedWipe: nil)

        // B carries out the wipe: some of what it holds survives (a goal it set after the wipe).
        var bSnap = old
        bSnap.pastGoals = [Goal(id: goalID(3), text: "P", createdAt: d(10, 1), status: .replaced, endedAt: d(10, 2))]
        let plan = SyncApply.plan(SyncApplyInput(local: env("B", bSnap, savedAt: d(10, 2)), remote: [marker], now: d(10, 5)))!
        guard case .adopt(let filtered, _) = plan.action else { return XCTFail("\(plan.action)") }
        XCTAssertTrue(plan.newWipe)
        let inMemory = WipeRecord(wipedAt: plan.merged.wipedAt, appliedWipe: plan.merged.wipedAt)

        // The store write failed: the state file keeps the old wipe.
        let kept = WipeRecord.toSave(inMemory: inMemory, onDisk: onDisk, storeHoldsModel: false)
        XCTAssertEqual(kept, onDisk)
        let relaunched = file(env("B", bSnap, savedAt: d(10, 2), wipedAt: kept.wipedAt))
        let bAgain = SyncApply.plan(SyncApplyInput(local: relaunched, remote: [marker], appliedWipe: kept.appliedWipe, now: d(10, 6)))!
        XCTAssertEqual(bAgain.merged.snapshot.goal, nil, "the stale store is filtered again")
        XCTAssertTrue(bAgain.merged.snapshot.days.isEmpty)
        let a = SyncApply.plan(SyncApplyInput(local: marker, remote: [relaunched], appliedWipe: d(10), now: d(10, 7)))!
        XCTAssertNil(a.merged.snapshot.goal, "A doesn't get the deleted goal back")
        XCTAssertEqual(a.merged.snapshot.referencedAudioFiles, [])
        XCTAssertEqual(a.merged.snapshot.pastGoals.map(\.text), ["P"])

        // The store write went through: the wipe is recorded, and the store holds only survivors.
        let saved = WipeRecord.toSave(inMemory: inMemory, onDisk: onDisk, storeHoldsModel: true)
        XCTAssertEqual(saved, inMemory)
        let b = file(env("B", filtered, savedAt: d(10, 2), wipedAt: saved.wipedAt))
        let a2 = SyncApply.plan(SyncApplyInput(local: marker, remote: [b], appliedWipe: d(10), now: d(10, 7)))!
        XCTAssertNil(a2.merged.snapshot.goal)
        XCTAssertEqual(a2.merged.snapshot.pastGoals.map(\.text), ["P"])

        // What the reviewer's probe showed before: the state file ahead of the store brings G back.
        let ahead = file(env("B", old, savedAt: d(8), wipedAt: d(10)))
        let broken = SyncApply.plan(SyncApplyInput(local: marker, remote: [ahead], appliedWipe: d(10), now: d(10, 7)))!
        XCTAssertEqual(broken.merged.snapshot.goal?.text, "G", "the state `toSave` never writes")
    }

    // MARK: Dates held in memory

    /// `asStored` gives exactly what a file reads back: fractions of a second are gone.
    func testAsStoredIsWhatAFileReadsBack() {
        var s = CompassSnapshot(goal: Goal(id: goalID(1), text: "G", createdAt: d(7).addingTimeInterval(0.4)))
        s.days = [startedDay(goal: s.goal?.id, at: d(21).addingTimeInterval(0.7))]
        let stored = JSONFileStore.asStored(s)
        XCTAssertEqual(stored, file(s))
        XCTAssertNotEqual(stored, s)
        XCTAssertEqual(JSONFileStore.asStored(stored), stored)
        XCTAssertEqual(stored.days[0].reflection?.createdAt.timeIntervalSince(d(21)), 0)
    }

    /// Data already in whole seconds (everything read from a file, every fixture) is unchanged by it, so
    /// `AppModel.commit` changes nothing but the fractions.
    func testAsStoredLeavesWholeSecondDataAlone() {
        for id in ScreenID.allCases {
            let s = Fixtures.fixture(for: id).snapshot
            XCTAssertEqual(JSONFileStore.asStored(s), s, "\(id)")
        }
        XCTAssertEqual(JSONFileStore.asStored(Fixtures.restorableSnapshot), Fixtures.restorableSnapshot)
    }

    /// A records the evening at 21:00:00.7 and B at 21:05; A resolves E5 in the same process. With A's
    /// entry held as the file has it (`AppModel.commit` keeps the snapshot `asStored`), the note it becomes
    /// has the id every device derives from that entry, and the choice holds on both devices. Held with the
    /// fraction, the conflict came back on both and the words were kept twice.
    func testE5ResolvedOnTheRecordingDeviceStaysResolved() {
        let rA = Reflection(outcome: .moved, transcript: "A", createdAt: d(21).addingTimeInterval(0.7), deviceID: "A")
        let rB = Reflection(outcome: .moved, transcript: "B", createdAt: d(21, 5), deviceID: "B")
        var dayA = Day(key: key, goalID: nil); dayA.reflection = rA
        var dayB = Day(key: key, goalID: nil); dayB.reflection = rB
        var aSnap = CompassSnapshot(); aSnap.days = [dayA]
        aSnap = JSONFileStore.asStored(aSnap)
        var bSnap = CompassSnapshot(); bSnap.days = [dayB]
        bSnap = file(bSnap)

        let onB = SyncApply.plan(SyncApplyInput(local: env("B", bSnap, savedAt: d(21, 5)), remote: [file(env("A", aSnap, savedAt: d(21)))]))!
        if case .adopt(let s, _) = onB.action { bSnap = s }
        XCTAssertTrue(bSnap.days[0].hasConflict)
        let onA = SyncApply.plan(SyncApplyInput(local: env("A", aSnap, savedAt: d(21)), remote: [file(env("B", bSnap, savedAt: d(21, 5)))]))!
        guard case .adopt(var resolved, _) = onA.action else { return XCTFail() }
        XCTAssertTrue(resolved.days[0].hasConflict)
        resolved.days[0].resolveConflict(keeping: rB)

        let bNext = SyncApply.plan(SyncApplyInput(local: env("B", bSnap, savedAt: d(21, 5)), remote: [file(env("A", resolved, savedAt: d(21, 10)))]))!
        var b2 = bSnap; if case .adopt(let s, _) = bNext.action { b2 = s }
        XCTAssertFalse(b2.days[0].hasConflict)
        XCTAssertEqual(b2.days[0].notes.count, 1)
        let aNext = SyncApply.plan(SyncApplyInput(local: env("A", resolved, savedAt: d(21, 10)), remote: [file(env("B", b2, savedAt: d(21, 5)))]))!
        var a2 = resolved; if case .adopt(let s, _) = aNext.action { a2 = s }
        XCTAssertFalse(a2.days[0].hasConflict)
        XCTAssertEqual(a2.days[0].notes.count, 1)
        XCTAssertEqual(a2, b2)
    }

    /// The same intention edited on both devices within one second. Held as the files have them, both
    /// devices compare equal times and pick the same version (by the envelope order); held with fractions,
    /// each kept its own until a relaunch.
    func testAnEditInTheSameSecondOnTwoDevicesConverges() {
        let base = Intention(text: "x", createdAt: d(8))
        var iA = base; iA.text = "A"; iA.updatedAt = d(9).addingTimeInterval(0.7)
        var iB = base; iB.text = "B"; iB.updatedAt = d(9).addingTimeInterval(0.3)
        var dayA = Day(key: key, goalID: nil); dayA.intention = iA
        var dayB = Day(key: key, goalID: nil); dayB.intention = iB
        var sA = CompassSnapshot(); sA.days = [dayA]
        var sB = CompassSnapshot(); sB.days = [dayB]
        let a = JSONFileStore.asStored(env("A", sA, savedAt: d(9).addingTimeInterval(0.7)))
        let b = JSONFileStore.asStored(env("B", sB, savedAt: d(9).addingTimeInterval(0.3)))
        let onA = SnapshotMerger.merge([a, file(b)])!.snapshot
        let onB = SnapshotMerger.merge([b, file(a)])!.snapshot
        XCTAssertEqual(onA, onB)
    }
}
