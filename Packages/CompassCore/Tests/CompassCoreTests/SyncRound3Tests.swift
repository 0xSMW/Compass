import Foundation
import XCTest
@testable import CompassCore

/// Round-3 sync review: the promotion race (N1), a completion that no longer outranks a title edit (N2),
/// the blank snapshot after a wipe (N3), the fresh goal's expiry (N5) and the app's one-step save (N6).
final class SyncRound3Tests: XCTestCase {
    let cal = Fixtures.calendar
    let key = DayKey(year: 2026, month: 11, day: 10)
    let phone = DeviceIdentity(id: "A", model: "iPhone")
    let pad = DeviceIdentity(id: "B", model: "iPad")

    func d(_ h: Int, _ m: Int = 0) -> Date { key.date(in: cal, hour: h, minute: m) }

    func envelope(_ id: String, savedAt: Date, _ snap: CompassSnapshot, wipedAt: Date? = nil) -> SyncEnvelope {
        SyncEnvelope(deviceID: id, deviceName: id, savedAt: savedAt, snapshot: snap, wipedAt: wipedAt)
    }

    func edit(_ s: CompassSnapshot, at: Date, on device: DeviceIdentity, _ body: (inout CompassSnapshot) -> Void) -> CompassSnapshot {
        var next = s
        body(&next)
        return LocalEdits.stamp(next, since: s, at: at, device: device)
    }

    // MARK: - A device, as SyncCoordinator runs it

    /// One install: its model, its envelope's `savedAt` (last local change), the fresh-goal marker and the
    /// envelope it last pushed to iCloud (what other devices read).
    struct Device {
        let identity: DeviceIdentity
        var snapshot: CompassSnapshot
        var savedAt: Date
        var freshGoalID: UUID?
        var published: SyncEnvelope

        init(_ identity: DeviceIdentity, _ snapshot: CompassSnapshot, savedAt: Date, freshGoalID: UUID? = nil) {
            self.identity = identity
            self.snapshot = snapshot
            self.savedAt = savedAt
            self.freshGoalID = freshGoalID
            published = SyncEnvelope(deviceID: identity.id, deviceName: identity.model, savedAt: savedAt, snapshot: snapshot)
        }

        var envelope: SyncEnvelope {
            SyncEnvelope(deviceID: identity.id, deviceName: identity.model, savedAt: savedAt, snapshot: snapshot)
        }

        mutating func push() { published = envelope }

        /// `SyncCoordinator.apply`: plan, then carry it out (a local change is stamped and moves `savedAt`).
        mutating func read(_ other: SyncEnvelope, at now: Date) {
            guard let plan = SyncApply.plan(SyncApplyInput(local: envelope, remote: [other], freshGoalID: freshGoalID, now: now)) else { return }
            freshGoalID = plan.freshGoalID
            switch plan.action {
            case .keep: break
            case .eraseLocal: snapshot = .empty
            case .adopt(let next, .merge): snapshot = next
            case .adopt(let next, .localChange):
                snapshot = LocalEdits.stamp(next, since: snapshot, at: now, device: identity)
                savedAt = now
            }
        }
    }

    let oldGoal = Goal(text: "OLD", createdAt: DayKey(year: 2026, month: 11, day: 10).date(in: Fixtures.calendar, hour: 6))
    let newGoal = Goal(text: "NEW", createdAt: DayKey(year: 2026, month: 11, day: 10).date(in: Fixtures.calendar, hour: 9))

    /// The old phone A holds OLD; the new device B finished onboarding with NEW before it had seen A
    /// (`freshGoalID`). Both have pushed once.
    func devices() -> (a: Device, b: Device) {
        (Device(phone, CompassSnapshot(goal: oldGoal), savedAt: d(8)),
         Device(pad, CompassSnapshot(goal: newGoal), savedAt: d(9), freshGoalID: newGoal.id))
    }

    func assertSettled(_ dev: Device, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(dev.snapshot.goal?.id, newGoal.id, "\(dev.identity.id) current, \(context)", file: file, line: line)
        XCTAssertEqual(dev.snapshot.goal?.status, .active, "\(dev.identity.id), \(context)", file: file, line: line)
        XCTAssertEqual(dev.snapshot.pastGoals.map(\.id), [oldGoal.id], "\(dev.identity.id) past, \(context)", file: file, line: line)
        XCTAssertEqual(dev.snapshot.pastGoals.first?.status, .replaced, "\(dev.identity.id), \(context)", file: file, line: line)
    }

    // MARK: - N1 · the promotion race

    /// Review probe Q1, first interleaving: A merges B's raw envelope (NEW demoted there by the merge) and
    /// pushes; B then reads A's merged envelope, puts NEW back on top and pushes; A reads that.
    func testOldDeviceMergesTheFreshGoalFirstThenReadsThePromotion_mergedEnvelope() {
        var (a, b) = devices()
        a.read(b.published, at: d(9, 1))
        XCTAssertEqual(a.snapshot.goal?.id, oldGoal.id, "before B decides, the merge alone keeps the earlier goal")
        XCTAssertEqual(a.snapshot.pastGoals.first?.demotedByMerge, true, "a merge's demotion, not A's decision")
        a.push()

        b.read(a.published, at: d(9, 2))
        assertSettled(b, "after promoting")
        XCTAssertNil(b.freshGoalID)
        b.push()

        a.read(b.published, at: d(9, 3))
        assertSettled(a, "after reading the promotion")
        a.push()
        b.read(a.published, at: d(9, 4))
        assertSettled(b, "after reading A's result")
        XCTAssertNil(a.snapshot.goal?.demotedByMerge)
        XCTAssertNil(b.snapshot.pastGoals.first?.demotedByMerge, "OLD was ended by B, deliberately")
    }

    /// Second interleaving: A merges B's raw envelope but hasn't pushed; B reads A's raw envelope.
    func testOldDeviceMergesTheFreshGoalFirstThenReadsThePromotion_rawEnvelope() {
        var (a, b) = devices()
        a.read(b.published, at: d(9, 1))
        b.read(a.published, at: d(9, 2))
        assertSettled(b, "after promoting")
        b.push()
        a.read(b.published, at: d(9, 3))
        assertSettled(a, "after reading the promotion")
        a.push()
        b.read(a.published, at: d(9, 4))
        assertSettled(b, "after reading A's result")
    }

    /// Every order of pushes and reads (up to six operations), then a few full rounds: both devices always
    /// end with exactly one current goal, the fresh NEW, and OLD in past goals.
    func testEveryOrderOfExchangesConverges() {
        enum Op: CaseIterable { case pushA, pushB, aReadsB, bReadsA }
        func run(_ ops: [Op]) -> (Device, Device) {
            var (a, b) = devices()
            var minute = 1
            func step(_ op: Op) {
                let now = d(9, minute)
                minute += 1
                switch op {
                case .pushA: a.push()
                case .pushB: b.push()
                case .aReadsB: a.read(b.published, at: now)
                case .bReadsA: b.read(a.published, at: now)
                }
            }
            ops.forEach(step)
            for _ in 0..<3 { Op.allCases.forEach(step) }
            return (a, b)
        }
        var sequences: [[Op]] = [[]]
        var frontier: [[Op]] = [[]]
        for _ in 0..<6 {
            frontier = frontier.flatMap { seq in Op.allCases.map { seq + [$0] } }
            sequences += frontier
        }
        var failures = 0
        for ops in sequences {
            let (a, b) = run(ops)
            let ok = [a, b].allSatisfy {
                $0.snapshot.goal?.id == newGoal.id && $0.snapshot.goal?.status == .active
                    && $0.snapshot.pastGoals.map(\.id) == [oldGoal.id] && $0.snapshot.pastGoals.first?.status == .replaced
            }
            if !ok {
                failures += 1
                if failures <= 3 {
                    XCTFail("\(ops): A current=\(a.snapshot.goal?.text ?? "nil") past=\(a.snapshot.pastGoals.map(\.text)) | "
                            + "B current=\(b.snapshot.goal?.text ?? "nil") past=\(b.snapshot.pastGoals.map(\.text))")
                }
            }
        }
        XCTAssertEqual(failures, 0, "of \(sequences.count) orders")
    }

    /// Without a fresh goal (two devices onboarded offline) the earlier goal still stays current, the
    /// newcomer is a past goal on every device, and nothing flips back on later merges.
    func testConcurrentGoalsWithoutAFreshMarkerKeepTheEarlierOne() {
        var a = Device(phone, CompassSnapshot(goal: oldGoal), savedAt: d(8))
        var b = Device(pad, CompassSnapshot(goal: newGoal), savedAt: d(9))
        for minute in 1...4 {
            a.read(b.published, at: d(10, minute)); a.push()
            b.read(a.published, at: d(11, minute)); b.push()
        }
        for dev in [a, b] {
            XCTAssertEqual(dev.snapshot.goal?.id, oldGoal.id)
            XCTAssertEqual(dev.snapshot.pastGoals.map(\.id), [newGoal.id])
            XCTAssertEqual(dev.snapshot.pastGoals.first?.status, .replaced)
        }
    }

    /// A merge-demoted goal never comes back over a goal set later by a device that had it in its past
    /// goals, even when a stale device still holds it as current.
    func testSettingANewGoalRetiresGoalsAMergeDemoted() throws {
        // A merged B's goal (demoted), then set a third goal.
        let merged = try XCTUnwrap(SnapshotMerger.merge([envelope("A", savedAt: d(8), CompassSnapshot(goal: oldGoal)),
                                                         envelope("B", savedAt: d(9), CompassSnapshot(goal: newGoal))]))
        var aSnap = merged.snapshot
        XCTAssertEqual(aSnap.pastGoals.first?.demotedByMerge, true)
        let third = Goal(text: "THIRD", createdAt: d(12))
        aSnap = edit(aSnap, at: d(12), on: phone) { s in
            var ended = s.goal!
            ended.status = .replaced
            ended.endedAt = self.d(12)
            s.pastGoals.insert(ended, at: 0)
            s.goal = third
        }
        XCTAssertTrue(aSnap.pastGoals.allSatisfy { $0.demotedByMerge == nil }, "A moved on from both knowingly")

        // B never merged: it still holds NEW as current. NEW (created earlier than THIRD) stays retired.
        for order in [[envelope("A", savedAt: d(12), aSnap), envelope("B", savedAt: d(9), CompassSnapshot(goal: newGoal))],
                      [envelope("B", savedAt: d(13), CompassSnapshot(goal: newGoal)), envelope("A", savedAt: d(12), aSnap)]] {
            let out = try XCTUnwrap(SnapshotMerger.merge(order)).snapshot
            XCTAssertEqual(out.goal?.id, third.id)
            XCTAssertEqual(Set(out.pastGoals.map(\.id)), [oldGoal.id, newGoal.id])
            XCTAssertTrue(out.pastGoals.allSatisfy { $0.status == .replaced })
        }
    }

    /// A merge-demoted copy of an achieved goal doesn't count as ended by a user (`isEndedByUser`), and a
    /// merge that demotes the achieved goal keeps its achievement.
    func testMergeDemotionKeepsAnAchievement() throws {
        var achieved = oldGoal
        achieved.status = .achieved
        achieved.endedAt = d(20)
        var demotedCopy = oldGoal
        demotedCopy.status = .replaced
        demotedCopy.endedAt = d(6)
        demotedCopy.demotedByMerge = true
        let out = try XCTUnwrap(SnapshotMerger.merge([envelope("A", savedAt: d(20), CompassSnapshot(goal: achieved)),
                                                      envelope("C", savedAt: d(21), CompassSnapshot(goal: Goal(text: "Z", createdAt: d(3)),
                                                                                                    pastGoals: [demotedCopy]))])).snapshot
        // C's own goal Z is earlier, so it stays current and OLD is demoted again, keeping its achievement.
        XCTAssertEqual(out.goal?.text, "Z")
        XCTAssertEqual(out.pastGoals.first?.status, .achieved)
    }

    // MARK: - N2 · a completion leaves the title's stamp alone

    /// Review probe Q3: B retitles at 15:30, A completes at 16:00 (neither saw the other).
    func testTitleEditSurvivesALaterCompletionElsewhere() throws {
        let goal = Goal(text: "G.", createdAt: d(6))
        let s = CompassSnapshot(goal: goal, days: [Day(key: key, goalID: goal.id, step: Step(title: "Text Sam", createdAt: d(7)))])
        let b = edit(s, at: d(15, 30), on: pad) { $0.updateDay(self.key) { $0.step?.title = "Call Sam" } }
        let a = edit(s, at: d(16), on: phone) { $0.updateDay(self.key) { $0.step?.completedAt = self.d(16) } }
        XCTAssertNil(a.day(key)?.step?.updatedAt)
        XCTAssertEqual(a.day(key)?.step?.completionChangedAt, d(16))
        for order in [[envelope("A", savedAt: d(16), a), envelope("B", savedAt: d(15, 30), b)],
                      [envelope("B", savedAt: d(15, 30), b), envelope("A", savedAt: d(16), a)]] {
            let step = try XCTUnwrap(SnapshotMerger.merge(order)?.snapshot.day(key)?.step)
            XCTAssertEqual(step.title, "Call Sam")
            XCTAssertTrue(step.isDone)
        }

        // The widget's completion (Store.setStepDone) is stamped the same way.
        let store = InMemoryStore(s)
        try store.setStepDone(true, on: key, at: d(16))
        let widget = try store.load()
        XCTAssertNil(widget.day(key)?.step?.updatedAt)
        XCTAssertEqual(widget.day(key)?.step?.completionChangedAt, d(16))
        let step = try XCTUnwrap(SnapshotMerger.merge([envelope("A", savedAt: d(16), widget), envelope("B", savedAt: d(15, 30), b)])?
            .snapshot.day(key)?.step)
        XCTAssertEqual(step.title, "Call Sam")
        XCTAssertTrue(step.isDone)

        // A deletion is weighed against the last touch, completion included: completing after the step
        // was deleted elsewhere keeps it, as before.
        let deleted = edit(s, at: d(15), on: pad) { $0.updateDay(self.key) { $0.step = nil } }
        let kept = try XCTUnwrap(SnapshotMerger.merge([envelope("A", savedAt: d(16), a), envelope("B", savedAt: d(15), deleted)])?.snapshot)
        XCTAssertEqual(kept.day(key)?.step?.isDone, true)
        XCTAssertEqual(a.day(key)?.step?.lastTouched, d(16))
    }

    // MARK: - N3 · nothing left but a skip

    /// Review probe Q6: a remote wipe at 08:00 and a morning skipped here at 09:00 offline. Nothing the user
    /// wrote survives, so this device erases and opens Welcome, not a goal-less "goal ended" Today.
    func testSkipMadeAfterARemoteWipeIsBlank() throws {
        let goal = Goal(text: "G.", createdAt: d(6))
        var s = CompassSnapshot(goal: goal, days: [Day(key: key.adding(days: -1, calendar: cal), goalID: goal.id,
                                                       step: Step(title: "x", createdAt: d(7).addingTimeInterval(-86400)))])
        s = edit(s, at: d(9), on: phone) { $0.updateDay(self.key) { $0.morningSkipped = true } }
        let survivors = s.keepingOnly(createdSince: d(8))
        XCTAssertEqual(survivors.days.count, 1, "the skip itself is still kept by the wipe filter (S1)")
        XCTAssertTrue(survivors.isBlank)
        XCTAssertFalse(survivors.hasHistory)
        XCTAssertEqual(DayEngine(calendar: cal).phase(at: d(9, 30), snapshot: survivors).kind, .onboarding)

        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("A", savedAt: d(9), s),
                                                               remote: [envelope("B", savedAt: d(8), .empty, wipedAt: d(8))])))
        XCTAssertEqual(plan.action, .eraseLocal)

        // A day with content is not blank.
        var withNote = survivors
        withNote.updateDay(key) { $0.notes.append(Note(text: "n", createdAt: self.d(9))) }
        XCTAssertFalse(withNote.isBlank)
    }

    // MARK: - N5 · the fresh goal's marker expires

    func backup() -> CompassSnapshot {
        CompassSnapshot(goal: oldGoal, days: [Day(key: key.adding(days: -1, calendar: cal), goalID: oldGoal.id,
                                                  step: Step(title: "s", createdAt: d(7).addingTimeInterval(-86400)))])
    }

    /// The first pass that reads another device's envelope settles the marker, whatever it holds.
    func testFreshGoalMarkerEndsWithTheFirstOtherEnvelope() throws {
        let fresh = CompassSnapshot(goal: newGoal)
        // Another device's envelope without goals (still onboarding there): the marker is used up.
        let blank = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: d(9), fresh),
                                                                remote: [envelope("C", savedAt: d(8), .empty)],
                                                                freshGoalID: newGoal.id, now: d(9, 1))))
        XCTAssertNil(blank.freshGoalID)
        // With the backup in that first pass, it promotes and is used up too.
        let promoted = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: d(9), fresh),
                                                                   remote: [envelope("A", savedAt: d(8), backup())],
                                                                   freshGoalID: newGoal.id, now: d(9, 1))))
        guard case .adopt(let snap, .localChange) = promoted.action else { return XCTFail("\(promoted.action)") }
        XCTAssertEqual(snap.goal?.id, newGoal.id)
        XCTAssertNil(promoted.freshGoalID)
    }

    /// A single-device account: after seven days the marker no longer promotes, so an old device that
    /// shows up months later keeps the ordinary rule (the earlier goal stays current).
    func testFreshGoalMarkerExpiresAfterSevenDays() throws {
        let fresh = CompassSnapshot(goal: newGoal)
        let alone = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: d(9), fresh), remote: [],
                                                                freshGoalID: newGoal.id, now: d(9).addingTimeInterval(6 * 86400))))
        XCTAssertEqual(alone.freshGoalID, newGoal.id, "still guarded on day 6")

        let late = d(9).addingTimeInterval(8 * 86400)
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: d(9), fresh),
                                                               remote: [envelope("A", savedAt: d(8), backup())],
                                                               freshGoalID: newGoal.id, now: late)))
        XCTAssertNil(plan.freshGoalID)
        guard case .adopt(let snap, .merge) = plan.action else { return XCTFail("\(plan.action)") }
        XCTAssertEqual(snap.goal?.id, oldGoal.id)
        XCTAssertEqual(snap.pastGoals.map(\.id), [newGoal.id])
    }

    // MARK: - N6 · the app's save is one step

    func testAppSaveIsOneStepAndReplacesOnlyADamagedFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compass-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("compass.json")
        let store = JSONFileStore(url: url)
        let start = Fixtures.snapshot(today: Fixtures.today())
        try store.save(start)

        // The body sees what is stored and when it changed; the result carries the date after the write.
        var seen: (CompassSnapshot, Date?)?
        let write = try store.update(replacingUnreadable: false) { stored, modifiedAt in
            seen = (stored, modifiedAt)
            stored.settings.cloudAssist = false
        }
        XCTAssertEqual(seen?.0, start)
        XCTAssertNotNil(seen?.1)
        XCTAssertEqual(write.modifiedAt, store.modifiedAt)
        XCTAssertEqual(try store.load(), write.snapshot)

        // A damaged file throws for the widget's update, and is replaced by the app's save.
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try store.update { _ in })
        let replaced = try store.update(replacingUnreadable: true) { stored, _ in
            XCTAssertEqual(stored, .empty)
            stored = start
        }
        XCTAssertEqual(replaced.snapshot, start)
        XCTAssertEqual(try store.load(), start)

        // Delete everything goes through the same coordination.
        try store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(store.quarantine(label: "unreadable"), "nothing to copy")
    }
}
