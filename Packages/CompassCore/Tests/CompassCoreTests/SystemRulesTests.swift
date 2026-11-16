import XCTest
@testable import CompassCore

final class TimeZoneRulesTests: XCTestCase {
    func testCityNames() {
        XCTAssertEqual(TimeZoneRules.city(for: "Asia/Tokyo"), "Tokyo")
        XCTAssertEqual(TimeZoneRules.city(for: "America/New_York"), "New York")
        XCTAssertEqual(TimeZoneRules.city(for: "UTC"), "UTC")
    }

    func testFirstLaunchRemembersZoneWithoutNotice() {
        let o = TimeZoneRules.observe(deviceZoneID: "Asia/Bangkok", lastSeenID: nil, pinnedID: nil)
        XCTAssertNil(o.change)
        XCTAssertEqual(o.lastSeenID, "Asia/Bangkok")
        XCTAssertNil(o.pinnedID)
    }

    func testSameZoneSaysNothing() {
        let o = TimeZoneRules.observe(deviceZoneID: "Asia/Bangkok", lastSeenID: "Asia/Bangkok", pinnedID: nil)
        XCTAssertNil(o.change)
    }

    func testMoveShowsNoticeUntilAnswered() {
        let o = TimeZoneRules.observe(deviceZoneID: "Asia/Tokyo", lastSeenID: "Asia/Bangkok", pinnedID: nil)
        XCTAssertEqual(o.change, TimeZoneChange(previousID: "Asia/Bangkok", currentID: "Asia/Tokyo"))
        XCTAssertEqual(o.change?.currentCity, "Tokyo")
        XCTAssertEqual(o.change?.previousCity, "Bangkok")
        // Not answered yet: the old zone stays remembered, so a relaunch shows it again.
        XCTAssertEqual(o.lastSeenID, "Asia/Bangkok")
        let again = TimeZoneRules.observe(deviceZoneID: "Asia/Tokyo", lastSeenID: o.lastSeenID, pinnedID: o.pinnedID)
        XCTAssertNotNil(again.change)
    }

    func testOKFollowsTheDevice() {
        let change = TimeZoneChange(previousID: "Asia/Bangkok", currentID: "Asia/Tokyo")
        let o = TimeZoneRules.acknowledge(change)
        XCTAssertEqual(o.lastSeenID, "Asia/Tokyo")
        XCTAssertNil(o.pinnedID)
        XCTAssertNil(TimeZoneRules.observe(deviceZoneID: "Asia/Tokyo", lastSeenID: o.lastSeenID, pinnedID: o.pinnedID).change)
    }

    func testKeepPreviousPinsAndReleasesWhenBack() {
        let change = TimeZoneChange(previousID: "Asia/Bangkok", currentID: "Asia/Tokyo")
        let kept = TimeZoneRules.keepPrevious(change)
        XCTAssertEqual(kept.pinnedID, "Asia/Bangkok")
        XCTAssertEqual(kept.lastSeenID, "Asia/Tokyo")
        // Still in Tokyo: pinned, quiet.
        let stay = TimeZoneRules.observe(deviceZoneID: "Asia/Tokyo", lastSeenID: kept.lastSeenID, pinnedID: kept.pinnedID)
        XCTAssertNil(stay.change)
        XCTAssertEqual(stay.pinnedID, "Asia/Bangkok")
        // Back home: follow the device again.
        let home = TimeZoneRules.observe(deviceZoneID: "Asia/Bangkok", lastSeenID: stay.lastSeenID, pinnedID: stay.pinnedID)
        XCTAssertNil(home.change)
        XCTAssertNil(home.pinnedID)
        XCTAssertEqual(home.lastSeenID, "Asia/Bangkok")
    }

    func testKeepingBangkokMovesTheRhythmAndToday() {
        // 10 Nov 23:30 in Tokyo is still 10 Nov 21:30 in Bangkok: evening there, not tomorrow.
        var tokyo = Fixtures.calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var bangkok = Fixtures.calendar
        bangkok.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let now = DayKey(year: 2026, month: 11, day: 11).date(in: tokyo, hour: 0, minute: 30)
        XCTAssertEqual(DayKey(now, calendar: tokyo), DayKey(year: 2026, month: 11, day: 11))
        XCTAssertEqual(DayKey(now, calendar: bangkok), DayKey(year: 2026, month: 11, day: 10))
        let snap = Fixtures.snapshot(today: Fixtures.today())
        XCTAssertEqual(DayEngine(calendar: bangkok).phase(at: now, snapshot: snap), .evening(.stepOpen))
    }
}

final class NotificationPlannerTests: XCTestCase {
    private var cal: Calendar { Fixtures.calendar }

    func testMorningShowsGoalEveningShowsStep() {
        let snap = Fixtures.snapshot(today: nil)
        let now = Fixtures.date(Fixtures.todayKey, 6)
        let plan = NotificationPlanner(calendar: cal, daysAhead: 1).plan(snapshot: snap, now: now)
        XCTAssertEqual(plan.map(\.kind), [.morning, .evening])
        XCTAssertEqual(plan[0].body, Fixtures.goalText)
        XCTAssertEqual(plan[0].date, Fixtures.date(Fixtures.todayKey, 7))
        XCTAssertEqual(plan[0].identifier, "compass.morning.2026-11-10")
        XCTAssertEqual(plan[1].body, NotificationPlanner.noStepEveningBody)
        XCTAssertEqual(plan[1].date, Fixtures.date(Fixtures.todayKey, 21))
    }

    func testEveningUsesTodaysStepAndSkipsPastAndHandled() {
        let snap = Fixtures.snapshot(today: Fixtures.today())
        let now = Fixtures.date(Fixtures.todayKey, 14)
        let plan = NotificationPlanner(calendar: cal, daysAhead: 2).plan(snapshot: snap, now: now)
        // Today: morning has passed (and is handled); evening shows the step. Tomorrow: both.
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(plan[0].kind, .evening)
        XCTAssertEqual(plan[0].body, Fixtures.stepTitle)
        XCTAssertEqual(plan[1].kind, .morning)
        XCTAssertEqual(plan[1].day, DayKey(year: 2026, month: 11, day: 11))
    }

    func testReflectedDayHasNoEvening() {
        let snap = Fixtures.snapshot(today: Fixtures.today(done: true, reflection: Fixtures.savedReflection))
        let plan = NotificationPlanner(calendar: cal, daysAhead: 1).plan(snapshot: snap, now: Fixtures.date(Fixtures.todayKey, 20))
        XCTAssertTrue(plan.isEmpty)
    }

    func testOffOrNoGoalPlansNothing() {
        var snap = Fixtures.snapshot(today: nil)
        snap.settings.notificationsEnabled = false
        XCTAssertTrue(NotificationPlanner(calendar: cal).plan(snapshot: snap, now: Fixtures.referenceDate).isEmpty)
        XCTAssertTrue(NotificationPlanner(calendar: cal).plan(snapshot: .empty, now: Fixtures.referenceDate).isEmpty)
    }

    func testCustomRhythm() {
        var snap = Fixtures.snapshot(today: nil)
        snap.settings.rhythm = Rhythm(morning: TimeOfDay(hour: 6, minute: 30), evening: TimeOfDay(hour: 22, minute: 15))
        let plan = NotificationPlanner(calendar: cal, daysAhead: 1).plan(snapshot: snap, now: Fixtures.date(Fixtures.todayKey, 5))
        XCTAssertEqual(plan.map(\.date), [Fixtures.date(Fixtures.todayKey, 6, 30), Fixtures.date(Fixtures.todayKey, 22, 15)])
    }

    func testI5FixtureContent() {
        let f = Fixtures.fixture(for: .i5)
        XCTAssertEqual(NotificationPlanner.body(for: .morning, goal: f.snapshot.goal, day: f.today), Fixtures.goalText)
        let yesterday = f.todayKey.adding(days: -1, calendar: f.calendar)
        XCTAssertEqual(NotificationPlanner.body(for: .evening, goal: f.snapshot.goal, day: f.snapshot.day(yesterday)), "Pitch Ridgeline")
    }
}

final class StorageAndTodayFixtureTests: XCTestCase {
    func testStorageThreshold() {
        XCTAssertTrue(StorageRules.isFull(availableBytes: 10 * 1024 * 1024))
        XCTAssertFalse(StorageRules.isFull(availableBytes: 2 * 1024 * 1024 * 1024))
        XCTAssertFalse(StorageRules.isFull(availableBytes: nil))
    }

    func testTodayFixturesMatchBoards() {
        let c8 = Fixtures.fixture(for: .c8)
        XCTAssertEqual(c8.today?.step?.title, "Send Lena the pilot price")
        XCTAssertEqual(c8.today?.notes.count, 3)
        XCTAssertEqual(c8.today?.notes.last?.text, "Lena: price the pilot per seat")
        XCTAssertEqual(Fixtures.fixture(for: .c9).today?.notes.last?.text, "Needed before Thursday’s board meeting")
        XCTAssertEqual(Fixtures.fixture(for: .c5).transcript?.pending, "seven")
        XCTAssertEqual(ScreenID.entry(for: DayEngine(calendar: c8.calendar).phase(at: c8.now, snapshot: c8.snapshot), today: c8.today), .c3)
    }
}
