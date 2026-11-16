import XCTest
import CompassCore
@testable import Compass

/// A clock the test moves by hand.
// @unchecked Sendable: read and moved only on the main actor by the (MainActor) tests.
final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

/// The live path through `AppModel`: onboarding → morning → Today → evening → the next day, the clock
/// moving the entry screen, a lapse, an achieved goal and a goal change, notes and reminders.
/// Each test's `AppModel` owns its own sessions (voice, morning, evening, onboarding), so nothing
/// carries over between cases.
@MainActor
final class LiveFlowTests: XCTestCase {
    let cal = Fixtures.calendar

    private func day(_ offset: Int) -> DayKey { Fixtures.todayKey.adding(days: offset, calendar: cal) }
    private func at(_ key: DayKey, _ h: Int, _ m: Int = 0) -> Date { Fixtures.date(key, h, m) }

    /// A live-path model (no fixture) on an in-memory store, its clock, and the store.
    private func make(_ snapshot: CompassSnapshot, at date: Date,
                      conditions: SystemConditions = .normal) -> (AppModel, TestClock, InMemoryStore) {
        let clock = TestClock(date)
        let store = InMemoryStore(snapshot)
        let model = AppModel(snapshot: snapshot, store: store, calendar: cal, now: { clock.now },
                             effects: .none, conditions: conditions)
        model.refreshEntryForClock() // the first look sets the baseline
        return (model, clock, store)
    }

    private var londonSettings: Settings {
        var s = Settings()
        s.timeZoneID = Fixtures.timeZone.identifier
        return s
    }

    // MARK: A day, end to end

    func testOnboardingMorningTodayEveningNextDay() {
        let (model, clock, store) = make(CompassSnapshot(settings: londonSettings), at: at(day(0), 8))
        XCTAssertEqual(model.current, .a1)

        // A2–A7: the goal typed, defaults kept, Start.
        let draft = model.onboardingDraft
        draft.text = "Run a calm studio."
        draft.proposePartsIfNeeded()
        model.go(.a2)
        model.onboardingFinish(draft)
        model.flushSaves()
        XCTAssertEqual(try store.load().goal?.text, "Run a calm studio.")
        XCTAssertEqual(model.settings.input, .typing)
        XCTAssertEqual(model.current, .b1, "day 1 before noon opens Center")

        // Morning: intention, then the first week names its own step (B4 → B5).
        model.setIntention("Patient.")
        model.addTypedStep("call lena about the pilot.", partID: model.morningDefaultPartID)
        XCTAssertEqual(model.today?.step?.title, "Call lena about the pilot")
        XCTAssertEqual(model.current, .c3)

        // Noon passes: the morning was handled, so Today stays.
        clock.now = at(day(0), 12, 5)
        XCTAssertEqual(model.refreshEntryForClock(), .unchanged)
        XCTAssertEqual(model.current, .c3)

        // 21:00: the evening, from Today.
        clock.now = at(day(0), 21, 1)
        XCTAssertEqual(model.refreshEntryForClock(), .moved)
        XCTAssertEqual(model.current, .d1)

        // Answered after midnight: it still belongs to day 0.
        model.beginEvening()
        clock.now = at(day(1), 0, 10)
        model.eveningSession.outcome = .moved
        model.saveEveningTake(transcript: "Called Lena", recording: nil, transcriptionFailed: false)
        model.flushSaves()
        XCTAssertEqual(try store.load().day(day(0))?.reflection?.transcript, "Called Lena")
        XCTAssertNil(try store.load().day(day(1))?.reflection)
        model.closeEvening()
        XCTAssertFalse(model.snapshot.day(day(1))?.morningSkipped ?? false, "closing the evening leaves the new morning open")

        // The next morning opens on Center for day 2.
        clock.now = at(day(1), 7, 30)
        XCTAssertEqual(model.refreshEntryForClock(), .moved)
        XCTAssertEqual(model.current, .b1)
    }

    // MARK: Clock (M11)

    func testEveningLeftOpenOvernightOpensTheNewMorning() {
        let (model, clock, _) = make(Fixtures.snapshot(today: Fixtures.today()), at: at(day(0), 23, 50))
        XCTAssertEqual(model.current, .d1)
        clock.now = at(day(1), 7, 30)
        XCTAssertEqual(model.refreshEntryForClock(), .moved)
        XCTAssertEqual(model.current, .b1)
        // Today was left without an evening; tomorrow's data is untouched.
        XCTAssertNil(model.snapshot.day(day(0))?.reflection)
        XCTAssertNil(model.snapshot.day(day(1)))
    }

    func testCenterLeftOpenBecomesTheAfternoonThenTheEvening() {
        let (model, clock, _) = make(Fixtures.snapshot(today: nil), at: at(day(0), 11, 50))
        XCTAssertEqual(model.current, .b1)
        clock.now = at(day(0), 12, 1)
        model.refreshEntryForClock()
        XCTAssertEqual(model.current, .b6)
        clock.now = at(day(0), 22)
        model.refreshEntryForClock()
        XCTAssertEqual(model.current, .d2)
    }

    func testClockWaitsWhileTypingThenMoves() {
        let (model, clock, _) = make(Fixtures.snapshot(today: Fixtures.today()), at: at(day(0), 20, 50))
        XCTAssertEqual(model.current, .c3)
        model.isComposing = true
        clock.now = at(day(0), 21, 1)
        XCTAssertEqual(model.refreshEntryForClock(), .deferred)
        XCTAssertEqual(model.current, .c3)
        model.isComposing = false
        XCTAssertEqual(model.refreshEntryForClock(), .moved)
        XCTAssertEqual(model.current, .d1)
    }

    func testClockKeepsPushedHistoryOnTop() {
        let (model, clock, _) = make(Fixtures.snapshot(today: Fixtures.today()), at: at(day(0), 20, 50))
        model.go(.e1)
        clock.now = at(day(0), 21, 1)
        XCTAssertEqual(model.refreshEntryForClock(), .moved)
        XCTAssertEqual(model.current, .e1)
        model.back()
        XCTAssertEqual(model.current, .d1)
    }

    func testClockLeavesSettingsAndOnboardingAlone() {
        let (model, clock, _) = make(CompassSnapshot(settings: londonSettings), at: at(day(0), 11, 50))
        model.go(.a2)
        clock.now = at(day(1), 9)
        XCTAssertEqual(model.refreshEntryForClock(), .unchanged)
        XCTAssertEqual(model.current, .a2)
    }

    func testBoundaryTimerTargets() {
        let (model, clock, _) = make(Fixtures.snapshot(today: Fixtures.today()), at: at(day(0), 9))
        XCTAssertEqual(model.nextEntryBoundary, at(day(0), 12))
        clock.now = at(day(0), 13)
        XCTAssertEqual(model.nextEntryBoundary, at(day(0), 21))
        clock.now = at(day(0), 21, 30)
        XCTAssertEqual(model.nextEntryBoundary, at(day(1), 0))
    }

    // MARK: Lapse

    func testLapseReturnsOncePerDay() {
        let f = Fixtures.fixture(for: .f2)
        let (model, _, store) = make(f.snapshot, at: f.now)
        XCTAssertEqual(model.current, .f2)
        model.returnLeaveForToday()
        XCTAssertEqual(model.current.flow, .today)
        model.flushSaves()
        // Reopened the same day: F2 isn't shown again.
        let reopened = AppModel(snapshot: try! store.load(), store: store, calendar: cal, now: { f.now }, effects: .none)
        XCTAssertEqual(reopened.current.flow, .today)
    }

    // MARK: Goal changes (B2, M12)

    func testAchievedGoalStaysInTheTodayFrame() {
        let (model, _, store) = make(Fixtures.snapshot(today: Fixtures.today()), at: at(day(0), 14))
        model.markGoalAchieved()
        model.goToEntry()
        XCTAssertEqual(model.current, .c3)
        model.flushSaves()
        // Relaunch: not Welcome, and History and Settings are a tap away.
        let nextMorning = at(day(1), 9)
        let relaunched = AppModel(snapshot: try! store.load(), store: store, calendar: cal,
                                  now: { nextMorning }, effects: .none)
        XCTAssertEqual(relaunched.phase, .goalEnded)
        XCTAssertEqual(relaunched.current.flow, .today)
        relaunched.go(.e1)
        XCTAssertEqual(relaunched.current, .e1)
    }

    func testReplacingAGoalKeepsRhythmRemindersAndCloudHelp() {
        var snap = Fixtures.snapshot(today: Fixtures.today())
        snap.settings.rhythm = Rhythm(morning: TimeOfDay(hour: 6, minute: 30), evening: TimeOfDay(hour: 22, minute: 15))
        snap.settings.cloudAssist = false
        snap.settings.notificationsEnabled = false
        snap.settings.input = .voice
        let before = snap.settings
        let oldGoal = snap.goal!
        let (model, _, store) = make(snap, at: at(day(0), 14))

        model.go(.g1)
        model.startNewGoal()
        XCTAssertEqual(model.current, .a2)
        let draft = model.onboardingDraft
        XCTAssertTrue(draft.replacing)
        XCTAssertEqual(draft.rhythm, before.rhythm)
        XCTAssertFalse(draft.cloudAssist)

        draft.text = "Write a book."
        draft.proposePartsIfNeeded()
        model.onboardingContinueFromParts(draft) // A5: saved here, A6/A7 skipped
        model.flushSaves()
        XCTAssertEqual(try store.load().goal?.text, "Write a book.")
        XCTAssertEqual(try store.load().settings, before)
        XCTAssertEqual(try store.load().pastGoals.first?.id, oldGoal.id)
        XCTAssertEqual(try store.load().pastGoals.first?.status, .replaced)
        XCTAssertNotEqual(model.current.flow, .onboarding)
    }

    // MARK: Start with: Typing (M7)

    func testTypingPreferenceOpensTheEveningAnswerTyped() {
        var snap = Fixtures.snapshot(today: Fixtures.today())
        snap.settings.input = .typing
        let (model, _, _) = make(snap, at: at(day(0), 21, 10))
        XCTAssertTrue(model.prefersTyping)
        model.beginEvening()
        model.answerEvening(.moved, kind: .stepOpen)
        XCTAssertTrue(model.eveningSession.typing)
        XCTAssertEqual(model.current, .d3)
        XCTAssertFalse(model.voice.isBusy)
        XCTAssertTrue(model.today?.step?.isDone ?? false)
    }

    // MARK: Notes (B1, item 17)

    func testVoiceNoteKeepsItsAudioAndCanBeEditedAndDeleted() throws {
        let (model, _, store) = make(Fixtures.snapshot(today: Fixtures.today(notes: [])), at: at(day(0), 14))
        let id = UUID()
        let file = VoiceStorage.shared.fileName(for: id)
        try Data([0, 1, 2]).write(to: VoiceStorage.shared.url(for: file))
        let recording = Recording(id: id, duration: 4, fileName: file, createdAt: model.now)

        // Speech off: no words. The note keeps the recording's id and its file; typing is offered.
        let note = try XCTUnwrap(model.saveVoiceNote(transcript: "", recording: recording))
        XCTAssertEqual(note.id, id)
        XCTAssertEqual(MemoAudio.fileName(for: note), file)
        XCTAssertTrue(VoiceStorage.shared.exists(file))
        XCTAssertTrue(NoteRules.needsWords(note))

        model.editNote(id, on: model.todayKey, text: "Ask Sam about Friday")
        model.flushSaves()
        XCTAssertEqual(try store.load().day(model.todayKey)?.notes.first?.text, "Ask Sam about Friday")

        model.deleteNote(id, on: model.todayKey)
        model.flushSaves()
        XCTAssertEqual(try store.load().day(model.todayKey)?.notes.count, 0)
        XCTAssertFalse(VoiceStorage.shared.exists(file))
    }

    // MARK: Reminders (M6)

    func testNotNowLeavesAWayBackToReminders() {
        var snap = Fixtures.snapshot(today: Fixtures.today())
        snap.settings.notificationsEnabled = false
        var conditions = SystemConditions.normal
        conditions.notifications = .notDetermined
        let (model, _, _) = make(snap, at: at(day(0), 14), conditions: conditions)
        model.system.setNoticeDismissed(false)
        XCTAssertTrue(model.showsNotificationsNotice)
        model.turnOnNotifications()
        XCTAssertTrue(model.settings.notificationsEnabled)
        XCTAssertFalse(model.showsNotificationsNotice)
    }

    func testDismissedNoticeLeavesTheSettingsRowAndComesBackWhenATimeChanges() {
        // F1: "Not now" on A6, then I2 dismissed.
        var snap = Fixtures.snapshot(today: Fixtures.today())
        snap.settings.notificationsEnabled = false
        var conditions = SystemConditions.normal
        conditions.notifications = .notDetermined
        let (model, _, _) = make(snap, at: at(day(0), 14), conditions: conditions)
        model.system.setNoticeDismissed(false)
        model.dismissNotificationsNotice()
        XCTAssertFalse(model.showsNotificationsNotice)
        XCTAssertTrue(model.showsRemindersRow, "H1 keeps a way to turn reminders on")

        // Saving the same times leaves it dismissed; a new time brings it back.
        model.setRhythmFromSettings(model.settings.rhythm)
        XCTAssertFalse(model.showsNotificationsNotice)
        model.setRhythmFromSettings(model.settings.rhythm.settingEvening(TimeOfDay(hour: 22)))
        XCTAssertEqual(model.settings.rhythm.evening.description, "22:00")
        XCTAssertTrue(model.showsNotificationsNotice)

        // The row's action turns them on; then the row goes away (the board's H1).
        model.turnOnNotifications()
        XCTAssertFalse(model.showsRemindersRow)
        model.system.setNoticeDismissed(false)
    }

    // MARK: Merges and reminders judge the screen (F2, F3)

    func testMergeThatFinishesTheMorningLeavesCenter() {
        let (model, _, _) = make(Fixtures.snapshot(today: nil), at: at(day(0), 9))
        XCTAssertEqual(model.current, .b1)
        let before = model.phase
        // The iPad set today's intention and step.
        var remote = model.snapshot
        remote.updateDay(model.todayKey) { $0 = Fixtures.today() }
        model.commit(remote, origin: .remote)
        XCTAssertEqual(model.refreshEntryAfterMerge(phaseBefore: before), .moved)
        XCTAssertEqual(model.current, .c3)
        // A merge that changes nothing on screen leaves it alone.
        XCTAssertEqual(model.refreshEntryAfterMerge(phaseBefore: model.phase), .unchanged)
    }

    func testMergeWaitsForAnAnswerInProgress() {
        let (model, _, _) = make(Fixtures.snapshot(today: Fixtures.today()), at: at(day(0), 21, 5))
        XCTAssertEqual(model.current, .d1)
        model.beginEvening()
        model.eveningSession.typing = true
        let before = model.phase
        var remote = model.snapshot
        remote.updateDay(model.todayKey) { $0.reflection = Fixtures.savedReflection }
        model.commit(remote, origin: .remote)
        XCTAssertEqual(model.refreshEntryAfterMerge(phaseBefore: before), .deferred)
        XCTAssertEqual(model.current, .d1, "never pulled away mid-sentence")
        XCTAssertEqual(model.refreshEntryForClock(), .deferred)
        model.eveningSession.typing = false
        XCTAssertEqual(model.refreshEntryForClock(), .moved, "the move happens once the answer ends")
        XCTAssertEqual(model.current.flow, .today)
    }

    func testReminderTapWaitsWhileANoteIsTyped() {
        let (model, _, _) = make(Fixtures.snapshot(today: Fixtures.today()), at: at(day(0), 14))
        model.go(.e1)
        model.isComposing = true
        XCTAssertEqual(model.openFromReminder(), .deferred)
        XCTAssertEqual(model.current, .e1)
        model.isComposing = false
        XCTAssertEqual(model.refreshEntryForClock(), .moved)
        XCTAssertEqual(model.path, [.c3], "the reminder opens the screen for the moment")
        // Not mid-answer: at once.
        model.go(.h1)
        XCTAssertEqual(model.openFromReminder(), .moved)
        XCTAssertEqual(model.path, [.c3])
    }

    // MARK: Settings clamp (item 18)

    func testSettingsTimesStayInsideA6Limits() {
        var settings = londonSettings
        settings.rhythm = .standard
        let (model, _, _) = make(Fixtures.snapshot(today: nil, settings: settings), at: at(day(0), 9))
        model.updateSettings { $0.rhythm = $0.rhythm.settingEvening(TimeOfDay(hour: 6)) }
        XCTAssertEqual(model.settings.rhythm.evening.description, "17:00")
        model.updateSettings { $0.rhythm = $0.rhythm.settingMorning(TimeOfDay(hour: 13)) }
        XCTAssertEqual(model.settings.rhythm.morning.description, "11:45")
    }
}
