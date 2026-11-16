import Foundation
import XCTest
@testable import CompassCore

/// Round-7 sync review: "Delete everything" when clocks disagree (W1). A device that has carried out a wipe
/// keeps what it makes next, whatever its clock says, and a wipe is dated after everything the wiping
/// device deletes. Also the end date of a goal two devices ended as replaced (W2). Runs on the same devices
/// and iCloud as `SyncRound4Tests`.
final class SyncRound7Tests: XCTestCase {
    typealias World = SyncRound4Tests.World
    typealias Device = SyncRound4Tests.Device
    func d(_ h: Int, _ m: Int = 0) -> Date { SyncRound4Tests.d(h, m) }
    func goalID(_ n: Int) -> UUID { SyncRound4Tests.goalID(n) }
    let key = SyncRound4Tests.key
    let day: TimeInterval = 24 * 60 * 60

    /// The user starts the day on device `i` at `now`: intention, step, a spoken memo and a recorded evening.
    func startDay(_ w: inout World, _ i: Int, at now: Date) {
        let goal = w.devices[i].snapshot.goal?.id
        w.devices[i].change(at: now) { s in
            s.days.append(Day(key: key, goalID: goal, intention: Intention(text: "today", createdAt: now),
                              step: Step(title: "step", createdAt: now),
                              notes: [Note(text: "memo", duration: 12, createdAt: now)],
                              reflection: Reflection(outcome: .moved, transcript: "evening", duration: 30, createdAt: now,
                                                     audioFileName: "evening.m4a")))
        }
    }

    /// The goal, and whether the day still holds its intention, step, memo and evening entry.
    func show(_ w: World, _ i: Int) -> String {
        let s = w.devices[i].snapshot
        let days = s.days.map { "\($0.key.day): i=\($0.intention != nil) s=\($0.step != nil) n=\($0.notes.count) r=\($0.reflection != nil)" }
        return "cur=\(s.goal?.text ?? "nil") days=\(days)"
    }

    /// Probe X1: A wipes at 10:00. B, whose clock is 10 minutes slow, hears of it and is erased; the user
    /// starts over on B at what B calls 9:53. B carried the wipe out, so its next pass keeps the new goal,
    /// the day and both recordings, and A gets them too.
    func testX1_aSlowDeviceKeepsWhatItMakesAfterCarryingOutTheWipe() {
        let g = Goal(id: goalID(1), text: "G", createdAt: d(7))
        var w = World([Device("A", CompassSnapshot(goal: g), savedAt: d(8)),
                       Device("B", CompassSnapshot(goal: g), savedAt: d(8))])
        w.push(0); w.push(1)
        w.wipe(0, at: d(10))
        XCTAssertEqual(w.pull(1, at: d(9, 51)), .eraseLocal)
        XCTAssertEqual(w.devices[1].appliedWipe, d(10))

        w.setGoal(1, "N", at: d(9, 53))
        startDay(&w, 1, at: d(9, 55))
        w.push(1)
        let recordings = w.devices[1].snapshot.referencedAudioFiles
        XCTAssertEqual(recordings.count, 2)

        w.pull(1, at: d(9, 57))
        XCTAssertEqual(show(w, 1), "cur=N days=[\"10: i=true s=true n=1 r=true\"]")
        XCTAssertEqual(w.devices[1].snapshot.referencedAudioFiles, recordings, "no recording dropped")
        w.push(1)
        w.pull(0, at: d(10, 8))
        XCTAssertEqual(show(w, 0), "cur=N days=[\"10: i=true s=true n=1 r=true\"]")

        XCTAssertTrue(w.settle(from: d(10, 10), offsets: [0, -600]), "\(w.log)")
        XCTAssertTrue(w.converged, show(w, 0) + " | " + show(w, 1))
        XCTAssertNil(w.wipeViolation())
    }

    /// Probe X2: one device, whose clock was an hour fast when it wiped and was corrected afterwards. What
    /// the user makes next is dated before the wipe and stays.
    func testX2_oneDeviceWhoseClockWasCorrectedAfterTheWipe() {
        var w = World([Device("A", CompassSnapshot(goal: Goal(id: goalID(1), text: "G", createdAt: d(7))), savedAt: d(8))])
        w.push(0)
        w.wipe(0, at: d(10))
        w.setGoal(0, "N", at: d(9, 5))
        startDay(&w, 0, at: d(9, 10))
        w.push(0)
        XCTAssertEqual(w.pull(0, at: d(9, 12)), .keep)
        XCTAssertEqual(show(w, 0), "cur=N days=[\"10: i=true s=true n=1 r=true\"]")
        XCTAssertNil(w.wipeViolation())
    }

    /// Probe X3: A's clock is a day fast. A wipes, then sets N and starts a day. B syncs them, then deletes
    /// everything on a correct clock. The wipe is dated after N, so N and its day stay deleted on both.
    func testX3_aWipeIsDatedAfterEverythingItDeletes() {
        let g = Goal(id: goalID(1), text: "G", createdAt: d(7))
        var w = World([Device("A", CompassSnapshot(goal: g), savedAt: d(8)),
                       Device("B", CompassSnapshot(goal: g), savedAt: d(8))])
        w.push(0); w.push(1)
        w.wipe(0, at: d(10) + day)
        w.setGoal(0, "N", at: d(10, 5) + day)
        startDay(&w, 0, at: d(10, 6) + day)
        w.push(0)
        w.pull(1, at: d(10, 10))
        XCTAssertEqual(show(w, 1), "cur=N days=[\"10: i=true s=true n=1 r=true\"]")
        w.push(1)

        w.wipe(1, at: d(10, 20))
        XCTAssertEqual(w.devices[1].wipedAt, d(10, 6) + day + 1, "one second after the newest thing deleted")

        w.push(0)
        XCTAssertEqual(w.log.last, "push0-deferred", "A hasn't carried out B's wipe yet")
        XCTAssertEqual(w.pull(0, at: d(10, 25) + day), .eraseLocal)
        w.pull(1, at: d(10, 30))
        XCTAssertTrue(w.settle(from: d(10, 30), offsets: [day, 0]), "\(w.log)")
        for i in 0..<2 { XCTAssertEqual(show(w, i), "cur=nil days=[]") }
        XCTAssertNil(w.wipeViolation())
    }

    /// The merge filters an envelope by a wipe only when the envelope doesn't carry that wipe yet: one with no
    /// wipe or an older one is filtered, one that carries it (or a newer one) is kept whole.
    func testOnlyAnEnvelopeThatHasNotCarriedOutTheWipeIsFiltered() throws {
        let wipe = d(10)
        let early = CompassSnapshot(goal: Goal(id: goalID(1), text: "early", createdAt: d(9, 50)))
        func envelope(_ id: String, wipedAt: Date?) -> SyncEnvelope {
            SyncEnvelope(deviceID: id, deviceName: id, savedAt: d(9, 55), snapshot: early,
                         tombstones: [DayTombstone(key: key, deletedAt: d(9, 52))], wipedAt: wipedAt,
                         audioTombstones: [AudioTombstone(name: "x.m4a", deletedAt: d(9, 52))])
        }
        for older in [nil, d(9)] {
            let out = SnapshotMerger.applyingWipe(wipe, to: envelope("B", wipedAt: older))
            XCTAssertNil(out.snapshot.goal, "made before the wipe on a device that hadn't carried it out")
            XCTAssertEqual(out.tombstones, [])
            XCTAssertEqual(out.audioTombstones, [])
            XCTAssertEqual(out.wipedAt, wipe)
        }
        for carried in [wipe, d(11)] {
            XCTAssertEqual(SnapshotMerger.applyingWipe(wipe, to: envelope("B", wipedAt: carried)), envelope("B", wipedAt: carried))
        }

        // Through the full merge, in both orders: A's marker carries the wipe; B carried it out too.
        let marker = SyncEnvelope(deviceID: "A", deviceName: "A", savedAt: wipe, snapshot: .empty, wipedAt: wipe)
        for envelopes in [[marker, envelope("B", wipedAt: wipe)], [envelope("B", wipedAt: wipe), marker]] {
            XCTAssertEqual(try XCTUnwrap(SnapshotMerger.merge(envelopes)).snapshot.goal?.text, "early")
        }
        for envelopes in [[marker, envelope("B", wipedAt: d(9))], [envelope("B", wipedAt: nil), marker]] {
            XCTAssertNil(try XCTUnwrap(SnapshotMerger.merge(envelopes)).snapshot.goal)
        }
    }

    /// `wipeDate`: the device's clock, unless it knows a wipe that late or holds something stamped that late;
    /// then one second after the latest of those.
    func testWipeDateIsAfterTheKnownWipeAndEverythingDeleted() {
        let now = d(10)
        func env(_ snapshot: CompassSnapshot = .empty, wipedAt: Date? = nil, tombstones: [DayTombstone] = [],
                 audio: [AudioTombstone] = []) -> SyncEnvelope {
            SyncEnvelope(deviceID: "A", deviceName: "A", savedAt: d(9), snapshot: snapshot, tombstones: tombstones,
                         wipedAt: wipedAt, audioTombstones: audio)
        }
        var past = Goal(id: goalID(2), text: "P", createdAt: d(6))
        past.status = .replaced
        past.endedAt = d(7)
        var held = CompassSnapshot(goal: Goal(id: goalID(1), text: "G", createdAt: d(8)), pastGoals: [past])
        held.days = [Day(key: key, intention: Intention(text: "i", createdAt: d(8, 30)), step: Step(title: "s", createdAt: d(8, 40)),
                         notes: [Note(text: "n", createdAt: d(8, 50))])]

        // Clocks agree: the wipe is dated now.
        XCTAssertEqual(env().wipeDate(now: now), now)
        XCTAssertEqual(env(held, wipedAt: d(5), tombstones: [DayTombstone(key: key, deletedAt: d(9))]).wipeDate(now: now), now)

        // A known wipe at or after now (this clock was set back, or another one was fast).
        XCTAssertEqual(env(wipedAt: now).wipeDate(now: now), now + 1)
        XCTAssertEqual(env(wipedAt: d(11)).wipeDate(now: now), d(11) + 1)
        XCTAssertEqual(env(wipedAt: d(9)).wipeDate(now: now, knownWipe: d(12)), d(12) + 1)

        // Something deleted here stamped later than now, by whichever field carries the stamp.
        let later = d(12)
        var cases: [(String, CompassSnapshot)] = []
        var s = held; s.goal?.createdAt = later; cases.append(("goal made", s))
        s = held; s.goal?.updatedAt = later; cases.append(("goal edited", s))
        s = held; s.pastGoals[0].endedAt = later; cases.append(("past goal ended", s))
        s = held; s.goal?.why = Note(text: "why", createdAt: later); cases.append(("why answered", s))
        s = held; s.days[0].intention?.updatedAt = later; cases.append(("intention edited", s))
        s = held; s.days[0].step?.completedAt = later; cases.append(("step completed", s))
        s = held; s.days[0].step?.completionChangedAt = later; cases.append(("step completion changed", s))
        s = held; s.days[0].notes[0].createdAt = later; cases.append(("note made", s))
        s = held; s.days[0].reflection = Reflection(outcome: .moved, transcript: "r", createdAt: d(9), updatedAt: later)
        cases.append(("evening edited", s))
        s = held; s.days[0].mergeCandidates = [Reflection(outcome: .moved, transcript: "r2", createdAt: later)]
        cases.append(("evening waiting in E5", s))
        s = held; s.days[0].removedItems = [ItemTombstone(id: UUID(), deletedAt: later)]; cases.append(("item deleted", s))
        s = held; s.days[0].morningSkipped = true; s.days[0].morningSkippedAt = later; cases.append(("morning skipped", s))
        s = held; s.settings.rhythmUpdatedAt = later; cases.append(("rhythm changed", s))
        for (what, snapshot) in cases {
            XCTAssertEqual(snapshot.newestStamp, later, what)
            XCTAssertEqual(env(snapshot, wipedAt: d(9)).wipeDate(now: now), later + 1, what)
        }
        XCTAssertEqual(env(tombstones: [DayTombstone(key: key, deletedAt: later)]).wipeDate(now: now), later + 1)
        XCTAssertEqual(env(audio: [AudioTombstone(name: "x.m4a", deletedAt: later)]).wipeDate(now: now), later + 1)

        // Dated so, the wipe drops everything the device held from any envelope that still has it.
        for (what, snapshot) in cases {
            let stamp = env(snapshot).wipeDate(now: now)
            XCTAssertTrue(snapshot.keepingOnly(createdSince: stamp).isBlank, what)
            XCTAssertEqual(snapshot.keepingOnly(createdSince: stamp).days.compactMap(\.removedItems), [], what)
        }
    }

    // MARK: - W2 · a replaced goal's end

    /// Probe Z2: B replaces N at 10:00. C only had N as a goal a merge demoted and sets V at 12:00 before
    /// hearing of B, which restamps its copy of N to end at 12:00. N ended when B replaced it: both settle
    /// with N ended at 10:00.
    func testZ2_aReplacedGoalKeepsTheFirstEnding() throws {
        let g = Goal(id: goalID(1), text: "G", createdAt: d(6))
        let n = Goal(id: goalID(2), text: "N", createdAt: d(9))
        var w = World([Device("B", CompassSnapshot(goal: n), savedAt: d(9)),
                       Device("C", CompassSnapshot(goal: g), savedAt: d(8))])
        w.push(0)
        w.pull(1, at: d(9, 30))
        XCTAssertEqual(w.show(1), "C: cur=G/active past=[\"N/replaced*\"]")
        w.setGoal(0, "U", at: d(10)); w.push(0)
        w.setGoal(1, "V", at: d(12)); w.push(1)
        XCTAssertEqual(w.devices[1].snapshot.pastGoals.first { $0.id == n.id }?.endedAt, d(12), "restamped on C")

        XCTAssertTrue(w.settle(from: d(13)), "\(w.log)")
        XCTAssertTrue(w.converged, (0..<2).map(w.show).joined(separator: " | "))
        for dev in w.devices {
            let ended = try XCTUnwrap(dev.snapshot.pastGoals.first { $0.id == n.id })
            XCTAssertEqual(ended.status, .replaced)
            XCTAssertEqual(ended.endedAt, d(10), dev.identity.id)
        }
        XCTAssertNil(w.violation())
    }

    /// The earlier end stands in either order, and only between two copies users ended as replaced.
    func testOnlyTwoUserReplacedCopiesTakeTheEarlierEnd() {
        func copy(_ status: GoalStatus, endedAt: Date, updatedAt: Date, marked: Bool = false) -> Goal {
            var g = Goal(id: goalID(1), text: "G", createdAt: d(6))
            g.status = status
            g.endedAt = endedAt
            g.updatedAt = updatedAt
            g.demotedByMerge = marked ? true : nil
            return g
        }
        let early = copy(.replaced, endedAt: d(10), updatedAt: d(10))
        let late = copy(.replaced, endedAt: d(12), updatedAt: d(12))
        for (a, b) in [(early, late), (late, early)] {
            let out = SnapshotMerger.pickGoal(a, b)
            XCTAssertEqual(out.endedAt, d(10))
            XCTAssertEqual(out.updatedAt, d(12), "the later copy still carries the content")
        }
        // An achieved copy keeps its achievement time; a copy a merge demoted was ended by nobody.
        let achieved = copy(.achieved, endedAt: d(12), updatedAt: d(12))
        XCTAssertEqual(SnapshotMerger.pickGoal(early, achieved).endedAt, d(12))
        XCTAssertEqual(SnapshotMerger.pickGoal(achieved, early).endedAt, d(12))
        let marked = copy(.replaced, endedAt: d(9), updatedAt: d(9), marked: true)
        XCTAssertEqual(SnapshotMerger.pickGoal(late, marked).endedAt, d(12))
        XCTAssertEqual(SnapshotMerger.pickGoal(marked, late).endedAt, d(12))
    }
}
