import Foundation
import XCTest
@testable import CompassCore

/// The cheap stored form the app holds after every commit and puts in every envelope
/// (`JSONFileStore.asStored(_:against:)`, `asStored(_:snapshotIsStored:)`) is exactly the full round trip.
/// And a failed save that goes through on a retry tells sync to record a wipe it held back.
final class StoredFormTests: XCTestCase {
    /// Deterministic, so a failure names a seed that reproduces it.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    let cal = Fixtures.calendar

    var fixtures: [CompassSnapshot] {
        var all = [CompassSnapshot.empty, Fixtures.totalsSnapshot, Fixtures.restorableSnapshot]
        var seen = Set<CompassSnapshot>(all)
        for id in ScreenID.allCases {
            let s = Fixtures.fixture(for: id).snapshot
            if seen.insert(s).inserted { all.append(s) }
        }
        return all
    }

    /// A date with a fraction of a second, as `Date()` gives one.
    func fractional(_ g: inout SplitMix) -> Date {
        let base = Fixtures.date(Fixtures.todayKey, 0).addingTimeInterval(TimeInterval(Int.random(in: -400...30, using: &g)) * 86_400)
        return base.addingTimeInterval(Double(Int.random(in: 0..<86_400, using: &g)) + Double.random(in: 0.001..<0.999, using: &g))
    }

    /// One edit the app could make (or a merge could bring), dated with fractions of a second.
    func edit(_ s: inout CompassSnapshot, _ g: inout SplitMix) {
        let now = fractional(&g)
        let key = s.days.randomElement(using: &g)?.key ?? DayKey(now, calendar: cal)
        switch Int.random(in: 0..<16, using: &g) {
        case 0:
            s.updateDay(key) { $0.notes.append(Note(text: "memo", duration: Double.random(in: 0...90, using: &g), createdAt: now,
                                                    deviceID: "A", updatedAt: now)) }
        case 1:
            s.updateDay(key) { $0.step = Step(title: "step", createdAt: now, updatedAt: now) }
        case 2:
            s.updateDay(key) { $0.step?.completedAt = now; $0.step?.completionChangedAt = now }
        case 3:
            s.updateDay(key) { $0.reflection = Reflection(outcome: .moved, transcript: "evening", duration: 30, createdAt: now,
                                                          audioFileName: "\(UUID()).m4a", deviceID: "A", updatedAt: now) }
        case 4:
            s.updateDay(key) { $0.intention = Intention(text: "today", createdAt: now, updatedAt: now) }
        case 5:
            s.updateDay(key) {
                if let id = $0.notes.first?.id {
                    $0.notes.removeFirst()
                    $0.removedItems = ($0.removedItems ?? []) + [ItemTombstone(id: id, deletedAt: now)]
                }
            }
        case 6:
            s.updateDay(key) { $0.morningSkipped = true; $0.morningSkippedAt = now }
        case 7:
            s.updateDay(key) { $0.mergeCandidates = [Reflection(outcome: .notToday, transcript: "other", createdAt: now)] }
        case 8:
            // A new day, dated today.
            s.updateDay(DayKey(now, calendar: cal)) { $0.notes.append(Note(text: "new day", createdAt: now)) }
        case 9:
            s.days.removeAll { $0.key == key }
        case 10:
            s.days.shuffle(using: &g)
        case 11:
            if s.goal == nil { s.goal = Goal(text: "G", createdAt: now) }
            s.goal?.updatedAt = now
            s.goal?.text += "."
        case 12:
            if var old = s.goal {
                old.status = .replaced
                old.endedAt = now
                s.pastGoals.insert(old, at: 0)
            }
            s.goal = Goal(text: "Next", parts: [GoalPart(title: "Part", symbol: .sun)], createdAt: now, updatedAt: now)
        case 13:
            s.settings.rhythm.morning = TimeOfDay(hour: Int.random(in: 5...9, using: &g))
            s.settings.updatedAt = now
            s.settings.rhythmUpdatedAt = now
        case 14:
            s.settings.cloudAssist.toggle()
            s.settings.cloudAssistUpdatedAt = now
        default:
            // A second day under a key that already has one (never made by `upsert`, but any order or
            // duplicate must still give the full round trip).
            if let d = s.days.randomElement(using: &g) {
                var dup = d
                dup.notes.append(Note(text: "dup", createdAt: now))
                s.days.append(dup)
            }
        }
    }

    func testOnlyWhatChangedGivesTheFullRoundTrip() {
        var truncated = 0
        for (f, fixture) in fixtures.enumerated() {
            for seed in 0..<6 {
                var g = SplitMix(state: UInt64(f * 1000 + seed))
                // Successive commits: each starts from the previous result, as `AppModel.snapshot` does.
                var held = JSONFileStore.asStored(fixture)
                for step in 0..<6 {
                    var next = held
                    for _ in 0..<Int.random(in: 1...3, using: &g) { edit(&next, &g) }
                    let cheap = JSONFileStore.asStored(next, against: held)
                    let full = JSONFileStore.asStored(next)
                    XCTAssertEqual(cheap, full, "fixture \(f) seed \(seed) step \(step)")
                    if full != next { truncated += 1 }
                    held = cheap
                }
                // Nothing changed: nothing to do.
                XCTAssertEqual(JSONFileStore.asStored(held, against: held), held)
            }
        }
        // Most edits carried a fraction of a second that the round trip dropped.
        XCTAssertGreaterThan(truncated, fixtures.count * 6 * 6 / 2)
    }

    /// Fixtures are already whole seconds; a stored snapshot against `.empty` (every day changed) and
    /// `.empty` against a stored snapshot are both the full round trip.
    func testFixturesAndEdgesAgreeWithTheFullRoundTrip() {
        for fixture in fixtures {
            XCTAssertEqual(JSONFileStore.asStored(fixture, against: .empty), JSONFileStore.asStored(fixture))
            XCTAssertEqual(JSONFileStore.asStored(fixture, against: fixture), fixture)
            XCTAssertEqual(JSONFileStore.asStored(.empty, against: JSONFileStore.asStored(fixture)), .empty)
        }
    }

    /// Read from a file, a snapshot's dates are whole seconds: what `asStored(_:against:)` holds is what
    /// the store file holds.
    func testTheCheapFormIsWhatAFileReadsBack() throws {
        var g = SplitMix(state: 7)
        let held = JSONFileStore.asStored(Fixtures.totalsSnapshot)
        var next = held
        for _ in 0..<5 { edit(&next, &g) }
        let cheap = JSONFileStore.asStored(next, against: held)
        let read = try JSONFileStore.decoder().decode(CompassSnapshot.self, from: JSONFileStore.encoder().encode(next))
        XCTAssertEqual(cheap, read)
    }

    func testAnEnvelopeAroundAStoredSnapshotGivesTheFullRoundTrip() {
        var g = SplitMix(state: 42)
        for fixture in fixtures {
            let snapshot = JSONFileStore.asStored(fixture)
            for _ in 0..<10 {
                let env = SyncEnvelope(deviceID: "A", deviceName: "iPhone", savedAt: fractional(&g), snapshot: snapshot,
                                       tombstones: [DayTombstone(key: Fixtures.todayKey, deletedAt: fractional(&g))],
                                       wipedAt: Bool.random(using: &g) ? fractional(&g) : nil,
                                       audioTombstones: [AudioTombstone(name: "a.m4a", deletedAt: fractional(&g))])
                let cheap = JSONFileStore.asStored(env, snapshotIsStored: true)
                XCTAssertEqual(cheap, JSONFileStore.asStored(env))
                XCTAssertNotEqual(cheap, env)
                XCTAssertEqual(cheap.savedAt.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1), 0)
            }
        }
        // A device that never changed anything itself.
        let never = SyncEnvelope(deviceID: "A", deviceName: "iPhone", savedAt: .distantPast, snapshot: .empty)
        XCTAssertEqual(JSONFileStore.asStored(never, snapshotIsStored: true), JSONFileStore.asStored(never))
        // Not known to be stored: the whole envelope goes through.
        var raw = never
        raw.snapshot = CompassSnapshot(goal: Goal(text: "G", createdAt: Date(timeIntervalSinceReferenceDate: 8e8 + 0.6)))
        XCTAssertEqual(JSONFileStore.asStored(raw, snapshotIsStored: false), JSONFileStore.asStored(raw))
    }

    // MARK: A retried save (review 9, P2)

    func testARetryThatGoesThroughReloadsTheWidgetAndRecordsTheSyncState() {
        XCTAssertEqual(StoreReload.afterRetry(saveFailed: false), .init(reloadWidgets: true, recordSyncState: true))
        XCTAssertEqual(StoreReload.afterRetry(saveFailed: true), .init(reloadWidgets: false, recordSyncState: false))
    }

    /// H6's last case: the wipe is held back while the save fails and recorded by the state write the
    /// successful retry now triggers, so a kill before the next pull no longer loses it.
    func testTheStateWriteAfterASuccessfulRetryRecordsTheHeldBackWipe() {
        let key = Fixtures.todayKey
        let old = WipeRecord(wipedAt: key.date(in: cal, hour: 8), appliedWipe: key.date(in: cal, hour: 8))
        let new = WipeRecord(wipedAt: key.date(in: cal, hour: 10), appliedWipe: key.date(in: cal, hour: 10))
        // The merge that carried the wipe out: the store write failed, the file keeps the old wipe.
        var onDisk = WipeRecord.toSave(inMemory: new, onDisk: old, storeHoldsModel: false)
        XCTAssertEqual(onDisk, old)
        // Becoming active: the retry goes through, and sync is told to write its state.
        let after = StoreReload.afterRetry(saveFailed: false)
        XCTAssertTrue(after.recordSyncState)
        onDisk = WipeRecord.toSave(inMemory: new, onDisk: onDisk, storeHoldsModel: true)
        XCTAssertEqual(onDisk, new)
    }
}
