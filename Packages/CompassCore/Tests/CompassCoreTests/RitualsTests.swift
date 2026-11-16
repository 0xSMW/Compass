import XCTest
@testable import CompassCore

final class RitualsTests: XCTestCase {
    let cal = Fixtures.calendar

    // MARK: Live words

    func testRecognizingSplitsPendingWord() {
        let u = TranscriptUpdate.recognizing(" Patient.  Calm with the team. Ship one thing ", isFinal: false)
        XCTAssertEqual(u.settled, "Patient. Calm with the team. Ship one")
        XCTAssertEqual(u.pending, "thing")
        XCTAssertFalse(u.isFinal)
        XCTAssertEqual(u.text, "Patient. Calm with the team. Ship one thing")
    }

    func testRecognizingFinalSettlesEverything() {
        let u = TranscriptUpdate.recognizing("Sick. Slept most of the day", isFinal: true)
        XCTAssertEqual(u.settled, "Sick. Slept most of the day")
        XCTAssertEqual(u.pending, "")
        XCTAssertTrue(u.isFinal)
    }

    func testRecognizingSingleWordAndEmpty() {
        XCTAssertEqual(TranscriptUpdate.recognizing("Texted", isFinal: false), TranscriptUpdate(settled: "", pending: "Texted"))
        XCTAssertEqual(TranscriptUpdate.recognizing("   ", isFinal: false), TranscriptUpdate(settled: ""))
    }

    // MARK: Silence

    func testSilenceNeverStopsBeforeWords() {
        var d = SilenceDetector()
        d.feed(level: 0, at: 0)
        d.feed(level: 0, at: 10)
        XCTAssertFalse(d.shouldStop(at: 10, hasWords: false))
    }

    func testSilenceStopsAfterPauseFollowingSpeech() {
        var d = SilenceDetector(silence: 2.5)
        d.feed(level: 0.6, at: 0)
        d.feed(level: 0.7, at: 1)
        d.feed(level: 0.01, at: 2)
        XCTAssertFalse(d.shouldStop(at: 3, hasWords: true))
        XCTAssertTrue(d.shouldStop(at: 3.6, hasWords: true))
        d.heardWords(at: 3.5)
        XCTAssertFalse(d.shouldStop(at: 4, hasWords: true))
    }

    func testSilenceStopsAtMaxDuration() {
        var d = SilenceDetector(maxDuration: 60)
        d.feed(level: 0, at: 0)
        XCTAssertTrue(d.shouldStop(at: 60, hasWords: false))
    }

    // MARK: Morning

    func testIntentionAndStepTidying() {
        XCTAssertEqual(MorningRules.intention(from: "patient. ship one thing"), "Patient. ship one thing.")
        XCTAssertEqual(MorningRules.intention(from: "Patient!"), "Patient!")
        XCTAssertEqual(MorningRules.intention(from: "  "), "")
        XCTAssertEqual(MorningRules.stepTitle(from: " call Lena about the pilot. "), "Call Lena about the pilot")
        XCTAssertEqual(MorningRules.quoted(Fixtures.intentionText), "“Patient. Ship one thing.”")
    }

    func testPlanMetaMatchesBoards() {
        XCTAssertEqual(MorningRules.planMeta(partTitle: "Keep close friends", hint: nil, stepsThisWeek: 1), "Keep close friends · 1 step this week")
        XCTAssertEqual(MorningRules.planMeta(partTitle: "Earn my first million", hint: "about 2 minutes", stepsThisWeek: 3), "Earn my first million · about 2 minutes")
        XCTAssertEqual(MorningRules.planMeta(partTitle: "Stay strong", hint: nil, stepsThisWeek: 0), "Stay strong · no steps this week")
        XCTAssertEqual(MorningRules.planMeta(partTitle: nil, hint: nil, stepsThisWeek: 2), "2 steps this week")
    }

    func testMorningPlanSurvivesSavingTheIntention() {
        let f = Fixtures.fixture(for: .b3)
        let engine = DayEngine(calendar: f.calendar)
        // B3 already has the intention, so the phase is Today; the ritual still knows how to plan.
        XCTAssertEqual(engine.phase(at: f.now, snapshot: f.snapshot), .today)
        let plan = engine.morningPlan(at: f.now, snapshot: f.snapshot)
        XCTAssertEqual(plan?.planning, .suggestion(partID: Fixtures.friendsPartID, size: .regular))
        XCTAssertEqual(engine.stepsThisWeek(partID: Fixtures.friendsPartID, snapshot: f.snapshot, today: f.todayKey), 1)
    }

    func testMorningPlanFirstWeekAndWhy() {
        let b4 = Fixtures.fixture(for: .b4)
        XCTAssertEqual(DayEngine(calendar: b4.calendar).morningPlan(at: b4.now, snapshot: b4.snapshot)?.planning, .nameYourOwn)
        XCTAssertEqual(DayEngine(calendar: b4.calendar).defaultPartID(at: b4.now, snapshot: b4.snapshot), Fixtures.wealthPartID)
        let b7 = Fixtures.fixture(for: .b7)
        XCTAssertEqual(DayEngine(calendar: b7.calendar).morningPlan(at: b7.now, snapshot: b7.snapshot)?.asksWhy, true)
        let b6 = Fixtures.fixture(for: .b6)
        XCTAssertEqual(DayEngine(calendar: b6.calendar).morningPlan(at: b6.now, snapshot: b6.snapshot)?.startsWithCenter, false)
    }

    func testStepIdeasForBoards() {
        XCTAssertEqual(Fixtures.stepIdea(for: .b3)?.title, "Text Sam about Friday dinner")
        XCTAssertEqual(Fixtures.stepIdea(for: .b6)?.hint, "about 2 minutes")
        XCTAssertNil(Fixtures.stepIdea(for: .b1))
    }

    // MARK: Evening

    func testQuestions() {
        XCTAssertEqual(ReflectionRules.question(outcome: .moved, kind: .stepOpen), "What happened?")
        XCTAssertEqual(ReflectionRules.question(outcome: .notToday, kind: .stepOpen), "What got in the way?")
        XCTAssertEqual(ReflectionRules.question(outcome: .notToday, kind: .noStep), "What got in the way?")
        XCTAssertEqual(ReflectionRules.question(outcome: .moved, kind: .doneEarlier), "Anything to add?")
        XCTAssertEqual(ReflectionRules.question(outcome: .moved, kind: .noStep), "What did you do?")
    }

    private var recording: Recording { Recording(duration: 14, fileName: "a.m4a", createdAt: Fixtures.referenceDate) }

    func testDraftKeepsAudioAndWords() {
        let r = ReflectionRules.draft(outcome: .moved, transcript: Fixtures.reflectionTranscript, recording: recording,
                                      transcriptionFailed: false, partID: Fixtures.friendsPartID, now: Fixtures.referenceDate)
        XCTAssertEqual(r.summaryState, .ready)
        XCTAssertEqual(r.duration, 14)
        XCTAssertEqual(r.audioFileName, "a.m4a")
        XCTAssertNil(r.summary)
        XCTAssertTrue(ReflectionRules.needsSummary(r))
        XCTAssertFalse(ReflectionRules.needsTranscription(r))
        XCTAssertEqual(ReflectionRules.title(for: r), Fixtures.reflectionTranscript)
        XCTAssertFalse(ReflectionRules.showsTranscript(r))
    }

    func testDraftWithFailedTextIsD6b() {
        let r = ReflectionRules.draft(outcome: .moved, transcript: "", recording: recording, transcriptionFailed: true,
                                      partID: nil, now: Fixtures.referenceDate)
        XCTAssertEqual(r.summaryState, .transcriptionFailed)
        XCTAssertEqual(ReflectionRules.title(for: r), "Saved as audio.")
        XCTAssertTrue(ReflectionRules.needsTranscription(r))
        XCTAssertFalse(ReflectionRules.needsSummary(r))
        // Try again succeeds.
        let retried = ReflectionRules.applying(transcript: "Texted Sam.", to: r)
        XCTAssertEqual(retried.summaryState, .ready)
        XCTAssertTrue(ReflectionRules.needsSummary(retried))
        // Or fails again.
        XCTAssertEqual(ReflectionRules.applying(transcript: nil, to: r).summaryState, .transcriptionFailed)
        // Or a typed summary.
        let typed = ReflectionRules.applying(typedSummary: "Dinner is on.", to: r)
        XCTAssertEqual(typed.summary, "Dinner is on.")
        XCTAssertEqual(typed.summaryState, .ready)
        XCTAssertEqual(typed.audioFileName, "a.m4a")
    }

    func testTypedReflectionWithoutAudioNeverFails() {
        let r = ReflectionRules.draft(outcome: .notToday, transcript: "", recording: nil, transcriptionFailed: true,
                                      partID: nil, now: Fixtures.referenceDate)
        XCTAssertEqual(r.summaryState, .ready)
        XCTAssertEqual(ReflectionRules.title(for: r), "Not today.")
    }

    func testSummaryResults() {
        let r = ReflectionRules.draft(outcome: .moved, transcript: Fixtures.reflectionTranscript, recording: recording,
                                      transcriptionFailed: false, partID: Fixtures.friendsPartID, now: Fixtures.referenceDate)
        let ok = ReflectionRules.applying(summary: .success(Fixtures.reflectionSummary), to: r)
        XCTAssertEqual(ReflectionRules.title(for: ok), "Texted Sam. Friday dinner is on.")
        XCTAssertTrue(ReflectionRules.showsTranscript(ok))
        XCTAssertFalse(ReflectionRules.needsSummary(ok))

        let offline = ReflectionRules.applying(summary: .failure(.offline), to: r)
        XCTAssertEqual(offline.summaryState, .waitingForNetwork)
        XCTAssertEqual(ReflectionRules.title(for: offline), "Saved as audio.")
        XCTAssertTrue(ReflectionRules.needsSummary(offline), "retried on reconnect")
        XCTAssertEqual(offline.transcript, Fixtures.reflectionTranscript, "words are kept while waiting")

        let off = ReflectionRules.applying(summary: .failure(.disabled), to: offline)
        XCTAssertEqual(off.summaryState, .ready)
        XCTAssertNil(off.summary)
        XCTAssertEqual(ReflectionRules.title(for: off), Fixtures.reflectionTranscript, "plain transcript when cloud help is off")
    }

    func testFixtureStatesMatchRules() {
        XCTAssertEqual(ReflectionRules.title(for: Fixtures.fixture(for: .d5).today!.reflection!), "Texted Sam. Friday dinner is on.")
        XCTAssertEqual(ReflectionRules.title(for: Fixtures.fixture(for: .d6).today!.reflection!), "Saved as audio.")
        XCTAssertEqual(Fixtures.fixture(for: .d6b).today!.reflection!.summaryState, .transcriptionFailed)
        XCTAssertEqual(Fixtures.fixture(for: .d3L).transcript?.pending, "coming")
    }

    func testReflectionDecodesWithoutAudioFileName() throws {
        let r = Fixtures.savedReflection
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        json.removeValue(forKey: "audioFileName")
        let decoded = try JSONDecoder().decode(Reflection.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.audioFileName)
        XCTAssertEqual(decoded.summary, r.summary)
    }
}
