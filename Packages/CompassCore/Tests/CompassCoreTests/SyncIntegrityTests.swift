import Foundation
import XCTest
@testable import CompassCore

/// Sync and data-integrity cases from the review (M1–M5, M10, item 19): concurrent edits to one item,
/// wipes followed by stale edits, audio deletion, placeholder envelopes on restore, device identity,
/// and unreadable stores.
final class SyncIntegrityTests: XCTestCase {
    let cal = Fixtures.calendar
    let sat = DayKey(year: 2026, month: 11, day: 7)
    let phone = DeviceIdentity(id: "PHONE-A", model: "iPhone")
    let pad = DeviceIdentity(id: "PAD-B", model: "iPad")

    func at(_ h: Int, _ m: Int = 0, _ key: DayKey? = nil) -> Date { Fixtures.date(key ?? sat, h, m) }
    func uid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    func envelope(_ id: String, savedAt: Date, _ snap: CompassSnapshot, wipedAt: Date? = nil,
                  audio: [AudioTombstone] = []) -> SyncEnvelope {
        SyncEnvelope(deviceID: id, deviceName: id, savedAt: savedAt, snapshot: snap, wipedAt: wipedAt, audioTombstones: audio)
    }

    func step() -> Step { Step(id: uid(900), title: Fixtures.stepTitle, partID: Fixtures.friendsPartID, createdAt: at(7, 30)) }

    // MARK: M1 · concurrent edits to the same item

    /// The review's probe: A completes the step at 15:00; B, which hasn't seen that, adds a note at 16:00.
    func testStepCompletionSurvivesALaterUnrelatedSaveOnAnotherDevice() throws {
        let base = CompassSnapshot(goal: Fixtures.goal, days: [Day(key: sat, goalID: Fixtures.goalID, step: step())])
        let storeA = InMemoryStore(base)
        let a = try storeA.setStepDone(true, on: sat, at: at(15))
        var b = base
        b.updateDay(sat) { $0.notes.append(Note(text: "Sam replied", createdAt: at(16), deviceID: pad.id)) }

        for order in [[envelope("A", savedAt: at(15), a), envelope("B", savedAt: at(16), b)],
                      [envelope("B", savedAt: at(16), b), envelope("A", savedAt: at(15), a)]] {
            let day = try XCTUnwrap(SnapshotMerger.merge(order)?.snapshot.day(sat))
            XCTAssertTrue(day.step?.isDone ?? false, "the completion is not reverted by B's later envelope")
            XCTAssertEqual(day.notes.map(\.text), ["Sam replied"])
        }
    }

    func testUndoLaterOnOneDeviceBeatsAnOlderCompletion() throws {
        let base = CompassSnapshot(goal: Fixtures.goal, days: [Day(key: sat, step: step())])
        let a = try InMemoryStore(base).setStepDone(true, on: sat, at: at(15))
        let b = try InMemoryStore(a).setStepDone(false, on: sat, at: at(16))
        // A saves something unrelated afterwards (its envelope is the newest), still with its old step.
        var a2 = a
        a2.settings.cloudAssist = false
        a2.settings.updatedAt = at(17)
        let merged = SnapshotMerger.merge([envelope("A", savedAt: at(17), a2), envelope("B", savedAt: at(16), b)])!
        XCTAssertFalse(merged.snapshot.day(sat)!.step!.isDone, "B's later undo stands")
        XCTAssertFalse(merged.snapshot.settings.cloudAssist, "A's later settings stand")
    }

    func testSameNoteEditedOnBothKeepsTheLaterEditWhicheverEnvelopeIsNewer() {
        let note = Note(id: uid(901), text: "Sam is free Friday", createdAt: at(12))
        var early = note; early.text = "Sam is free Friday after 7"; early.updatedAt = at(18)
        var late = note; late.text = "Sam is free Saturday"; late.updatedAt = at(19)
        let a = CompassSnapshot(days: [Day(key: sat, notes: [late])])
        let b = CompassSnapshot(days: [Day(key: sat, notes: [early])])
        let merged = SnapshotMerger.merge([envelope("A", savedAt: at(19), a), envelope("B", savedAt: at(20), b)])!
        XCTAssertEqual(merged.snapshot.day(sat)?.notes.map(\.text), ["Sam is free Saturday"])
    }

    func testSettingsFollowTheLatestChangeNotTheLatestEnvelope() {
        var a = CompassSnapshot(goal: Fixtures.goal)
        a.settings.rhythm.morning = TimeOfDay(hour: 6, minute: 30)
        a.settings.updatedAt = at(9)
        var b = CompassSnapshot(goal: Fixtures.goal)   // never touched settings
        b.updateDay(sat) { $0.notes.append(Note(text: "x", createdAt: at(10))) }
        let merged = SnapshotMerger.merge([envelope("A", savedAt: at(9), a), envelope("B", savedAt: at(10), b)])!
        XCTAssertEqual(merged.snapshot.settings.rhythm.morning, TimeOfDay(hour: 6, minute: 30))
    }

    func testIntentionAndReflectionEditsFollowTheirOwnTimes() {
        let intention = Intention(text: "Patient.", createdAt: at(7))
        var edited = intention; edited.text = "Patient. Ship one thing."; edited.updatedAt = at(8)
        let r = Reflection(outcome: .moved, transcript: "Dinner.", createdAt: at(21), deviceID: phone.id)
        var r2 = r; r2.summary = "Dinner at Sam’s."; r2.updatedAt = at(22)
        let a = CompassSnapshot(days: [Day(key: sat, intention: edited, reflection: r2)])
        let b = CompassSnapshot(days: [Day(key: sat, intention: intention, reflection: r, morningSkipped: false)])
        let merged = SnapshotMerger.merge([envelope("A", savedAt: at(22), a), envelope("B", savedAt: at(23), b)])!
        let day = merged.snapshot.day(sat)!
        XCTAssertEqual(day.intention?.text, "Patient. Ship one thing.")
        XCTAssertEqual(day.reflection?.summary, "Dinner at Sam’s.")
        XCTAssertFalse(day.hasConflict)
    }

    func testGoalEditsMergeFieldWise() {
        var withWhy = Fixtures.goal
        withWhy.why = Note(text: "For my family", duration: 9, createdAt: at(8))
        withWhy.whyAsked = true
        withWhy.updatedAt = at(8)
        var renamed = Fixtures.goal
        renamed.why = nil
        renamed.whyAsked = false
        renamed.parts[0].title = "Earn my first million, calmly"
        renamed.parts.append(GoalPart(id: uid(902), title: "Read more", symbol: .sun))
        renamed.updatedAt = at(9)
        let merged = SnapshotMerger.merge([envelope("A", savedAt: at(8), CompassSnapshot(goal: withWhy)),
                                           envelope("B", savedAt: at(9), CompassSnapshot(goal: renamed))])!
        let g = merged.snapshot.goal!
        XCTAssertEqual(g.parts[0].title, "Earn my first million, calmly")
        XCTAssertTrue(g.parts.contains { $0.title == "Read more" })
        XCTAssertEqual(g.why?.text, "For my family", "the B7 answer from A is kept")
        XCTAssertTrue(g.whyAsked)
    }

    func testDataWithoutStampsDecodesAndCompletionStillWins() throws {
        // Schema 1 store: no schemaVersion, no updatedAt / deviceID anywhere.
        let json = """
        {"days":[{"key":{"year":2026,"month":11,"day":7},"morningSkipped":false,"notes":[{"createdAt":"2026-11-07T12:00:00Z",\
        "id":"00000000-0000-4000-8000-000000000903","text":"old","device":"This iPhone"}],"step":{"createdAt":"2026-11-07T07:30:00Z",\
        "completedAt":"2026-11-07T15:00:00Z","id":"00000000-0000-4000-8000-000000000900","size":"regular","source":"user","title":"T"}}],\
        "pastGoals":[],"settings":{"cloudAssist":true,"input":"voice","notificationsEnabled":true,\
        "rhythm":{"evening":{"hour":21,"minute":0},"morning":{"hour":7,"minute":0}}}}
        """
        let old = try JSONFileStore.decoder().decode(CompassSnapshot.self, from: Data(json.utf8))
        let day = try XCTUnwrap(old.day(sat))
        XCTAssertNil(day.step?.updatedAt)
        XCTAssertNil(day.notes.first?.deviceID)
        XCTAssertNil(old.settings.updatedAt)
        // An older copy of the same step without the completion loses to it (completedAt stands in).
        var open = day.step!; open.completedAt = nil
        let other = CompassSnapshot(days: [Day(key: sat, step: open)])
        let merged = SnapshotMerger.merge([envelope("A", savedAt: at(15), old), envelope("B", savedAt: at(16), other)])!
        XCTAssertTrue(merged.snapshot.day(sat)!.step!.isDone)

        // A format 1 envelope (no audio tombstones) decodes too.
        let v1 = #"{"deviceID":"X","deviceName":"iPad","format":1,"savedAt":"2026-11-07T12:00:00Z","snapshot":{},"tombstones":[]}"#
        let e = try JSONFileStore.decoder().decode(SyncEnvelope.self, from: Data(v1.utf8))
        XCTAssertEqual(e.format, 1)
        XCTAssertTrue(e.audioTombstones.isEmpty)
        XCTAssertTrue(e.isReadable)
        XCTAssertEqual(e.snapshot, .empty)
    }

    func testDeletedNoteAndStepDoNotComeBackFromAnotherDevice() {
        let note = Note(id: uid(910), text: "Lena wants numbers", createdAt: at(9))
        let base = CompassSnapshot(goal: Fixtures.goal, days: [Day(key: sat, step: step(), notes: [note])])
        var deleted = base
        deleted.updateDay(sat) { $0.notes = []; $0.step = nil }
        let a = LocalEdits.stamp(deleted, since: base, at: at(12), device: phone)
        XCTAssertEqual(Set(a.day(sat)?.removedItems?.map(\.id) ?? []), [note.id, step().id])

        // B still has both and saved later.
        let merged = SnapshotMerger.merge([envelope("A", savedAt: at(12), a), envelope("B", savedAt: at(13), base)])!
        XCTAssertTrue(merged.snapshot.day(sat)!.notes.isEmpty)
        XCTAssertNil(merged.snapshot.day(sat)!.step)

        // An edit made on B after the deletion wins.
        var edited = base
        edited.updateDay(sat) { $0.notes[0].text = "Lena wants numbers by Thursday"; $0.notes[0].updatedAt = at(14) }
        let later = SnapshotMerger.merge([envelope("A", savedAt: at(12), a), envelope("B", savedAt: at(14), edited)])!
        XCTAssertEqual(later.snapshot.day(sat)?.notes.map(\.text), ["Lena wants numbers by Thursday"])
    }

    // MARK: Stamping local edits

    func testLocalEditsStampChangedItemsOnly() {
        let base = CompassSnapshot(goal: Fixtures.goal, days: [Day(key: sat, step: step(),
                                   notes: [Note(id: uid(904), text: "a", createdAt: at(9))])])
        var edited = base
        edited.updateDay(sat) { $0.step?.completedAt = at(15) }
        edited.settings.cloudAssist = false
        let stamped = LocalEdits.stamp(edited, since: base, at: at(15, 1), device: phone)
        XCTAssertEqual(stamped.day(sat)?.step?.updatedAt, at(15, 1))
        XCTAssertNil(stamped.day(sat)?.notes.first?.updatedAt, "untouched note keeps no stamp")
        XCTAssertNil(stamped.goal?.updatedAt)
        XCTAssertEqual(stamped.settings.updatedAt, at(15, 1))
        XCTAssertEqual(LocalEdits.stamp(base, since: base, at: at(16), device: phone), base)

        // An edit that stamped itself (the widget) keeps its own time.
        var widget = base
        widget.updateDay(sat) { $0.step?.completedAt = at(14); $0.step?.updatedAt = at(14) }
        XCTAssertEqual(LocalEdits.stamp(widget, since: base, at: at(15), device: phone).day(sat)?.step?.updatedAt, at(14))
    }

    func testLocalEditsPutThisDeviceOnNewRecordingsOnly() {
        let base = CompassSnapshot(goal: Fixtures.goal, days: [Day(key: sat)])
        var edited = base
        edited.updateDay(sat) { day in
            day.notes.append(Note(text: "mine", createdAt: at(10), device: "This iPhone"))
            day.notes.append(Note(text: "from iPad", createdAt: at(11), device: "iPad"))
            day.reflection = ReflectionRules.draft(outcome: .moved, transcript: "Done.", recording: nil,
                                                   transcriptionFailed: false, partID: nil, now: at(21))
        }
        let key = sat.adding(days: 1, calendar: cal)
        edited.updateDay(key) { $0.notes.append(Note(text: "new day", createdAt: at(9, 0, key))) }
        let s = LocalEdits.stamp(edited, since: base, at: at(21, 1), device: phone)
        let notes = s.day(sat)!.notes
        XCTAssertEqual(notes[0].deviceID, phone.id)
        XCTAssertEqual(notes[0].device, "iPhone", "stored as the model, not \"This iPhone\"")
        XCTAssertNil(notes[1].deviceID, "another device's note keeps its own name")
        XCTAssertEqual(s.day(sat)?.reflection?.deviceID, phone.id)
        XCTAssertEqual(s.day(key)?.notes.first?.deviceID, phone.id)
    }

    // MARK: M10 · device identity in conflicts

    func testTwoIPhonesAreToldApartInE5() {
        let mine = Reflection(outcome: .moved, transcript: "Dinner with Sam.", createdAt: at(21, 14), device: "iPhone", deviceID: phone.id)
        let other = Reflection(outcome: .moved, transcript: "Cooked at Sam’s.", createdAt: at(21, 30), device: "iPhone", deviceID: "PHONE-C")
        let merged = SnapshotMerger.merge([envelope("PHONE-C", savedAt: at(21, 31), CompassSnapshot(days: [Day(key: sat, reflection: other)])),
                                           envelope(phone.id, savedAt: at(21, 15), CompassSnapshot(days: [Day(key: sat, reflection: mine)]))])!
        let versions = merged.snapshot.day(sat)!.reflectionVersions
        XCTAssertEqual(versions.count, 2)
        // On the first iPhone:
        XCTAssertEqual(versions.map(phone.label(for:)), ["This iPhone", "iPhone"])
        XCTAssertEqual(phone.defaultChoice(versions)?.createdAt, mine.createdAt)
        // On the other iPhone the labels swap, and its own version is preselected.
        let c = DeviceIdentity(id: "PHONE-C", model: "iPhone")
        XCTAssertEqual(versions.map(c.label(for:)), ["iPhone", "This iPhone"])
        XCTAssertEqual(c.defaultChoice(versions)?.createdAt, other.createdAt)
        // An iPad reads both as iPhones and shows a phone icon for them.
        XCTAssertEqual(versions.map(pad.label(for:)), ["iPhone", "iPhone"])
        XCTAssertFalse(pad.isTablet(versions[0]))
    }

    func testLegacyThisIPhoneLabelIsOnlyTrustedInFixtures() {
        let legacy = Reflection(outcome: .moved, transcript: "x", createdAt: at(21), device: "This iPhone")
        XCTAssertFalse(phone.isLocal(legacy))
        XCTAssertEqual(phone.label(for: legacy), "iPhone")
        let fixtures = DeviceIdentity(id: "fixture", model: "iPhone", trustsLegacyLabels: true)
        XCTAssertEqual(fixtures.label(for: legacy), "This iPhone")
        let ipad = Reflection(outcome: .moved, transcript: "y", createdAt: at(21, 30), device: "iPad")
        XCTAssertEqual(fixtures.label(for: ipad), "iPad")
        XCTAssertTrue(fixtures.isTablet(ipad))
        XCTAssertEqual(phone.label(for: Reflection(outcome: .moved, transcript: "", createdAt: at(1))), "Another device")
    }

    func testARedoOnTheSameDeviceIsNotAConflict() {
        let first = Reflection(outcome: .moved, transcript: "First take.", createdAt: at(21, 5), audioFileName: "a.m4a", deviceID: phone.id)
        let redo = Reflection(outcome: .moved, transcript: "Second take.", createdAt: at(21, 9), audioFileName: "b.m4a", deviceID: phone.id)
        // The iPad still has the first take (it synced before the redo).
        let merged = SnapshotMerger.merge([envelope(phone.id, savedAt: at(21, 10), CompassSnapshot(days: [Day(key: sat, reflection: redo)])),
                                           envelope(pad.id, savedAt: at(21, 20), CompassSnapshot(days: [Day(key: sat, reflection: first)]))])!
        let day = merged.snapshot.day(sat)!
        XCTAssertFalse(day.hasConflict)
        XCTAssertEqual(day.reflection?.transcript, "Second take.")
    }

    // MARK: M2 · wipe as a generation boundary

    /// The review's probe: wipe at 12:00; an offline device with all the history adds one note at 13:00.
    func testWipeFollowedByALaterEditOnAStaleDeviceDoesNotResurrectHistory() throws {
        let wipe = Fixtures.date(Fixtures.todayKey, 12)
        var stale = Fixtures.snapshot(today: nil)
        stale.settings.updatedAt = Fixtures.date(Fixtures.todayKey, 8)
        XCTAssertGreaterThan(stale.days.count, 100)
        let late = Note(text: "Offline thought", createdAt: Fixtures.date(Fixtures.todayKey, 13))
        stale.updateDay(Fixtures.todayKey) { $0.notes.append(late) }

        let marker = envelope("A", savedAt: wipe, .empty, wipedAt: wipe)
        let merged = try XCTUnwrap(SnapshotMerger.merge([marker, envelope("B", savedAt: Fixtures.date(Fixtures.todayKey, 13), stale)]))
        XCTAssertNil(merged.snapshot.goal, "the goal was created before the wipe")
        XCTAssertTrue(merged.snapshot.pastGoals.isEmpty)
        XCTAssertEqual(merged.snapshot.days.map(\.key), [Fixtures.todayKey], "only the day with post-wipe content")
        XCTAssertEqual(merged.snapshot.days.first?.notes, [late])
        XCTAssertEqual(merged.snapshot.settings, Settings(), "settings changed before the wipe go back to defaults")
        XCTAssertEqual(merged.wipedAt, wipe)
        XCTAssertFalse(merged.snapshot.referencedAudioFiles.contains { $0.contains("000000000200") })

        // Pairwise merges apply the boundary too, and a new goal set after the wipe is kept.
        let fresh = Goal(text: "Run a marathon.", createdAt: Fixtures.date(Fixtures.todayKey, 14))
        let restart = envelope("A", savedAt: fresh.createdAt, CompassSnapshot(goal: fresh), wipedAt: wipe)
        let pair = SnapshotMerger.merge(restart, envelope("B", savedAt: Fixtures.date(Fixtures.todayKey, 15), stale))
        XCTAssertEqual(pair.snapshot.goal?.id, fresh.id)
        XCTAssertEqual(pair.snapshot.days.count, 1)
    }

    func testOlderWipesDoNotTouchNewerGenerations() {
        let wipe = at(12)
        let after = CompassSnapshot(goal: Goal(text: "New.", createdAt: at(13)),
                                    days: [Day(key: sat, notes: [Note(text: "after", createdAt: at(14))])])
        let merged = SnapshotMerger.merge([envelope("A", savedAt: at(15), after, wipedAt: wipe),
                                           envelope("B", savedAt: at(11), CompassSnapshot(goal: Fixtures.goal))])!
        XCTAssertEqual(merged.snapshot.goal?.text, "New.")
        XCTAssertEqual(merged.snapshot.day(sat)?.notes.map(\.text), ["after"])
    }

    // MARK: M3 · audio deletion

    func testDeletedRecordingIsNeitherDownloadedNorUploadedAgain() {
        let note = Note(id: uid(905), text: "memo", duration: 12, createdAt: at(12))
        let kept = AudioNaming.fileName(for: note.id)
        let r = Reflection(outcome: .moved, transcript: "x", duration: 30, createdAt: at(21), audioFileName: "redo-new.m4a")
        let snap = CompassSnapshot(days: [Day(key: sat, notes: [note], reflection: r)])
        XCTAssertEqual(snap.referencedAudioFiles, [kept, "redo-new.m4a"])

        let tombstones = [AudioTombstone(name: "redo-old.m4a", deletedAt: at(21, 1))]
        // iCloud still has the old take; this device has nothing yet.
        let down = AudioSyncPlan.toDownload(remote: [kept, "redo-new.m4a", "redo-old.m4a", "orphan.m4a"], local: [],
                                            referenced: snap.referencedAudioFiles, tombstones: tombstones)
        XCTAssertEqual(down, [kept, "redo-new.m4a"])
        // A device that still has the old take and a discarded draft doesn't upload them.
        let up = AudioSyncPlan.toUpload(local: [kept, "redo-old.m4a", "draft.m4a"], remote: [],
                                        referenced: snap.referencedAudioFiles.union(["redo-old.m4a"]), tombstones: tombstones)
        XCTAssertEqual(up, [kept])
    }

    func testDayDeletedElsewhereRemovesItsRecordingsHere() {
        let note = Note(id: uid(906), text: "memo", duration: 12, createdAt: at(12))
        let before = CompassSnapshot(days: [Day(key: sat, notes: [note])])
        let deletion = envelope("B", savedAt: at(13), .empty)
        var withTombstone = deletion
        withTombstone.tombstones = [DayTombstone(key: sat, deletedAt: at(13))]
        let merged = SnapshotMerger.merge([envelope("A", savedAt: at(12), before), withTombstone])!
        XCTAssertNil(merged.snapshot.day(sat))
        let file = AudioNaming.fileName(for: note.id)
        let remove = AudioSyncPlan.toRemoveLocally(local: [file, "recording-now.m4a"], referencedBefore: before.referencedAudioFiles,
                                                   referencedAfter: merged.snapshot.referencedAudioFiles, tombstones: merged.audioTombstones)
        XCTAssertEqual(remove, [file], "a take being recorded right now is left alone")
    }

    func testAudioTombstonesTravelAndClearAtAWipe() {
        let t1 = AudioTombstone(name: "a.m4a", deletedAt: at(10))
        let t2 = AudioTombstone(name: "a.m4a", deletedAt: at(11))
        let t3 = AudioTombstone(name: "b.m4a", deletedAt: at(14))
        let merged = SnapshotMerger.merge([envelope("A", savedAt: at(11), .empty, audio: [t1, t3]),
                                           envelope("B", savedAt: at(12), .empty, audio: [t2])])!
        XCTAssertEqual(merged.audioTombstones, [t2, t3])
        let wiped = SnapshotMerger.merge([merged, envelope("C", savedAt: at(13), .empty, wipedAt: at(13))])!
        XCTAssertEqual(wiped.audioTombstones, [t3], "deletions before the wipe are moot")
    }

    // MARK: M5 · a second device's onboarding never replaces the goal

    func testFreshGoalFromAnotherDeviceNeverReplacesTheEstablishedOne() {
        var real = Fixtures.snapshot(today: nil)
        real.settings.rhythm.morning = TimeOfDay(hour: 6)
        real.settings.updatedAt = at(8)
        var fresh = CompassSnapshot(goal: Goal(text: "New.", createdAt: Fixtures.date(Fixtures.todayKey, 9)))
        fresh.settings.cloudAssist = false
        fresh.settings.updatedAt = Fixtures.date(Fixtures.todayKey, 9)

        for order in [[envelope("A", savedAt: at(8), real), envelope("B", savedAt: Fixtures.date(Fixtures.todayKey, 9), fresh)],
                      [envelope("B", savedAt: Fixtures.date(Fixtures.todayKey, 9), fresh), envelope("A", savedAt: at(8), real)]] {
            let m = SnapshotMerger.merge(order)!.snapshot
            XCTAssertEqual(m.goal?.id, Fixtures.goalID, "the established goal stays current")
            XCTAssertEqual(m.pastGoals.first?.text, "New.", "the newcomer is kept, not lost")
            XCTAssertEqual(m.pastGoals.first?.status, .replaced)
            XCTAssertEqual(m.settings.rhythm.morning, TimeOfDay(hour: 6), "onboarding settings don't replace the real ones")
            XCTAssertTrue(m.settings.cloudAssist)
        }
    }

    func testAGoalReplacedOnADeviceThatKnewItDoesReplace() {
        let old = Fixtures.goal
        let new = Goal(text: "Run a marathon.", createdAt: at(10))
        var replacedOld = old; replacedOld.status = .replaced; replacedOld.endedAt = at(10); replacedOld.updatedAt = at(10)
        let a = CompassSnapshot(goal: old)
        let b = CompassSnapshot(goal: new, pastGoals: [replacedOld])
        let merged = SnapshotMerger.merge(envelope("A", savedAt: at(12), a), envelope("B", savedAt: at(11), b))
        XCTAssertEqual(merged.snapshot.goal?.id, new.id)
        XCTAssertEqual(merged.snapshot.pastGoals.map(\.id), [old.id])
    }

    // MARK: M4 · restore with placeholder envelopes

    final class FakeSource: EnvelopeSource, @unchecked Sendable {
        let lock = NSLock()
        var available = true
        var listedAfterPolls = 0
        var envelopes: [String: SyncEnvelope] = [:]
        /// Polls (listings) until each file finishes downloading once requested.
        var downloadAfter: [String: Int] = [:]
        var requested: [String: Int] = [:]
        var polls = 0

        func isAvailable() -> Bool { available }
        func listEnvelopes() -> [EnvelopeFile] {
            lock.withLock {
                polls += 1
                guard polls > listedAfterPolls else { return [] }
                return envelopes.keys.sorted().map { name in
                    let after = downloadAfter[name] ?? 0
                    let ready = after == 0 || (requested[name].map { polls - $0 >= after } ?? false)
                    return EnvelopeFile(name: name, isDownloaded: ready)
                }
            }
        }
        func requestDownload(_ name: String) { lock.withLock { if requested[name] == nil { requested[name] = polls } } }
        func readEnvelope(_ name: String) -> SyncEnvelope? { lock.withLock { envelopes[name] } }
    }

    final class FakeClock: @unchecked Sendable {
        let lock = NSLock()
        var now = Date(timeIntervalSince1970: 0)
        func advance(_ t: TimeInterval) { lock.withLock { now += t } }
        func read() -> Date { lock.withLock { now } }
    }

    func reader(_ clock: FakeClock, timeout: TimeInterval = 10) -> BackupReader {
        BackupReader(timeout: timeout, emptyGrace: 3, pollInterval: 0.5, clock: { clock.read() }, sleep: { clock.advance($0) })
    }

    func testRestoreWaitsForPlaceholderEnvelopes() async {
        let source = FakeSource()
        source.envelopes = ["A.json": envelope("A", savedAt: at(9), Fixtures.restorableSnapshot),
                            "B.json": envelope("B", savedAt: at(10), CompassSnapshot(goal: Fixtures.goal))]
        source.downloadAfter = ["A.json": 3, "B.json": 5]
        let clock = FakeClock()
        let steps = ProgressLog()
        let read = reader(clock).read(from: source, progress: { steps.add($0) })
        XCTAssertEqual(read.pending, 0)
        XCTAssertEqual(read.envelopes.count, 2)
        guard case .available(let summary) = read.availability else { return XCTFail("\(read.availability)") }
        XCTAssertEqual(summary.goalText, Fixtures.goalText)
        XCTAssertEqual(steps.values.first, 0)
        XCTAssertEqual(steps.values.last, 1)
        XCTAssertEqual(Set(source.requested.keys), ["A.json", "B.json"], "placeholders were asked to download")
    }

    func testRestoreGivesEachNothingReasonItsOwnCase() {
        let clock = FakeClock()
        let off = FakeSource(); off.available = false
        XCTAssertEqual(reader(clock).read(from: off).availability, .nothing(.iCloudUnavailable))

        let empty = FakeSource()
        XCTAssertEqual(reader(clock).read(from: empty).availability, .nothing(.empty))

        let slow = FakeSource()
        slow.envelopes = ["A.json": envelope("A", savedAt: at(9), Fixtures.restorableSnapshot)]
        slow.downloadAfter = ["A.json": 1000]
        let read = reader(FakeClock(), timeout: 5).read(from: slow)
        XCTAssertEqual(read.pending, 1)
        XCTAssertEqual(read.availability, .nothing(.stillDownloading))

        XCTAssertNotEqual(NothingToRestoreReason.iCloudUnavailable.message, NothingToRestoreReason.empty.message)
        XCTAssertEqual(NothingToRestoreReason.empty.title, "No history found.")
    }

    func testRestoreWaitsForAFolderListedLate() {
        let source = FakeSource()
        source.listedAfterPolls = 3   // a new phone hasn't listed the folder yet
        source.envelopes = ["A.json": envelope("A", savedAt: at(9), Fixtures.restorableSnapshot)]
        source.downloadAfter = ["A.json": 1]
        guard case .available = reader(FakeClock()).read(from: source).availability else { return XCTFail() }
    }

    func testRestoreStopsWhenCancelled() {
        let source = FakeSource()
        source.envelopes = ["A.json": envelope("A", savedAt: at(9), Fixtures.restorableSnapshot)]
        source.downloadAfter = ["A.json": 1000]
        let read = reader(FakeClock(), timeout: 1000).read(from: source, isCancelled: { source.polls > 2 })
        XCTAssertEqual(read.pending, 1)
    }

    final class ProgressLog: @unchecked Sendable {
        var values: [Double] = []
        func add(_ v: Double) { values.append(v) }
    }
}

// MARK: - Item 19 · corrupt and newer stores

final class StoreRecoveryTests: XCTestCase {
    var dir: URL!
    var url: URL { dir.appendingPathComponent("compass.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("compass-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func quarantined() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "compass.json" }
    }

    func testSnapshotsCarryASchemaVersion() throws {
        let data = try JSONFileStore.encoder().encode(Fixtures.snapshot(today: nil))
        XCTAssertEqual(CompassSnapshot.schemaVersion(of: data), CompassSnapshot.currentSchema)
        XCTAssertEqual(CompassSnapshot.schemaVersion(of: Data("{}".utf8)), 1)
        XCTAssertNil(CompassSnapshot.schemaVersion(of: Data("not json".utf8)))
    }

    func testCorruptStoreIsCopiedAsideAndReported() throws {
        let garbage = Data("{\"goal\": {\"text\": tru".utf8)
        try garbage.write(to: url)
        let store = JSONFileStore(url: url)
        let (snapshot, problem) = store.loadRecovering(now: Fixtures.date(Fixtures.todayKey, 15, 30))
        XCTAssertEqual(snapshot, .empty)
        XCTAssertEqual(problem?.kind, .corrupt)
        XCTAssertFalse(problem?.blocksSaving ?? true)
        let copy = try XCTUnwrap(problem?.quarantinedCopy)
        XCTAssertEqual(try Data(contentsOf: copy), garbage, "the unreadable bytes are kept")
        XCTAssertTrue(copy.lastPathComponent.hasPrefix("compass.unreadable-"))

        // A second failure never overwrites the first copy.
        let again = store.loadRecovering(now: Fixtures.date(Fixtures.todayKey, 15, 30))
        XCTAssertNotEqual(again.problem?.quarantinedCopy, copy)
        XCTAssertEqual(try quarantined().count, 2)

        // Saving afterwards replaces the damaged file; the copies stay.
        try store.save(Fixtures.snapshot(today: nil))
        XCTAssertEqual(try store.load().goal?.text, Fixtures.goalText)
        XCTAssertEqual(try quarantined().count, 2)
    }

    func testNewerSchemaIsNeverReadAsEmptyOrOverwritten() throws {
        var obj = try JSONSerialization.jsonObject(with: JSONFileStore.encoder().encode(Fixtures.snapshot(today: nil))) as! [String: Any]
        obj["schemaVersion"] = CompassSnapshot.currentSchema + 1
        obj["futureField"] = ["anything": true]
        let newer = try JSONSerialization.data(withJSONObject: obj)
        try newer.write(to: url)

        let store = JSONFileStore(url: url)
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? StoreError, .newerSchema(CompassSnapshot.currentSchema + 1))
        }
        let (snapshot, problem) = store.loadRecovering()
        XCTAssertEqual(snapshot, .empty)
        XCTAssertEqual(problem?.kind, .newerSchema(CompassSnapshot.currentSchema + 1))
        XCTAssertTrue(problem?.blocksSaving ?? false)
        XCTAssertNotNil(problem?.quarantinedCopy)
        XCTAssertThrowsError(try store.save(.empty))
        XCTAssertThrowsError(try store.deleteAll())
        XCTAssertEqual(try Data(contentsOf: url), newer, "the newer file is untouched")
        // The widget's path (load → save) refuses too.
        XCTAssertThrowsError(try JSONFileStore(url: url).setStepDone(true, on: Fixtures.todayKey, at: Date()))
        XCTAssertEqual(try Data(contentsOf: url), newer)
    }

    func testReadableStoreHasNoProblem() throws {
        let store = JSONFileStore(url: url)
        XCTAssertNil(store.loadRecovering().problem, "a missing file is simply empty")
        try store.save(Fixtures.snapshot(today: nil))
        let (snapshot, problem) = store.loadRecovering()
        XCTAssertNil(problem)
        XCTAssertEqual(snapshot.goal?.text, Fixtures.goalText)
        XCTAssertTrue(try quarantined().isEmpty)
    }
}
