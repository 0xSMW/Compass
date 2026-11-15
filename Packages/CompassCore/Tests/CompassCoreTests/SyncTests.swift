import XCTest
@testable import CompassCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SyncMergeTests: XCTestCase {
    let cal = Fixtures.calendar
    let sat = DayKey(year: 2026, month: 11, day: 7)

    func at(_ h: Int, _ m: Int = 0, _ key: DayKey? = nil) -> Date { Fixtures.date(key ?? sat, h, m) }

    func envelope(_ id: String, _ name: String, savedAt: Date, _ snap: CompassSnapshot, tombstones: [DayTombstone] = [], wipedAt: Date? = nil) -> SyncEnvelope {
        SyncEnvelope(deviceID: id, deviceName: name, savedAt: savedAt, snapshot: snap, tombstones: tombstones, wipedAt: wipedAt)
    }

    func reflection(_ text: String, _ h: Int, _ m: Int, device: String) -> Reflection {
        Reflection(outcome: .moved, transcript: text, summary: text, duration: 20, partID: Fixtures.friendsPartID, createdAt: at(h, m), device: device)
    }

    func testDisjointDaysUnion() {
        var a = CompassSnapshot(goal: Fixtures.goal)
        a.upsert(Day(key: sat, notes: [Note(text: "a", createdAt: at(9))]))
        var b = CompassSnapshot(goal: Fixtures.goal)
        let sun = sat.adding(days: 1, calendar: cal)
        b.upsert(Day(key: sun, notes: [Note(text: "b", createdAt: at(9, 0, sun))]))
        let merged = SnapshotMerger.merge([envelope("A", "iPhone", savedAt: at(10), a), envelope("B", "iPad", savedAt: at(11), b)])!
        XCTAssertEqual(merged.snapshot.sortedDays.map(\.key), [sat, sun])
    }

    func testNotesMergeByIDAndEditsFollowNewerDevice() {
        let shared = Note(text: "Sam is free Friday", duration: 12, createdAt: at(12))
        var edited = shared
        edited.text = "Sam is free Friday after 7"
        let a = CompassSnapshot(days: [Day(key: sat, notes: [shared, Note(text: "from A", createdAt: at(13))])])
        let b = CompassSnapshot(days: [Day(key: sat, notes: [edited, Note(text: "from B", createdAt: at(14))])])
        let merged = SnapshotMerger.merge(envelope("A", "iPhone", savedAt: at(15), a), envelope("B", "iPad", savedAt: at(16), b))
        let notes = merged.snapshot.day(sat)!.notes
        XCTAssertEqual(notes.map(\.text), ["Sam is free Friday after 7", "from A", "from B"])
    }

    func testTwoDifferentReflectionsBecomeAConflict() {
        let phone = reflection("Dinner with Sam and Priya.", 21, 14, device: "This iPhone")
        let pad = reflection("Cooked at Sam’s. Lisbon trip before March.", 21, 30, device: "iPad")
        let a = CompassSnapshot(days: [Day(key: sat, reflection: phone)])
        let b = CompassSnapshot(days: [Day(key: sat, reflection: pad)])
        let ab = SnapshotMerger.merge(envelope("A", "iPhone", savedAt: at(21, 40), a), envelope("B", "iPad", savedAt: at(21, 41), b))
        let ba = SnapshotMerger.merge(envelope("B", "iPad", savedAt: at(21, 41), b), envelope("A", "iPhone", savedAt: at(21, 40), a))
        XCTAssertEqual(ab.snapshot, ba.snapshot, "merge is order independent")
        let day = ab.snapshot.day(sat)!
        XCTAssertTrue(day.hasConflict)
        XCTAssertEqual(day.reflection, phone)
        XCTAssertEqual(day.mergeCandidates, [pad])
        XCTAssertEqual(day.reflectionVersions.count, 2)
    }

    func testSameReflectionEditedTakesNewerVersionWithoutConflict() {
        let original = reflection("Dinner with Sam and Priya.", 21, 14, device: "This iPhone")
        var edited = original
        edited.summary = "Dinner at Sam’s."
        let a = CompassSnapshot(days: [Day(key: sat, reflection: original)])
        let b = CompassSnapshot(days: [Day(key: sat, reflection: edited)])
        let merged = SnapshotMerger.merge(envelope("A", "iPhone", savedAt: at(21, 20), a), envelope("B", "iPhone", savedAt: at(22), b))
        let day = merged.snapshot.day(sat)!
        XCTAssertFalse(day.hasConflict)
        XCTAssertEqual(day.reflection?.summary, "Dinner at Sam’s.")
    }

    func testResolvingKeepsBothRecordingsAndConverges() {
        let phone = reflection("Dinner with Sam and Priya.", 21, 14, device: "This iPhone")
        let pad = reflection("Cooked at Sam’s. Lisbon trip before March.", 21, 30, device: "iPad")
        var day = Day(key: sat, reflection: phone, mergeCandidates: [pad])
        day.resolveConflict(keeping: pad)
        XCTAssertEqual(day.reflection, pad)
        XCTAssertFalse(day.hasConflict)
        XCTAssertEqual(day.notes.count, 1)
        XCTAssertEqual(day.notes[0].duration, 20, "the other recording stays on the day")
        XCTAssertEqual(day.notes[0].text, "Dinner with Sam and Priya.")

        // The iPhone resolved; the iPad still has its own original reflection only.
        let resolved = CompassSnapshot(days: [day])
        let padOnly = CompassSnapshot(days: [Day(key: sat, reflection: pad)])
        let phoneOld = CompassSnapshot(days: [Day(key: sat, reflection: phone)])
        let merged = SnapshotMerger.merge([
            envelope("A", "iPhone", savedAt: at(22), resolved),
            envelope("B", "iPad", savedAt: at(21, 31), padOnly),
            envelope("C", "iPhone old", savedAt: at(21, 15), phoneOld),
        ])!
        let m = merged.snapshot.day(sat)!
        XCTAssertFalse(m.hasConflict, "a settled conflict does not come back")
        XCTAssertEqual(m.reflection, pad)
        XCTAssertEqual(m.notes.count, 1)
    }

    func testKeepBothKeepsShownSummary() {
        let phone = reflection("Dinner with Sam and Priya.", 21, 14, device: "This iPhone")
        let pad = reflection("Cooked at Sam’s.", 21, 30, device: "iPad")
        var day = Day(key: sat, reflection: phone, mergeCandidates: [pad])
        day.keepBothVersions()
        XCTAssertEqual(day.reflection, phone)
        XCTAssertEqual(day.notes.map(\.text), ["Cooked at Sam’s."])
        XCTAssertNil(day.mergeCandidates)
    }

    func testTombstoneRemovesOlderDayButNotNewerContent() {
        let day = Day(key: sat, notes: [Note(text: "old", createdAt: at(9))])
        let a = CompassSnapshot(days: [])
        let b = CompassSnapshot(days: [day])
        let merged = SnapshotMerger.merge(envelope("A", "iPhone", savedAt: at(12), a, tombstones: [DayTombstone(key: sat, deletedAt: at(11))]),
                                          envelope("B", "iPad", savedAt: at(10), b))
        XCTAssertNil(merged.snapshot.day(sat))
        XCTAssertEqual(merged.tombstones.count, 1)

        let newer = Day(key: sat, notes: [Note(text: "after", createdAt: at(13))])
        let merged2 = SnapshotMerger.merge(merged, envelope("B", "iPad", savedAt: at(14), CompassSnapshot(days: [newer])))
        XCTAssertEqual(merged2.snapshot.day(sat)?.notes.map(\.text), ["after"])
    }

    func testWipeDropsEnvelopesSavedBefore() {
        let old = CompassSnapshot(goal: Fixtures.goal, days: [Day(key: sat, notes: [Note(text: "x", createdAt: at(9))])])
        let merged = SnapshotMerger.merge([
            envelope("A", "iPhone", savedAt: at(12), .empty, wipedAt: at(11)),
            envelope("B", "iPad", savedAt: at(10), old),
        ])!
        XCTAssertNil(merged.snapshot.goal)
        XCTAssertTrue(merged.snapshot.days.isEmpty)
        XCTAssertEqual(merged.wipedAt, at(11))
    }

    func testReplacedGoalOnOneDeviceMovesToPast() {
        let old = Fixtures.goal
        let new = Goal(text: "Run a marathon.", createdAt: at(10))
        var ended = old
        ended.status = .replaced
        ended.endedAt = at(10)
        let a = CompassSnapshot(goal: old)
        let b = CompassSnapshot(goal: new, pastGoals: [ended])
        // The device with the old goal saved later (it didn't touch the goal); the new goal still wins,
        // because the replacing device knew the old one (it is in its past goals).
        let merged = SnapshotMerger.merge(envelope("A", "iPhone", savedAt: at(12), a), envelope("B", "iPad", savedAt: at(11), b))
        XCTAssertEqual(merged.snapshot.goal?.id, new.id)
        XCTAssertEqual(merged.snapshot.pastGoals.map(\.id), [old.id])
        XCTAssertEqual(merged.snapshot.pastGoals.first?.status, .replaced)
    }

    func testAchievedVersionWinsOverActive() {
        var achieved = Fixtures.goal
        achieved.status = .achieved
        achieved.endedAt = at(21)
        let merged = SnapshotMerger.merge(envelope("A", "iPhone", savedAt: at(20), CompassSnapshot(goal: achieved)),
                                          envelope("B", "iPad", savedAt: at(22), CompassSnapshot(goal: Fixtures.goal)))
        XCTAssertEqual(merged.snapshot.goal?.status, .achieved)
    }

    func testEnvelopeRoundTripsThroughJSON() throws {
        let e = envelope("A", "iPhone", savedAt: at(12), Fixtures.fixture(for: .e5).snapshot, tombstones: [DayTombstone(key: sat, deletedAt: at(11))])
        let data = try JSONFileStore.encoder().encode(e)
        let back = try JSONFileStore.decoder().decode(SyncEnvelope.self, from: data)
        XCTAssertEqual(back, e)
    }

    func testE5FixtureIsAConflict() {
        let f = Fixtures.fixture(for: .e5)
        XCTAssertTrue(f.snapshot.day(f.selectedDay!)!.hasConflict)
    }
}

final class BackupTests: XCTestCase {
    func testFixtureCountsMatchBoards() {
        let s = Fixtures.fixture(for: .h2).snapshot
        XCTAssertEqual(s.pastGoals.count, 2)
        XCTAssertGreaterThan(s.totalSteps, 150)
        XCTAssertGreaterThan(s.memoCount, 150)
    }

    func testPastGoalLines() {
        let s = Fixtures.fixture(for: .g3).snapshot
        XCTAssertEqual(s.pastGoals.map { s.steps(for: $0) }, [64, 38])
        XCTAssertEqual(s.steps(for: s.goal!), Fixtures.fixture(for: .g1).snapshot.movedCount)
        for g in s.pastGoals {
            XCTAssertTrue(s.days(for: g).allSatisfy { $0.key.date(in: Fixtures.calendar) <= g.endedAt! })
        }
    }

    func testFakeRestorer() async throws {
        let yes = FakeBackupRestoring(conditions: Fixtures.fixture(for: .r1).conditions)
        guard case .available(let summary) = await yes.availability() else { return XCTFail() }
        XCTAssertEqual(summary.goals, 1)
        XCTAssertTrue(summary.line.hasSuffix("· 1 goal"))
        let restored = try await yes.restore { _ in }
        XCTAssertEqual(restored.goal?.text, Fixtures.goalText)

        let no = FakeBackupRestoring(conditions: Fixtures.fixture(for: .r3).conditions)
        let availability = await no.availability()
        XCTAssertEqual(availability, .nothing(.empty))
    }
}

final class HTTPCloudAssistTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    func client(endpoint: String? = "https://assist.example.com/v1", on: Bool = true, reply: @escaping @Sendable (URLRequest) throws -> (Data, Int)) -> (HTTPCloudAssist, Recorder) {
        let rec = Recorder()
        let c = HTTPCloudAssist(configuration: CloudAssistConfiguration(endpointString: endpoint), switchOn: on) { req in
            rec.requests.append(req)
            let (data, status) = try reply(req)
            return (data, HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        return (c, rec)
    }

    func testDisabledWithoutEndpoint() async {
        for endpoint in [nil, "", "$(COMPASS_CLOUD_ASSIST_ENDPOINT)", "ftp://x"] as [String?] {
            let (c, rec) = client(endpoint: endpoint) { _ in (Data(), 200) }
            XCTAssertFalse(c.isEnabled)
            do { _ = try await c.summarize(transcript: "hi", goal: nil); XCTFail() } catch {
                XCTAssertEqual(error as? CloudAssistError, .disabled)
            }
            XCTAssertTrue(rec.requests.isEmpty)
        }
    }

    func testDisabledWhenSwitchOff() async {
        let (c, rec) = client(on: false) { _ in (Data(), 200) }
        XCTAssertFalse(c.isEnabled)
        do { _ = try await c.clarifyingQuestion(for: "Be happier."); XCTFail() } catch {
            XCTAssertEqual(error as? CloudAssistError, .disabled)
        }
        XCTAssertTrue(rec.requests.isEmpty)
        c.switchOn = true
        XCTAssertTrue(c.isEnabled)
    }

    func testSummarizePostsJSON() async throws {
        let (c, rec) = client { _ in (Data(#"{"summary":"Texted Sam. Friday dinner is on."}"#.utf8), 200) }
        let s = try await c.summarize(transcript: Fixtures.reflectionTranscript, goal: Fixtures.goal)
        XCTAssertEqual(s, Fixtures.reflectionSummary)
        let req = try XCTUnwrap(rec.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://assist.example.com/v1/summarize")
        XCTAssertEqual(req.httpMethod, "POST")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body?["transcript"], Fixtures.reflectionTranscript)
        XCTAssertEqual(body?["goal"], Fixtures.goalText)
    }

    func testOfflineMapsToOffline() async {
        let (c, _) = client { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await c.summarize(transcript: "x", goal: nil); XCTFail() } catch {
            XCTAssertEqual(error as? CloudAssistError, .offline)
        }
    }

    func testBadStatusAndMalformed() async {
        let (c, _) = client { _ in (Data("{}".utf8), 500) }
        do { _ = try await c.summarize(transcript: "x", goal: nil); XCTFail() } catch {
            XCTAssertEqual(error as? HTTPCloudAssistError, .badStatus(500))
        }
        let (c2, _) = client { _ in (Data("nope".utf8), 200) }
        do { _ = try await c2.summarize(transcript: "x", goal: nil); XCTFail() } catch {
            XCTAssertEqual(error as? HTTPCloudAssistError, .malformedResponse)
        }
    }

    func testStepAndParts() async throws {
        let friends = Fixtures.friendsPartID.uuidString
        let (c, _) = client { req in
            if req.url!.lastPathComponent == "step" {
                return (Data(#"{"title":"Text Sam about Friday dinner","partID":"\#(friends)","hint":"about 2 minutes"}"#.utf8), 200)
            }
            return (Data(#"{"parts":[{"title":"Earn my first million","symbol":"we"},{"title":"Stay strong"}]}"#.utf8), 200)
        }
        let idea = try await c.suggestStep(goal: Fixtures.goal, part: nil, size: .regular, recent: [])
        XCTAssertEqual(idea.title, Fixtures.stepTitle)
        XCTAssertEqual(idea.partID, Fixtures.friendsPartID)
        XCTAssertEqual(idea.hint, "about 2 minutes")
        let parts = try await c.proposeParts(for: Fixtures.goalText)
        XCTAssertEqual(parts.map(\.title), ["Earn my first million", "Stay strong"])
        XCTAssertEqual(parts.map(\.symbol), [.wealth, .strength])
    }
}
