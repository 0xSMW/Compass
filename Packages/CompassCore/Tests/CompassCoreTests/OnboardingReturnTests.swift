import XCTest
@testable import CompassCore

final class GoalShaperTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(GoalShaper.normalize("  earn my first million,  stay strong, keep close friends "),
                       "Earn my first million, stay strong, keep close friends.")
        XCTAssertEqual(GoalShaper.normalize("Run a marathon!"), "Run a marathon!")
        XCTAssertEqual(GoalShaper.normalize("be happier,"), "Be happier.")
        XCTAssertEqual(GoalShaper.normalize("   "), "")
    }

    func testClarifyingQuestion() {
        XCTAssertEqual(GoalShaper.clarifyingQuestion(for: Fixtures.vagueGoalText), "What would happier look like a year from now?")
        XCTAssertEqual(GoalShaper.clarifyingQuestion(for: "Get better"), "What would better look like a year from now?")
        XCTAssertEqual(GoalShaper.clarifyingQuestion(for: "Improve"), "What would that look like a year from now?")
        XCTAssertNil(GoalShaper.clarifyingQuestion(for: Fixtures.goalText))
        XCTAssertNil(GoalShaper.clarifyingQuestion(for: Fixtures.shortGoalText))
        XCTAssertNil(GoalShaper.clarifyingQuestion(for: ""))
    }

    func testProposePartsMatchesBoard() {
        let parts = GoalShaper.proposeParts(for: Fixtures.goalText)
        XCTAssertEqual(parts.map(\.title), Fixtures.parts.map(\.title))
        XCTAssertEqual(parts.map(\.symbol), [.wealth, .strength, .friends])
        XCTAssertEqual(GoalShaper.partsTitle(count: parts.count), "Your goal has three parts.")
        XCTAssertEqual(GoalShaper.partsTitle(count: 1), "Your goal has one part.")
    }

    func testProposePartsSplitsAndAndCaps() {
        let two = GoalShaper.proposeParts(for: "run a marathon and call my parents every week")
        XCTAssertEqual(two.map(\.title), ["Run a marathon", "Call my parents every week"])
        XCTAssertEqual(two.map(\.symbol), [.strength, .friends])
        XCTAssertEqual(GoalShaper.proposeParts(for: "Run a marathon.").count, 1)
        XCTAssertEqual(GoalShaper.proposeParts(for: "a, b c, d e, f g, h i, j k").count, 4)
        XCTAssertEqual(GoalShaper.singlePart(for: Fixtures.goalText).map(\.title), ["Earn my first million, stay strong, keep close friends"])
        XCTAssertTrue(GoalShaper.proposeParts(for: "").isEmpty)
    }

    func testRhythmSteps() {
        let r = Rhythm.standard
        XCTAssertEqual(r.movingMorning(by: 1).morning.description, "07:15")
        XCTAssertEqual(r.movingEvening(by: -2).evening.description, "20:30")
        var late = r
        late.evening = TimeOfDay(hour: 23, minute: 45)
        XCTAssertEqual(late.movingEvening(by: 1).evening.description, "23:45")
        var early = r
        early.morning = TimeOfDay(hour: 4)
        XCTAssertEqual(early.movingMorning(by: -1).morning.description, "04:00")
        XCTAssertEqual(TimeOfDay(hour: 23, minute: 50).adding(minutes: 15).description, "00:05")
    }
}

final class ReturnSummaryTests: XCTestCase {
    let cal = Fixtures.calendar

    func summary(_ id: ScreenID) -> ReturnSummary {
        let f = Fixtures.fixture(for: id)
        return ReturnSummary(snapshot: f.snapshot, today: f.todayKey, calendar: cal)
    }

    func testF2MatchesBoard() {
        let s = summary(.f2)
        XCTAssertEqual(s.steps, 41)
        XCTAssertEqual(s.stepsCaption, "steps toward this goal")
        XCTAssertEqual(s.lastLine, "Last: Pitched Ridgeline, 9 days ago")
        XCTAssertEqual(s.why?.text, Fixtures.whyText)
    }

    func testF3MatchesBoard() {
        XCTAssertEqual(summary(.f3).checkLine, "41 steps. The last one was 34 days ago.")
    }

    func testF1SmallerStepGoesToTheQuietWorkPart() {
        let f = Fixtures.fixture(for: .f1)
        let engine = DayEngine(calendar: cal)
        XCTAssertEqual(engine.quietDays(before: f.todayKey, snapshot: f.snapshot), 2)
        XCTAssertEqual(engine.quietestPart(goal: f.snapshot.goal!, snapshot: f.snapshot, endingBefore: f.todayKey)?.id, Fixtures.wealthPartID)
    }

    func testDaysAgoWording() {
        XCTAssertEqual(ReturnSummary.daysAgo(1), "yesterday")
        XCTAssertEqual(ReturnSummary.daysAgo(0), "today")
        XCTAssertEqual(ReturnSummary.daysAgo(5), "5 days ago")
    }
}
