import XCTest
@testable import CompassCore

/// Rules behind the live app's flows: day rollover mid-ritual, the boundary timer, rhythm limits,
/// the I2 notice, voice notes and E4 edits.
final class FlowRulesTests: XCTestCase {
    let cal = Fixtures.calendar
    var engine: DayEngine { DayEngine(calendar: cal) }
    let today = Fixtures.todayKey
    var tomorrow: DayKey { today.adding(days: 1, calendar: cal) }

    func at(_ h: Int, _ m: Int = 0, _ key: DayKey? = nil) -> Date { Fixtures.date(key ?? today, h, m) }

    // MARK: Clock: entry follows the day

    func testDayRolloverMidEveningMovesTheClock() {
        // D1 opened at 23:50, phone left on the screen, reopened at 07:30 the next day.
        let snap = Fixtures.snapshot(today: Fixtures.today())
        XCTAssertEqual(engine.phase(at: at(23, 50), snapshot: snap), .evening(.stepOpen))
        XCTAssertTrue(engine.clockMoved(from: at(23, 50), to: at(7, 30, tomorrow), snapshot: snap))
        // The next day opens on its own morning, not the old evening.
        guard case .morning(let plan) = engine.phase(at: at(7, 30, tomorrow), snapshot: snap) else { return XCTFail() }
        XCTAssertTrue(plan.startsWithCenter)
        // Even a minute past midnight is a new day.
        XCTAssertTrue(engine.clockMoved(from: at(23, 59), to: at(0, 1, tomorrow), snapshot: snap))
    }

    func testEveningAnswerSavedToItsDayClosesThatEvening() {
        // The answer given at 00:10 belongs to the evening that was open (today), so today has its
        // evening and tomorrow's morning is untouched.
        var snap = Fixtures.snapshot(today: Fixtures.today())
        snap.updateDay(today) { $0.reflection = Fixtures.savedReflection }
        XCTAssertEqual(engine.phase(at: at(23, 55), snapshot: snap), .today)
        XCTAssertNil(snap.day(tomorrow))
        guard case .morning = engine.phase(at: at(7, 30, tomorrow), snapshot: snap) else { return XCTFail() }
    }

    func testMorningLeftOpenPastNoonAndEvening() {
        let snap = Fixtures.snapshot(today: nil)
        XCTAssertEqual(engine.phase(at: at(11, 59), snapshot: snap).kind, .center)
        XCTAssertEqual(engine.phase(at: at(12), snapshot: snap).kind, .afternoon)
        XCTAssertTrue(engine.clockMoved(from: at(11, 59), to: at(12), snapshot: snap))
        // B1 left until 22:00 becomes the evening.
        XCTAssertTrue(engine.clockMoved(from: at(8), to: at(22), snapshot: snap))
        XCTAssertEqual(engine.phase(at: at(22), snapshot: snap), .evening(.noStep))
    }

    func testSavingAnIntentionIsNotTheClockMoving() {
        // After the intention (handled morning) the phase is Today; noon must not pull B3/B4 away.
        let snap = Fixtures.snapshot(today: Fixtures.today(step: nil, notes: []))
        XCTAssertFalse(engine.clockMoved(from: at(11, 58), to: at(12, 2), snapshot: snap))
        XCTAssertFalse(engine.clockMoved(from: at(9), to: at(9, 30), snapshot: snap))
        // ...but the evening time does.
        XCTAssertTrue(engine.clockMoved(from: at(20, 59), to: at(21), snapshot: snap))
    }

    func testNextBoundary() {
        let rhythm = Rhythm(morning: TimeOfDay(hour: 7), evening: TimeOfDay(hour: 21, minute: 30))
        XCTAssertEqual(engine.nextBoundary(after: at(7, 30), rhythm: rhythm), at(12))
        XCTAssertEqual(engine.nextBoundary(after: at(12), rhythm: rhythm), at(21, 30))
        XCTAssertEqual(engine.nextBoundary(after: at(21, 30), rhythm: rhythm), at(0, 0, tomorrow))
        XCTAssertEqual(engine.nextBoundary(after: at(0, 0), rhythm: rhythm), at(12))
        // A stored evening before noon is clamped, so the boundary is 17:00, not 06:00.
        let broken = Rhythm(morning: TimeOfDay(hour: 7), evening: TimeOfDay(hour: 6))
        XCTAssertEqual(engine.nextBoundary(after: at(13), rhythm: broken), at(17))
    }

    // MARK: Rhythm limits

    func testEveningEarlierThanMorningIsClamped() {
        // An evening of 06:00 (Settings' wheel before the clamp) no longer makes 08:00 the evening.
        var settings = Fixtures.settings
        settings.rhythm = Rhythm(morning: TimeOfDay(hour: 7), evening: TimeOfDay(hour: 6))
        let snap = Fixtures.snapshot(today: nil, settings: settings)
        guard case .morning(let plan) = engine.phase(at: at(8), snapshot: snap) else {
            return XCTFail("\(engine.phase(at: at(8), snapshot: snap))")
        }
        XCTAssertTrue(plan.startsWithCenter)
        XCTAssertEqual(engine.phase(at: at(17), snapshot: snap), .evening(.noStep))
        // Reminders use the same limits.
        let planned = NotificationPlanner(calendar: cal, daysAhead: 1).plan(snapshot: snap, now: at(5))
        XCTAssertEqual(planned.map(\.time.description), ["07:00", "17:00"])
    }

    func testSettingsClampsMatchA6() {
        let r = Rhythm.standard
        XCTAssertEqual(r.settingMorning(TimeOfDay(hour: 3)).morning.description, "04:00")
        XCTAssertEqual(r.settingMorning(TimeOfDay(hour: 12, minute: 30)).morning.description, "11:45")
        XCTAssertEqual(r.settingMorning(TimeOfDay(hour: 6, minute: 10)).morning.description, "06:10")
        XCTAssertEqual(r.settingEvening(TimeOfDay(hour: 6)).evening.description, "17:00")
        XCTAssertEqual(r.settingEvening(TimeOfDay(hour: 23, minute: 59)).evening.description, "23:45")
        XCTAssertEqual(r.settingEvening(TimeOfDay(hour: 22, minute: 15)).evening.description, "22:15")
        // Settings and A6 share one set of limits.
        XCTAssertEqual(r.settingMorning(TimeOfDay(hour: 0)).morning, r.movingMorning(by: -100).morning)
        XCTAssertEqual(r.settingEvening(TimeOfDay(hour: 23, minute: 59)).evening, r.movingEvening(by: 100).evening)
        XCTAssertEqual(Rhythm(morning: TimeOfDay(hour: 2), evening: TimeOfDay(hour: 1)).clamped,
                       Rhythm(morning: TimeOfDay(hour: 4), evening: TimeOfDay(hour: 17)))
    }

    // MARK: I2

    func testNotificationsNoticeAfterNotNow() {
        // "Not now" on A6: switched off while iOS has never asked.
        XCTAssertTrue(NotificationRules.showsOffNotice(enabled: false, status: .notDetermined, dismissed: false))
        XCTAssertTrue(NotificationRules.showsOffNotice(enabled: false, status: .granted, dismissed: false))
        XCTAssertTrue(NotificationRules.showsOffNotice(enabled: true, status: .denied, dismissed: false))
        XCTAssertTrue(NotificationRules.showsOffNotice(enabled: true, status: .notDetermined, dismissed: false))
        XCTAssertFalse(NotificationRules.showsOffNotice(enabled: true, status: .granted, dismissed: false))
        XCTAssertFalse(NotificationRules.showsOffNotice(enabled: false, status: .denied, dismissed: true))
    }

    // MARK: Notes

    func testVoiceNoteKeepsRecordingIdAndAudio() {
        let rec = Recording(duration: 12, fileName: "x.m4a", createdAt: at(12, 40))
        let note = NoteRules.note(transcript: " Sam is  free Friday ", recording: rec, now: at(12, 41), device: "This iPhone")
        XCTAssertEqual(note?.id, rec.id)
        XCTAssertEqual(note?.text, "Sam is free Friday")
        XCTAssertEqual(note?.duration, 12)
        XCTAssertFalse(NoteRules.needsWords(note!))
    }

    func testVoiceNoteWithoutWordsKeepsAudioAndOffersTyping() {
        let rec = Recording(duration: 7, fileName: "x.m4a", createdAt: at(12, 40))
        let note = NoteRules.note(transcript: "", recording: rec, now: at(12, 41), device: nil)
        XCTAssertEqual(note?.id, rec.id)
        XCTAssertEqual(note?.text, "")
        XCTAssertTrue(NoteRules.needsWords(note!))
        XCTAssertNil(NoteRules.note(transcript: "  ", recording: nil, now: at(12), device: nil))
        XCTAssertEqual(NoteRules.note(transcript: "typed", recording: nil, now: at(12), device: nil)?.duration, nil)
    }

    func testEditAndDeleteNotes() {
        let spoken = Note(text: "", duration: 7, createdAt: at(9))
        let typed = Note(text: "Buy wine", createdAt: at(10))
        var day = Day(key: today, notes: [spoken, typed])
        XCTAssertTrue(day.editNote(spoken.id, text: "  Call  Sam "))
        XCTAssertEqual(day.notes[0].text, "Call Sam")
        // A voice note emptied keeps its audio; a typed note emptied goes.
        day.editNote(spoken.id, text: "")
        XCTAssertEqual(day.notes.count, 2)
        day.editNote(typed.id, text: " ")
        XCTAssertEqual(day.notes.map(\.id), [spoken.id])
        XCTAssertEqual(day.removeNote(spoken.id)?.id, spoken.id)
        XCTAssertTrue(day.notes.isEmpty)
        XCTAssertFalse(day.editNote(UUID(), text: "x"))
    }

    // MARK: E4

    func testE4UnchangedSaveKeepsTranscriptAsIs() {
        var day = Fixtures.today(done: true, reflection: Reflection(outcome: .moved, transcript: Fixtures.reflectionTranscript,
                                                                    partID: Fixtures.friendsPartID, createdAt: at(21, 20)))
        HistoryEdit.apply(to: &day, summary: Fixtures.reflectionTranscript, moved: true, partID: Fixtures.friendsPartID,
                          now: at(22), calendar: cal, device: nil)
        XCTAssertNil(day.reflection?.summary)
        XCTAssertFalse(ReflectionRules.showsTranscript(day.reflection!))
        // A real edit becomes the summary.
        HistoryEdit.apply(to: &day, summary: "Dinner is on.", moved: true, partID: Fixtures.friendsPartID,
                          now: at(22), calendar: cal, device: nil)
        XCTAssertEqual(day.reflection?.summary, "Dinner is on.")
    }

    func testE4NoneClearsTheStepPart() {
        var day = Fixtures.today(done: true)
        HistoryEdit.apply(to: &day, summary: Fixtures.stepTitle, moved: true, partID: nil, now: at(22), calendar: cal, device: nil)
        XCTAssertNil(day.step?.partID)
        // Unchanged text with a step and no evening entry adds nothing.
        XCTAssertNil(day.reflection)
        XCTAssertTrue(day.moved)
    }

    func testE4NotThatDayReopensStep() {
        var day = Fixtures.today(done: true)
        HistoryEdit.apply(to: &day, summary: "Sick", moved: false, partID: Fixtures.friendsPartID, now: at(22), calendar: cal, device: nil)
        XCTAssertFalse(day.moved)
        XCTAssertEqual(day.reflection?.outcome, .notToday)
        XCTAssertEqual(day.reflection?.summary, "Sick")
        XCTAssertFalse(ReflectionRules.showsTranscript(day.reflection!))
    }
}
