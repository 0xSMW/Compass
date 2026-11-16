import XCTest
@testable import CompassCore

final class DayEngineTests: XCTestCase {
    let cal = Fixtures.calendar
    var engine: DayEngine { DayEngine(calendar: cal) }
    let today = Fixtures.todayKey

    func at(_ h: Int, _ m: Int = 0) -> Date { Fixtures.date(today, h, m) }

    func testSameStageIgnoresPlanDetailsButNotTheScreen() {
        // F2: a merge re-judges the screen only when today's phase changes what is on screen.
        let morning = engine.phase(at: at(9), snapshot: Fixtures.snapshot(today: nil))
        let handled = engine.phase(at: at(9), snapshot: Fixtures.snapshot(today: Fixtures.today()))
        guard case .morning = morning else { return XCTFail("expected morning, got \(morning)") }
        XCTAssertFalse(DayEngine.sameStage(morning, handled), "morning finished elsewhere: \(handled)")
        XCTAssertTrue(DayEngine.sameStage(morning, morning))
        XCTAssertTrue(DayEngine.sameStage(.returning(quietDays: 3), .returning(quietDays: 4)))
        XCTAssertFalse(DayEngine.sameStage(.evening(.stepOpen), .evening(.doneEarlier)))
        XCTAssertFalse(DayEngine.sameStage(.evening(.stepOpen), .today))
        XCTAssertTrue(DayEngine.sameStage(.today, .today))
    }

    func testNoGoalIsOnboarding() {
        XCTAssertEqual(engine.phase(at: at(9), snapshot: .empty), .onboarding)
    }

    func testAchievedGoalStaysInTodayFrame() {
        var g = Fixtures.goal
        g.status = .achieved
        g.endedAt = at(8)
        // Achieved, no history yet: still not Welcome. Any time of day, no rituals.
        for h in [7, 13, 22] {
            let phase = engine.phase(at: at(h), snapshot: CompassSnapshot(goal: g))
            XCTAssertEqual(phase, .goalEnded, "\(h):00")
            XCTAssertEqual(ScreenID.entry(for: phase, today: nil), .c1)
        }
        // With the fixture's history (Today has a done step): Today's frame, never A1.
        var snap = Fixtures.snapshot(today: Fixtures.today(done: true))
        snap.goal = g
        XCTAssertEqual(engine.phase(at: at(9), snapshot: snap), .goalEnded)
        XCTAssertEqual(ScreenID.entry(for: engine.phase(at: at(9), snapshot: snap), today: snap.day(today)), .c4)
        XCTAssertNil(engine.morningPlan(at: at(9), snapshot: snap))
    }

    func testNoGoalWithHistoryIsNotOnboarding() {
        var snap = Fixtures.snapshot(today: nil)
        var ended = snap.goal!
        ended.status = .replaced
        snap.pastGoals = [ended]
        snap.goal = nil
        XCTAssertEqual(engine.phase(at: at(9), snapshot: snap), .goalEnded)
        // A day with only a note still counts as history.
        let notesOnly = CompassSnapshot(days: [Day(key: today, notes: [Note(text: "x", createdAt: at(8))])])
        XCTAssertEqual(engine.phase(at: at(9), snapshot: notesOnly), .goalEnded)
    }

    func testMorningBeforeNoonStartsWithCenterAndSuggestion() {
        let snap = Fixtures.snapshot(today: nil)
        guard case .morning(let plan) = engine.phase(at: at(7, 30), snapshot: snap) else { return XCTFail() }
        XCTAssertTrue(plan.startsWithCenter)
        XCTAssertFalse(plan.asksWhy)
        XCTAssertEqual(plan.quietDays, 0)
        guard case .suggestion(_, let size) = plan.planning else { return XCTFail("\(plan.planning)") }
        XCTAssertEqual(size, .regular)
    }

    func testMorningBeforeRhythmTimeStillMorning() {
        // Opening at 05:00, before the 07:00 notification, is still the morning ritual.
        let snap = Fixtures.snapshot(today: nil)
        guard case .morning(let plan) = engine.phase(at: at(5), snapshot: snap) else { return XCTFail() }
        XCTAssertTrue(plan.startsWithCenter)
    }

    func testAfternoonStartSkipsCenter() {
        let snap = Fixtures.snapshot(today: nil)
        guard case .morning(let plan) = engine.phase(at: at(14, 10), snapshot: snap) else { return XCTFail() }
        XCTAssertFalse(plan.startsWithCenter)
        XCTAssertEqual(ScreenID.entry(for: .morning(plan), today: nil), .b6)
    }

    func testNoonExactlyIsAfternoon() {
        guard case .morning(let plan) = engine.phase(at: at(12), snapshot: Fixtures.snapshot(today: nil)) else { return XCTFail() }
        XCTAssertFalse(plan.startsWithCenter)
    }

    func testHandledMorningIsToday() {
        let snap = Fixtures.snapshot(today: Fixtures.today())
        XCTAssertEqual(engine.phase(at: at(10), snapshot: snap), .today)
        XCTAssertEqual(engine.phase(at: at(15), snapshot: snap), .today)
    }

    func testSkippedMorningIsToday() {
        let snap = Fixtures.snapshot(today: Fixtures.today(intention: false, step: nil, notes: [], morningSkipped: true))
        XCTAssertEqual(engine.phase(at: at(9), snapshot: snap), .today)
        XCTAssertEqual(ScreenID.entry(for: .today, today: snap.day(today)), .c1)
    }

    func testEveningStepOpen() {
        let snap = Fixtures.snapshot(today: Fixtures.today())
        XCTAssertEqual(engine.phase(at: at(21), snapshot: snap), .evening(.stepOpen))
        XCTAssertEqual(engine.phase(at: at(20, 59), snapshot: snap), .today)
    }

    func testEveningDoneEarlier() {
        let snap = Fixtures.snapshot(today: Fixtures.today(done: true))
        XCTAssertEqual(engine.phase(at: at(21, 30), snapshot: snap), .evening(.doneEarlier))
    }

    func testEveningNoStep() {
        let snap = Fixtures.snapshot(today: Fixtures.today(step: nil))
        XCTAssertEqual(engine.phase(at: at(21, 30), snapshot: snap), .evening(.noStep))
        // Nothing at all today, opened after 21:00: still "What did you do today?"
        XCTAssertEqual(engine.phase(at: at(22), snapshot: Fixtures.snapshot(today: nil)), .evening(.noStep))
    }

    func testEveningAfterReflectionIsToday() {
        let snap = Fixtures.snapshot(today: Fixtures.today(done: true, reflection: Fixtures.savedReflection))
        XCTAssertEqual(engine.phase(at: at(22), snapshot: snap), .today)
    }

    func testEveningFollowsCustomRhythm() {
        var settings = Settings()
        settings.rhythm = Rhythm(morning: TimeOfDay(hour: 6), evening: TimeOfDay(hour: 20, minute: 30))
        let snap = Fixtures.snapshot(today: Fixtures.today(), settings: settings)
        XCTAssertEqual(engine.phase(at: at(20, 30), snapshot: snap), .evening(.stepOpen))
    }

    func testFirstWeekNamesOwnStep() {
        var g = Fixtures.goal
        g.createdAt = Fixtures.date(today.adding(days: -1, calendar: cal), 8)
        let snap = CompassSnapshot(goal: g, days: [Day(key: today.adding(days: -1, calendar: cal), goalID: g.id, morningSkipped: true)])
        guard case .morning(let plan) = engine.phase(at: at(7, 30), snapshot: snap) else { return XCTFail() }
        XCTAssertEqual(plan.planning, .nameYourOwn)
        XCTAssertFalse(plan.asksWhy)
    }

    func testFirstDayAfterOnboarding() {
        var g = Fixtures.goal
        g.createdAt = at(6)
        g.why = nil
        g.whyAsked = false
        let snap = CompassSnapshot(goal: g)
        guard case .morning(let plan) = engine.phase(at: at(7), snapshot: snap) else { return XCTFail() }
        XCTAssertEqual(plan.quietDays, 0)
        XCTAssertEqual(plan.planning, .nameYourOwn)
        // Same first day, afternoon: a step for what's left; after 21:00: the evening question.
        guard case .morning(let pm) = engine.phase(at: at(15), snapshot: snap) else { return XCTFail() }
        XCTAssertFalse(pm.startsWithCenter)
        XCTAssertEqual(engine.phase(at: at(21, 15), snapshot: snap), .evening(.noStep))
    }

    func testDayThreeAsksWhyOnce() {
        var g = Fixtures.goal
        g.createdAt = Fixtures.date(today.adding(days: -2, calendar: cal), 8)
        g.why = nil
        g.whyAsked = false
        let yesterday = Day(key: today.adding(days: -1, calendar: cal), goalID: g.id, intention: Fixtures.intention)
        var snap = CompassSnapshot(goal: g, days: [yesterday])
        guard case .morning(let plan) = engine.phase(at: at(7, 30), snapshot: snap) else { return XCTFail() }
        XCTAssertTrue(plan.asksWhy)
        XCTAssertEqual(ScreenID.entry(for: .morning(plan), today: nil), .b7)

        snap.goal?.whyAsked = true
        guard case .morning(let again) = engine.phase(at: at(7, 30), snapshot: snap) else { return XCTFail() }
        XCTAssertFalse(again.asksWhy)
    }

    func testDayThreeAfternoonDoesNotAskWhy() {
        var g = Fixtures.goal
        g.createdAt = Fixtures.date(today.adding(days: -2, calendar: cal), 8)
        g.why = nil
        g.whyAsked = false
        let snap = CompassSnapshot(goal: g, days: [Day(key: today.adding(days: -1, calendar: cal), goalID: g.id, intention: Fixtures.intention)])
        guard case .morning(let plan) = engine.phase(at: at(13), snapshot: snap) else { return XCTFail() }
        XCTAssertFalse(plan.asksWhy)
    }

    func testOneOrTwoQuietDaysGiveSmallerStep() {
        for quiet in [1, 2] {
            let history = Fixtures.historyDays().filter { $0.key < today.adding(days: -quiet, calendar: cal) }
            let snap = Fixtures.snapshot(today: nil, history: history)
            XCTAssertEqual(engine.quietDays(before: today, snapshot: snap), quiet)
            guard case .morning(let plan) = engine.phase(at: at(7, 30), snapshot: snap) else { return XCTFail() }
            guard case .suggestion(_, let size) = plan.planning else { return XCTFail() }
            XCTAssertEqual(size, .smaller, "quiet \(quiet)")
        }
    }

    /// Goal started long ago; the only activity is `quiet + 1` days before today.
    func lapsed(_ quiet: Int) -> CompassSnapshot {
        let last = today.adding(days: -(quiet + 1), calendar: cal)
        let day = Day(key: last, goalID: Fixtures.goalID, step: Step(title: "Pitch Ridgeline", createdAt: Fixtures.date(last, 7), completedAt: Fixtures.date(last, 16)))
        return Fixtures.snapshot(today: nil, history: [day])
    }

    func testThreeToTwentyNineQuietDaysIsReturning() {
        for quiet in [3, 8, 29] {
            let snap = lapsed(quiet)
            XCTAssertEqual(engine.phase(at: at(9), snapshot: snap), .returning(quietDays: quiet))
            // Also in the evening: the return screen comes first.
            XCTAssertEqual(engine.phase(at: at(21, 30), snapshot: snap), .returning(quietDays: quiet))
        }
    }

    func testThirtyPlusQuietDaysChecksGoal() {
        for quiet in [30, 34, 120] {
            let snap = lapsed(quiet)
            XCTAssertEqual(engine.phase(at: at(9), snapshot: snap), .checkGoal(quietDays: quiet))
            XCTAssertEqual(ScreenID.entry(for: .checkGoal(quietDays: quiet), today: nil), .f3)
        }
    }

    func testActivityTodayEndsLapse() {
        let history = Fixtures.historyDays().filter { $0.key < today.adding(days: -10, calendar: cal) }
        let snap = Fixtures.snapshot(today: Fixtures.today(), history: history)
        XCTAssertEqual(engine.phase(at: at(10), snapshot: snap), .today)
    }

    func testQuietestPartGetsSuggestion() {
        // Last 7 days in fixtures: wealth 2 (pricing, Ridgeline), strength 2, friends 1 → friends is quietest.
        let snap = Fixtures.snapshot(today: nil)
        XCTAssertEqual(engine.quietestPart(goal: Fixtures.goal, snapshot: snap, endingBefore: today)?.id, Fixtures.friendsPartID)
        XCTAssertEqual(engine.stepsThisWeek(partID: Fixtures.friendsPartID, snapshot: snap, today: today), 1)
    }

    func testFixturePhasesMatchBoards() {
        func phase(_ id: ScreenID) -> DayPhase {
            let f = Fixtures.fixture(for: id)
            return DayEngine(calendar: f.calendar).phase(at: f.now, snapshot: f.snapshot)
        }
        XCTAssertEqual(phase(.a1), .onboarding)
        if case .morning(let p) = phase(.b1) { XCTAssertTrue(p.startsWithCenter) } else { XCTFail() }
        if case .morning(let p) = phase(.b6) { XCTAssertFalse(p.startsWithCenter) } else { XCTFail() }
        if case .morning(let p) = phase(.b7) { XCTAssertTrue(p.asksWhy) } else { XCTFail() }
        XCTAssertEqual(phase(.c1), .today)
        XCTAssertEqual(phase(.c3), .today)
        XCTAssertEqual(phase(.d1), .evening(.stepOpen))
        XCTAssertEqual(phase(.d2), .evening(.noStep))
        XCTAssertEqual(phase(.d2b), .evening(.doneEarlier))
        XCTAssertEqual(phase(.d5), .today)
        if case .returning(let q) = phase(.f2) { XCTAssertEqual(q, 8) } else { XCTFail("\(phase(.f2))") }
        if case .checkGoal(let q) = phase(.f3) { XCTAssertEqual(q, 33) } else { XCTFail("\(phase(.f3))") }
    }

    func testEntryScreens() {
        let open = Fixtures.today()
        XCTAssertEqual(ScreenID.entry(for: .today, today: open), .c3)
        XCTAssertEqual(ScreenID.entry(for: .today, today: Fixtures.today(done: true)), .c4)
        XCTAssertEqual(ScreenID.entry(for: .today, today: Fixtures.today(step: nil)), .c2)
        XCTAssertEqual(ScreenID.entry(for: .evening(.stepOpen), today: open), .d1)
        XCTAssertEqual(ScreenID.entry(for: .evening(.noStep), today: open), .d2)
        XCTAssertEqual(ScreenID.entry(for: .evening(.doneEarlier), today: open), .d2b)
        XCTAssertEqual(ScreenID.entry(for: .returning(quietDays: 5), today: nil), .f2)
    }
}
