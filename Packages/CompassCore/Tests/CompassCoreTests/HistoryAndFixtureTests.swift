import XCTest
@testable import CompassCore

final class HistoryTests: XCTestCase {
    let cal = Fixtures.calendar
    var builder: HistoryBuilder { HistoryBuilder(calendar: cal) }

    func testThisWeekMatchesBoard() {
        let snap = Fixtures.snapshot(today: Fixtures.today(done: true, reflection: Fixtures.savedReflection))
        let week = builder.thisWeek(snapshot: snap, today: Fixtures.todayKey)
        // history.html: Wednesday → Today = 1101111 ("Sick. Rested." on Friday).
        XCTAssertEqual(week.marks, [.moved, .moved, .missed, .moved, .moved, .moved, .moved])
        XCTAssertEqual(week.entries[2].text, "Sick. Rested.")
        XCTAssertEqual(week.entries.last?.text, Fixtures.reflectionSummary)
        XCTAssertEqual(builder.label(for: week), "4–10 Nov")
    }

    func testTodayUnresolvedIsEmptyMark() {
        let snap = Fixtures.snapshot(today: Fixtures.today())
        XCTAssertEqual(builder.mark(for: Fixtures.todayKey, snapshot: snap, today: Fixtures.todayKey), .empty)
        var notToday = Fixtures.savedReflection
        notToday.outcome = .notToday
        let snap2 = Fixtures.snapshot(today: Fixtures.today(reflection: notToday))
        XCTAssertEqual(builder.mark(for: Fixtures.todayKey, snapshot: snap2, today: Fixtures.todayKey), .missed)
    }

    func testEarlierWeeksPatternsAndLabels() {
        let snap = Fixtures.snapshot(today: Fixtures.today(done: true))
        let weeks = builder.weeks(snapshot: snap, today: Fixtures.todayKey)
        let expected: [(String, String)] = [
            ("4–10 Nov", "1101111"), ("28 Oct–3 Nov", "1111011"), ("21–27 Oct", "1011101"),
            ("14–20 Oct", "0000011"), ("7–13 Oct", "0000000"), ("30 Sep–6 Oct", "1100000"),
            ("23–29 Sep", "1111110"), ("16–22 Sep", "1110111"), ("9–15 Sep", "1111111"),
        ]
        for (i, (label, pattern)) in expected.enumerated() {
            XCTAssertEqual(builder.label(for: weeks[i]), label)
            XCTAssertEqual(weeks[i].marks.map { $0 == .moved ? "1" : "0" }.joined(), pattern, label)
        }
        // Empty weeks stay visible.
        XCTAssertTrue(weeks[4].isEmpty)
        // Goes back to the goal's start (14 Apr).
        XCTAssertLessThanOrEqual(weeks.last!.start, DayKey(year: 2026, month: 4, day: 14))
        // Days before the goal started draw nothing.
        XCTAssertTrue(weeks.last!.entries.contains { $0.mark == .empty })
    }

    func testGoalMarker() {
        XCTAssertFalse(builder.goalMarker(snapshot: Fixtures.fixture(for: .g1).snapshot).achieved)
        let g2 = builder.goalMarker(snapshot: Fixtures.fixture(for: .g2).snapshot)
        XCTAssertTrue(g2.achieved)
        XCTAssertGreaterThan(g2.totalSteps, 100)
    }
}

final class FixtureTests: XCTestCase {
    func testSixtySixScreens() {
        XCTAssertEqual(ScreenID.allCases.count, 66)
        let perFlow = Dictionary(grouping: ScreenID.allCases, by: \.flow).mapValues(\.count)
        XCTAssertEqual(perFlow[.onboarding], 13)
        XCTAssertEqual(perFlow[.morning], 8)
        XCTAssertEqual(perFlow[.today], 12)
        XCTAssertEqual(perFlow[.evening], 13)
        XCTAssertEqual(perFlow[.history], 6)
        XCTAssertEqual(perFlow[.lapse], 3)
        XCTAssertEqual(perFlow[.goal], 3)
        XCTAssertEqual(perFlow[.settings], 2)
        XCTAssertEqual(perFlow[.system], 6)
    }

    func testEveryScreenHasFixtureAndCaption() {
        for id in ScreenID.allCases {
            let f = Fixtures.fixture(for: id)
            XCTAssertEqual(f.id, id)
            XCTAssertFalse(id.title.isEmpty)
            XCTAssertFalse(id.caption.isEmpty)
            if id.flow != .onboarding { XCTAssertNotNil(f.snapshot.goal, id.rawValue) }
        }
    }

    func testDesignRenderNames() {
        XCTAssertEqual(ScreenID.c4.designRender, "V3Today-04.png")
        XCTAssertEqual(ScreenID.a8.designRender, "V3Onboarding-13.png")
        XCTAssertEqual(ScreenID.r1.designRender, "V3Onboarding-10.png")
        XCTAssertEqual(ScreenID.d8.designRender, "V3Evening-13.png")
        XCTAssertEqual(ScreenID.i6.designRender, "V3System-06.png")
        XCTAssertEqual(ScreenID(argument: "c11b"), .c11b)
        XCTAssertEqual(ScreenID(argument: "D1L"), .d1L)
        XCTAssertNil(ScreenID(argument: "Z9"))
    }

    func testLargestTextStates() {
        XCTAssertEqual(Set(ScreenID.allCases.filter(\.isLargestText)), [.a8, .b8, .c11, .c11b, .d7, .d8, .e6])
    }

    func testFixtureCopy() {
        XCTAssertEqual(Fixtures.fixture(for: .c3).today?.step?.title, "Text Sam about Friday dinner")
        XCTAssertEqual(Fixtures.fixture(for: .c3).today?.intention?.text, "Patient. Ship one thing.")
        XCTAssertEqual(Fixtures.fixture(for: .c4).today?.step?.isDone, true)
        XCTAssertNil(Fixtures.fixture(for: .c1).today?.step)
        XCTAssertEqual(Fixtures.fixture(for: .d6).conditions.online, false)
        XCTAssertEqual(Fixtures.fixture(for: .i1).conditions.microphone, .denied)
        XCTAssertEqual(Fixtures.fixture(for: .i4).conditions.storageFull, true)
        XCTAssertEqual(Fixtures.fixture(for: .i3).calendar.timeZone.identifier, "Asia/Tokyo")
        XCTAssertEqual(Fixtures.fixture(for: .g3).snapshot.pastGoals.count, 2)
        let yesterday = Fixtures.todayKey.adding(days: -1, calendar: Fixtures.calendar)
        XCTAssertEqual(Fixtures.fixture(for: .i5).snapshot.day(yesterday)?.step?.title, "Pitch Ridgeline")
        XCTAssertEqual(Fixtures.fixture(for: .e5).snapshot.day(DayKey(year: 2026, month: 11, day: 7))?.mergeCandidates?.count, 1)
    }

    func testFakesAreDeterministic() async throws {
        let t = FakeSpeechTranscriber(script: "Patient. Ship one thing.")
        var last: TranscriptUpdate?
        for try await u in t.live() { last = u }
        XCTAssertEqual(last, TranscriptUpdate(settled: "Patient. Ship one thing.", isFinal: true))
        XCTAssertEqual(FakeSpeechTranscriber.updates(for: "a b").first, TranscriptUpdate(settled: "", pending: "a"))

        let cloud = FakeCloudAssist()
        let summary = try await cloud.summarize(transcript: Fixtures.reflectionTranscript, goal: nil)
        XCTAssertEqual(summary, "Texted Sam. Friday dinner is on.")
        let idea = try await cloud.suggestStep(goal: Fixtures.goal, part: Fixtures.friendsPart, size: .regular, recent: [])
        XCTAssertEqual(idea.title, Fixtures.stepTitle)

        cloud.isEnabled = false
        do { _ = try await cloud.summarize(transcript: "x", goal: nil); XCTFail() } catch { XCTAssertEqual(error as? CloudAssistError, .disabled) }

        let rec = FakeAudioRecorder(permission: .denied)
        do { try await rec.start(); XCTFail() } catch { XCTAssertEqual(error as? RecorderError, .permissionDenied) }
        let full = FakeAudioRecorder(storageFull: true)
        do { try await full.start(); XCTFail() } catch { XCTAssertEqual(error as? RecorderError, .storageFull) }
        let ok = FakeAudioRecorder()
        try await ok.start()
        let clip = try await ok.stop()
        XCTAssertEqual(clip.duration, 14)
    }
}
