import Foundation
import XCTest
@testable import CompassCore

/// Round-2 sync review (S1–S8, P1): the wipe filter, starting fresh over a backup, stale store files,
/// device-local settings, field-wise settings and completions, audio tombstones, memo counts, and every
/// branch of `SyncApply.plan` (the coordinator's decision).
final class SyncApplyTests: XCTestCase {
    let cal = Fixtures.calendar
    let key = DayKey(year: 2026, month: 11, day: 10)
    let phone = DeviceIdentity(id: "A", model: "iPhone")
    let pad = DeviceIdentity(id: "B", model: "iPad")

    func d(_ h: Int, _ m: Int = 0) -> Date { key.date(in: cal, hour: h, minute: m) }
    func daysAgo(_ n: Int, _ h: Int = 12) -> Date { key.adding(days: -n, calendar: cal).date(in: cal, hour: h) }

    func envelope(_ id: String, savedAt: Date, _ snap: CompassSnapshot, wipedAt: Date? = nil) -> SyncEnvelope {
        SyncEnvelope(deviceID: id, deviceName: id, savedAt: savedAt, snapshot: snap, wipedAt: wipedAt)
    }

    func edit(_ s: CompassSnapshot, at: Date, on device: DeviceIdentity, _ body: (inout CompassSnapshot) -> Void) -> CompassSnapshot {
        var next = s
        body(&next)
        return LocalEdits.stamp(next, since: s, at: at, device: device)
    }

    func base() -> CompassSnapshot {
        let goal = Goal(text: "G.", createdAt: d(6))
        return CompassSnapshot(goal: goal, days: [Day(key: key, goalID: goal.id, step: Step(title: "Text Sam", createdAt: d(7)))])
    }

    // MARK: S1 · the wipe filter keeps skip-only and tombstone-only days

    /// Review probe P11: one device, a wipe a month ago, today's morning skipped. The merge on the next
    /// foreground must not bring the morning back.
    func testSkippedMorningSurvivesEveryMergeAfterAnOldWipe() throws {
        let wipe = daysAgo(30)
        var s = CompassSnapshot(goal: Goal(text: "G.", createdAt: daysAgo(29, 9)))
        s.updateDay(key) { $0.morningSkipped = true }
        let engine = DayEngine(calendar: cal)
        XCTAssertEqual(engine.phase(at: d(8), snapshot: s).kind, .today)

        let merged = try XCTUnwrap(SnapshotMerger.merge([envelope("A", savedAt: d(7), s, wipedAt: wipe)]))
        XCTAssertEqual(merged.snapshot, s, "nothing made after the wipe is dropped")
        XCTAssertEqual(engine.phase(at: d(8), snapshot: merged.snapshot).kind, .today)

        // And through the coordinator's decision: nothing to do.
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("A", savedAt: d(7), s, wipedAt: wipe),
                                                               remote: [], appliedWipe: wipe)))
        XCTAssertEqual(plan.action, .keep)
    }

    /// A skip stamped before the wipe still goes; one stamped after stays.
    func testSkipStampDecidesAgainstTheWipe() {
        let wipe = d(9)
        var before = CompassSnapshot()
        before.updateDay(key) { $0.morningSkipped = true; $0.morningSkippedAt = self.d(8) }
        XCTAssertTrue(before.keepingOnly(createdSince: wipe).days.isEmpty)
        var after = CompassSnapshot()
        after.updateDay(key) { $0.morningSkipped = true; $0.morningSkippedAt = self.d(10) }
        XCTAssertEqual(after.keepingOnly(createdSince: wipe).days.count, 1)
        // Unstamped (older data): a day long before the wipe goes.
        var old = CompassSnapshot()
        old.updateDay(key.adding(days: -10, calendar: cal)) { $0.morningSkipped = true }
        XCTAssertTrue(old.keepingOnly(createdSince: wipe).days.isEmpty)
    }

    /// Review probe P12: after a wipe in the account's past, A deletes the only note of a day; B still has
    /// it. The deletion must hold, as it does without a wipe.
    func testDeletedOnlyNoteStaysDeletedAfterAnOldWipe() throws {
        let wipe = daysAgo(30)
        var s = CompassSnapshot(goal: Goal(text: "G.", createdAt: daysAgo(29, 9)))
        s.updateDay(key) { $0.notes.append(Note(text: "n", createdAt: self.d(8))) }
        let a = edit(s, at: d(9), on: phone) { $0.updateDay(self.key) { $0.notes.removeAll() } }
        for wiped in [wipe, nil] {
            let merged = try XCTUnwrap(SnapshotMerger.merge([envelope("A", savedAt: d(9), a, wipedAt: wiped),
                                                             envelope("B", savedAt: d(8), s, wipedAt: wiped)]))
            XCTAssertEqual(merged.snapshot.day(key)?.notes.count ?? 0, 0, "wipe: \(String(describing: wiped))")
        }
    }

    func testSkipIsStampedWhenMade() {
        let s = CompassSnapshot(goal: Goal(text: "G.", createdAt: d(6)))
        let skipped = edit(s, at: d(7, 5), on: phone) { $0.updateDay(self.key) { $0.morningSkipped = true } }
        XCTAssertEqual(skipped.day(key)?.morningSkippedAt, d(7, 5))
        var withDay = s
        withDay.updateDay(key) { $0.notes.append(Note(text: "n", createdAt: self.d(6, 30))) }
        let later = edit(withDay, at: d(8), on: phone) { $0.updateDay(self.key) { $0.morningSkipped = true } }
        XCTAssertEqual(later.day(key)?.morningSkippedAt, d(8))
    }

    // MARK: S2 · starting a new goal over a backup

    func backupSnapshot() -> CompassSnapshot { Fixtures.snapshot(today: nil) }

    func freshSnapshot() -> CompassSnapshot {
        var settings = Settings(rhythm: Rhythm(morning: TimeOfDay(hour: 6), evening: TimeOfDay(hour: 22)), cloudAssist: false)
        settings.updatedAt = d(9)
        settings.rhythmUpdatedAt = d(9)
        settings.cloudAssistUpdatedAt = d(9)
        return CompassSnapshot(goal: Goal(text: "New.", createdAt: d(9)), settings: settings)
    }

    /// Onboarding finished before the backup arrived: the merge alone demotes the new goal (review probe
    /// P6). The plan puts it back on top, with the backup's goal in past goals and the new settings.
    func testFreshGoalFinishedBeforeTheBackupArrivedWins() throws {
        let backup = backupSnapshot()
        let fresh = freshSnapshot()
        let freshGoal = try XCTUnwrap(fresh.goal)
        let local = envelope("B", savedAt: d(9), fresh)
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: local, remote: [envelope("A", savedAt: d(8), backup)],
                                                               freshGoalID: freshGoal.id)))
        guard case .adopt(let snap, .localChange) = plan.action else { return XCTFail("\(plan.action)") }
        XCTAssertEqual(snap.goal?.id, freshGoal.id)
        XCTAssertEqual(snap.goal?.status, .active)
        let old = try XCTUnwrap(snap.pastGoals.first { $0.id == backup.goal?.id })
        XCTAssertEqual(old.status, .replaced)
        XCTAssertEqual(snap.days.count, backup.days.count, "the history stays")
        XCTAssertEqual(snap.settings.rhythm, fresh.settings.rhythm)
        XCTAssertFalse(snap.settings.cloudAssist)
        XCTAssertNil(plan.freshGoalID, "settled")
        XCTAssertFalse(plan.openEntry)

        // Every device now agrees: the old phone, which never saw the new goal, merges the pushed result.
        let pushed = envelope("B", savedAt: d(9, 1), snap)
        for order in [[pushed, envelope("A", savedAt: d(8), backup)], [envelope("A", savedAt: d(8), backup), pushed]] {
            let merged = try XCTUnwrap(SnapshotMerger.merge(order))
            XCTAssertEqual(merged.snapshot.goal?.id, freshGoal.id)
            XCTAssertTrue(merged.snapshot.pastGoals.contains { $0.id == backup.goal?.id && $0.status == .replaced })
        }
    }

    /// The other order: the backup arrives mid-onboarding. The plan adopts it and leaves onboarding alone;
    /// finishing then sets the new goal on top (`setGoal`), which the merge keeps.
    func testGoalArrivingMidOnboardingIsAdoptedWithoutEndingOnboarding() throws {
        let backup = backupSnapshot()
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: .distantPast, .empty),
                                                               remote: [envelope("A", savedAt: d(8), backup)], isOnboarding: true)))
        guard case .adopt(var snap, .merge) = plan.action else { return XCTFail("\(plan.action)") }
        XCTAssertEqual(snap.goal?.id, backup.goal?.id)
        XCTAssertFalse(plan.openEntry, "onboarding stays on screen")

        // Finish onboarding the same way: setGoal on top (AppModel.setGoal), as a local edit.
        let before = snap
        var ended = try XCTUnwrap(snap.goal)
        ended.status = .replaced
        ended.endedAt = d(9)
        snap.pastGoals.insert(ended, at: 0)
        snap.goal = Goal(text: "New.", createdAt: d(9))
        let finished = LocalEdits.stamp(snap, since: before, at: d(9), device: pad)
        let merged = try XCTUnwrap(SnapshotMerger.merge([envelope("B", savedAt: d(9), finished), envelope("A", savedAt: d(8), backup)]))
        XCTAssertEqual(merged.snapshot.goal?.text, "New.")
        XCTAssertTrue(merged.snapshot.pastGoals.contains { $0.id == backup.goal?.id && $0.status == .replaced })
        XCTAssertEqual(merged.snapshot.days.count, backup.days.count)
    }

    /// A later goal set on another device that knew the fresh one is a real replacement: not undone.
    func testFreshGoalReplacedLaterElsewhereIsNotPromoted() throws {
        let fresh = freshSnapshot()
        let freshGoal = try XCTUnwrap(fresh.goal)
        var other = fresh
        var ended = freshGoal
        ended.status = .replaced
        ended.endedAt = d(12)
        other.pastGoals = [ended]
        other.goal = Goal(text: "Later.", createdAt: d(12))
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: d(9), fresh),
                                                               remote: [envelope("A", savedAt: d(12), other)], freshGoalID: freshGoal.id)))
        guard case .adopt(let snap, .merge) = plan.action else { return XCTFail("\(plan.action)") }
        XCTAssertEqual(snap.goal?.text, "Later.")
    }

    /// No other device yet (iCloud still downloading): keep guarding the fresh goal.
    func testFreshGoalMarkerIsKeptUntilAnotherDevicesGoalsAreSeen() throws {
        let fresh = freshSnapshot()
        let id = try XCTUnwrap(fresh.goal?.id)
        let alone = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: d(9), fresh), remote: [], freshGoalID: id)))
        XCTAssertEqual(alone.freshGoalID, id)
        XCTAssertEqual(alone.action, .keep)
        // The fresh goal is no longer current here: nothing to guard.
        var replaced = fresh
        replaced.goal = Goal(text: "Other.", createdAt: d(10))
        let gone = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: d(10), replaced), remote: [], freshGoalID: id)))
        XCTAssertNil(gone.freshGoalID)
    }

    // MARK: P1 · the coordinator's other branches

    func testNothingReadableIsNoPlan() {
        var future = envelope("B", savedAt: d(9), base())
        future.format = SyncEnvelope.currentFormat + 1
        XCTAssertNil(SyncApply.plan(SyncApplyInput(local: future, remote: [])))
    }

    func testRemoteWipeWithNothingMadeHereSinceErases() throws {
        let local = envelope("B", savedAt: d(8), base())
        let marker = envelope("A", savedAt: d(12), .empty, wipedAt: d(12))
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: local, remote: [marker], freshGoalID: UUID())))
        XCTAssertEqual(plan.action, .eraseLocal)
        XCTAssertTrue(plan.newWipe)
        XCTAssertNil(plan.freshGoalID)
    }

    func testRemoteWipeWithLocalSurvivorsKeepsThemAndReopensTheEntry() throws {
        var s = base()
        s.updateDay(key) { $0.notes.append(Note(text: "after", createdAt: self.d(13))) }
        let marker = envelope("A", savedAt: d(12), .empty, wipedAt: d(12))
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: d(13), s), remote: [marker])))
        guard case .adopt(let snap, .merge) = plan.action else { return XCTFail("\(plan.action)") }
        XCTAssertNil(snap.goal)
        XCTAssertEqual(snap.day(key)?.notes.map(\.text), ["after"])
        XCTAssertTrue(plan.openEntry)
        // Mid-onboarding, the screen stays.
        let onboarding = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: d(13), s), remote: [marker], isOnboarding: true)))
        XCTAssertFalse(onboarding.openEntry)
    }

    func testAnOldWipeAlreadyCarriedOutChangesNothing() throws {
        let s = base()
        let marker = envelope("A", savedAt: daysAgo(30), .empty, wipedAt: daysAgo(30))
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("B", savedAt: d(8), s), remote: [marker],
                                                               appliedWipe: daysAgo(30))))
        XCTAssertEqual(plan.action, .keep)
        XCTAssertFalse(plan.newWipe)
    }

    func testOtherDevicesChangesAreAdoptedAsAMerge() throws {
        let s = base()
        let b = edit(s, at: d(16), on: pad) { $0.updateDay(self.key) { $0.notes.append(Note(text: "n", createdAt: self.d(16))) } }
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("A", savedAt: d(8), s),
                                                               remote: [envelope("A", savedAt: d(8), s), envelope("B", savedAt: d(16), b)])))
        guard case .adopt(let snap, .merge) = plan.action else { return XCTFail("\(plan.action)") }
        XCTAssertEqual(snap.day(key)?.notes.count, 1)
        XCTAssertFalse(plan.openEntry)
    }

    // MARK: S3 · a failed save never turns the stale file into a local edit

    func testStoreFileIsReadOnlyWhenAnotherProcessWroteItAfterOurLastSave() {
        XCTAssertFalse(StoreReload.shouldRead(fileModifiedAt: d(10), lastSavedAt: d(9), saveFailed: true))
        XCTAssertFalse(StoreReload.shouldRead(fileModifiedAt: d(9), lastSavedAt: d(9), saveFailed: false))
        XCTAssertFalse(StoreReload.shouldRead(fileModifiedAt: d(8), lastSavedAt: d(9), saveFailed: false))
        XCTAssertFalse(StoreReload.shouldRead(fileModifiedAt: nil, lastSavedAt: d(9), saveFailed: false))
        XCTAssertTrue(StoreReload.shouldRead(fileModifiedAt: d(10), lastSavedAt: d(9), saveFailed: false))
        XCTAssertTrue(StoreReload.shouldRead(fileModifiedAt: d(10), lastSavedAt: nil, saveFailed: false))
    }

    /// Review probe P9: memory has a note the (stale) file lacks. Taking the file in must not tombstone it;
    /// a completion the widget made there is taken.
    func testTakingTheFileOnlyTakesTheWidgetsCompletion() throws {
        let s = base()
        var memory = s
        memory.updateDay(key) { $0.notes.append(Note(text: "typed while the disk was full", createdAt: self.d(9))) }
        let file = try InMemoryStore(s).setStepDone(true, on: key, at: d(10))
        let taken = memory.takingWidgetChanges(from: file)
        XCTAssertEqual(taken.day(key)?.notes.count, 1)
        XCTAssertTrue(taken.day(key)?.step?.isDone ?? false)
        let stamped = LocalEdits.stamp(taken, since: memory, at: d(10, 1), device: phone)
        XCTAssertNil(stamped.day(key)?.removedItems, "nothing recorded as deleted")
        XCTAssertEqual(stamped.day(key)?.step?.completionChangedAt, d(10), "the widget's time is kept")
        // An older completion in the file doesn't undo a newer undo here.
        let undone = edit(taken, at: d(11), on: phone) { $0.updateDay(self.key) { $0.step?.completedAt = nil } }
        XCTAssertFalse(undone.takingWidgetChanges(from: file).day(key)?.step?.isDone ?? true)
    }

    func testFailedSaveLeavesTheStoreAlone() throws {
        let b = base()
        let store = InMemoryStore(b)
        store.failsSaving = true
        XCTAssertThrowsError(try store.save(.empty))
        XCTAssertEqual(try store.load(), b)
        XCTAssertNil(store.modifiedAt)
    }

    // MARK: S4, S5 · device-local settings, field-wise synced settings

    /// Review probe P1c: evening 22:00 on A, then a time-zone pin on B an hour later. The evening holds,
    /// and A's own time zone (none) stays.
    func testTimeZonePinElsewhereNeitherTravelsNorUndoesTheRhythm() throws {
        let s = base()
        let a = edit(s, at: d(10), on: phone) { $0.settings.rhythm.evening = TimeOfDay(hour: 22) }
        let b = edit(s, at: d(11), on: pad) { $0.settings.timeZoneID = "Asia/Bangkok" }
        XCTAssertNil(b.settings.updatedAt, "a device-local change stamps nothing synced")
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("A", savedAt: d(10), a),
                                                               remote: [envelope("B", savedAt: d(11), b)])))
        let merged: CompassSnapshot
        if case .adopt(let snap, _) = plan.action { merged = snap } else { merged = a }
        XCTAssertEqual(merged.settings.rhythm.evening, TimeOfDay(hour: 22))
        XCTAssertNil(merged.settings.timeZoneID)
    }

    /// S4: the travelling phone keeps its pin when the iPad at home clears its own.
    func testPinnedTimeZoneSurvivesAnotherDeviceClearingItsOwn() throws {
        let shared = base()
        var pinned = shared
        pinned.settings.timeZoneID = "Asia/Bangkok"
        var home = shared
        home.settings.timeZoneID = "Asia/Bangkok"
        let cleared = edit(home, at: d(12), on: pad) { $0.settings.timeZoneID = nil; $0.settings.notificationsEnabled = false; $0.settings.input = .typing }
        let plan = try XCTUnwrap(SyncApply.plan(SyncApplyInput(local: envelope("A", savedAt: d(9), pinned),
                                                               remote: [envelope("B", savedAt: d(12), cleared)])))
        let merged: CompassSnapshot
        if case .adopt(let snap, _) = plan.action { merged = snap } else { merged = pinned }
        XCTAssertEqual(merged.settings.timeZoneID, "Asia/Bangkok")
        XCTAssertTrue(merged.settings.notificationsEnabled)
        XCTAssertEqual(merged.settings.input, .voice)
    }

    func testRhythmAndCloudHelpMergeOnTheirOwnStamps() throws {
        let s = base()
        let a = edit(s, at: d(10), on: phone) { $0.settings.rhythm.evening = TimeOfDay(hour: 22) }
        let b = edit(s, at: d(11), on: pad) { $0.settings.cloudAssist = false }
        for order in [[envelope("A", savedAt: d(10), a), envelope("B", savedAt: d(11), b)],
                      [envelope("B", savedAt: d(11), b), envelope("A", savedAt: d(10), a)]] {
            let merged = try XCTUnwrap(SnapshotMerger.merge(order)).snapshot.settings
            XCTAssertEqual(merged.rhythm.evening, TimeOfDay(hour: 22))
            XCTAssertFalse(merged.cloudAssist)
        }
        // Older data (one stamp for all): the later change wins as before.
        let old1 = Settings(rhythm: Rhythm(morning: TimeOfDay(hour: 6)), updatedAt: d(8))
        let old2 = Settings(cloudAssist: false, updatedAt: d(9))
        let m = SnapshotMerger.mergeSettings(old1, old2)
        XCTAssertEqual(m.rhythm, old2.rhythm)
        XCTAssertFalse(m.cloudAssist)
    }

    func testWipeResetsOnlySyncedSettingsMadeBeforeIt() {
        var s = CompassSnapshot()
        s.settings = Settings(rhythm: Rhythm(morning: TimeOfDay(hour: 6)), cloudAssist: false, notificationsEnabled: false,
                              input: .typing, timeZoneID: "Asia/Bangkok", updatedAt: d(10), rhythmUpdatedAt: d(8), cloudAssistUpdatedAt: d(10))
        let kept = s.keepingOnly(createdSince: d(9)).settings
        XCTAssertEqual(kept.rhythm, .standard)
        XCTAssertFalse(kept.cloudAssist)
        XCTAssertEqual(kept.deviceLocal, s.settings.deviceLocal)
    }

    // MARK: S6 · a completion on its own stamp

    /// Review probe P1b: done at 15:00 on A, title edited at 15:30 on B.
    func testCompletionSurvivesALaterTitleEditElsewhere() throws {
        let s = base()
        let a = edit(s, at: d(15), on: phone) { $0.updateDay(self.key) { $0.step?.completedAt = self.d(15) } }
        XCTAssertEqual(a.day(key)?.step?.completionChangedAt, d(15))
        let b = edit(s, at: d(15, 30), on: pad) { $0.updateDay(self.key) { $0.step?.title = "Text Sam about Friday" } }
        for order in [[envelope("A", savedAt: d(15), a), envelope("B", savedAt: d(15, 30), b)],
                      [envelope("B", savedAt: d(15, 30), b), envelope("A", savedAt: d(15), a)]] {
            let step = try XCTUnwrap(SnapshotMerger.merge(order)?.snapshot.day(key)?.step)
            XCTAssertTrue(step.isDone)
            XCTAssertEqual(step.title, "Text Sam about Friday")
        }
        // An undo later than the completion wins.
        let undo = edit(a, at: d(16), on: pad) { $0.updateDay(self.key) { $0.step?.completedAt = nil } }
        let step = try XCTUnwrap(SnapshotMerger.merge([envelope("A", savedAt: d(15), a), envelope("B", savedAt: d(16), undo)])?.snapshot.day(key)?.step)
        XCTAssertFalse(step.isDone)
    }

    // MARK: S7 · audio tombstones

    func testAudioTombstonesArePrunedAfterNinetyDaysAndOnlyForUsedRecordings() {
        let now = d(12)
        let list = [AudioTombstone(name: "old.m4a", deletedAt: daysAgo(91)), AudioTombstone(name: "new.m4a", deletedAt: daysAgo(89))]
        XCTAssertEqual(AudioTombstone.pruned(list, now: now).map(\.name), ["new.m4a"])
        let used = Fixtures.snapshot(today: Fixtures.today()).referencedAudioFiles
        let note = AudioNaming.fileName(for: Fixtures.note.id)
        XCTAssertTrue(AudioTombstone.isNeeded(for: note, referenced: used))
        XCTAssertFalse(AudioTombstone.isNeeded(for: AudioNaming.fileName(for: UUID()), referenced: used), "a discarded take")
    }

    // MARK: S8 · memos

    func testSpokenIntentionIsNotCountedAsAMemo() {
        var s = CompassSnapshot()
        s.updateDay(key) { $0.intention = Intention(text: "Patient.", duration: 4, createdAt: self.d(7)) }
        XCTAssertEqual(s.memoCount, 0)
        XCTAssertEqual(Fixtures.totalsSnapshot.memoCount, 186)
        XCTAssertEqual(Fixtures.totalsSnapshot.totalSteps, 212)
    }
}
