import XCTest
@testable import CompassCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Adaptive silence (noise-floor relative), cloud-help failure kinds and https-only endpoints.
final class AdaptiveSilenceTests: XCTestCase {
    /// Feeds `level` every 50 ms (the recorder reports ~20–47 levels a second) from `from` to `to`.
    private func feed(_ d: inout SilenceDetector, _ level: Float, from: TimeInterval, to: TimeInterval) {
        var t = from
        while t < to - 0.0001 {
            d.feed(level: level, at: t)
            t += 0.05
        }
    }

    func testQuietRoomSpeechCountsAsVoice() {
        var d = SilenceDetector()
        feed(&d, 0.02, from: 0, to: 2)
        XCTAssertEqual(d.voiceThreshold, 0.17, accuracy: 0.02)
        XCTAssertTrue(d.isVoice(0.35))   // soft speech, about -34 dBFS
        XCTAssertFalse(d.isVoice(0.05))  // the room
    }

    func testNoisyRoomStillStopsAfterAPause() {
        // Café hum at 0.3 (about -36 dBFS) is above the old fixed 0.12 bar, so a pause never ended the take.
        var d = SilenceDetector(silence: 2.5)
        feed(&d, 0.3, from: 0, to: 5)
        XCTAssertFalse(d.isVoice(0.3), "steady hum is learned as the room within a few seconds")
        XCTAssertGreaterThan(d.noiseFloor, 0.2)
        feed(&d, 0.7, from: 5, to: 6.5)        // speech over the hum
        d.heardWords(at: 6.5)
        feed(&d, 0.7, from: 6.5, to: 7)
        feed(&d, 0.3, from: 7, to: 10)         // back to the hum
        XCTAssertEqual(d.lastVoiceAt ?? 0, 6.95, accuracy: 0.06)
        XCTAssertFalse(d.shouldStop(at: 9.0, hasWords: true))
        XCTAssertTrue(d.shouldStop(at: 9.6, hasWords: true))
    }

    func testFixedThresholdWouldNeverStopInTheSameRoom() {
        // The same café with the floor pinned (no adaptation) shows what the old detector did.
        var d = SilenceDetector(risePerSecond: 0)
        d.heardWords(at: 0)
        feed(&d, 0.3, from: 0, to: 10)
        XCTAssertFalse(d.shouldStop(at: 10, hasWords: true))
    }

    func testFloorDropsQuicklyInGapsBetweenWords() {
        var d = SilenceDetector()
        feed(&d, 0.6, from: 0, to: 4)          // long loud stretch pushes the floor up
        let raised = d.noiseFloor
        feed(&d, 0.05, from: 4, to: 4.3)       // a short gap
        XCTAssertLessThan(d.noiseFloor, raised / 3)
        XCTAssertTrue(d.isVoice(0.5))
    }

    func testVoiceBarIsCapped() {
        var d = SilenceDetector()
        feed(&d, 0.95, from: 0, to: 60)        // something very loud for a minute
        XCTAssertEqual(d.voiceThreshold, d.ceiling)
    }
}

final class CloudAssistFailureTests: XCTestCase {
    func testFailureKinds() {
        XCTAssertEqual(CloudAssistFailure(CloudAssistError.disabled), .disabled)
        XCTAssertEqual(CloudAssistFailure(CloudAssistError.offline), .offline)
        XCTAssertEqual(CloudAssistFailure(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(CloudAssistFailure(HTTPCloudAssistError.badStatus(500)), .server)
        XCTAssertEqual(CloudAssistFailure(HTTPCloudAssistError.malformedResponse), .server)
        XCTAssertEqual(CloudAssistFailure(URLError(.badServerResponse)), .server)
        XCTAssertEqual(CloudAssistFailure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))), .server)
    }

    private var waiting: Reflection {
        Reflection(outcome: .moved, transcript: "Called Lena about the pilot.", partID: nil, createdAt: Fixtures.referenceDate)
    }

    func testServerErrorKeepsThePlainTranscriptNotOffline() {
        let r = ReflectionRules.applying(summaryError: HTTPCloudAssistError.badStatus(503), to: waiting)
        XCTAssertEqual(r.summaryState, .ready)
        XCTAssertNil(r.summary)
        XCTAssertEqual(ReflectionRules.title(for: r), "Called Lena about the pilot.")
        XCTAssertFalse(ReflectionRules.waitsForNetwork(r))
    }

    func testOfflineWaitsForTheNetwork() {
        let r = ReflectionRules.applying(summaryError: URLError(.networkConnectionLost), to: waiting)
        XCTAssertEqual(r.summaryState, .waitingForNetwork)
        XCTAssertTrue(ReflectionRules.waitsForNetwork(r))
    }

    func testOnlyHTTPSEndpointsAreConfigured() {
        XCTAssertNotNil(CloudAssistConfiguration(endpointString: "https://assist.example.com/v1").endpoint)
        XCTAssertTrue(CloudAssistConfiguration(endpointString: " https://assist.example.com ").isConfigured)
        for s in ["http://assist.example.com/v1", "HTTP://x.y", "ftp://x", "https://", "", "$(COMPASS_CLOUD_ASSIST_ENDPOINT)", "assist.example.com"] {
            XCTAssertNil(CloudAssistConfiguration(endpointString: s).endpoint, s)
        }
        XCTAssertFalse(CloudAssistConfiguration.none.isConfigured)
    }

    func testInsecureURLBuiltInCodeIsRefused() async {
        let c = HTTPCloudAssist(configuration: CloudAssistConfiguration(endpoint: URL(string: "http://assist.example.com")!),
                                switchOn: true) { _ in
            XCTFail("must not send over http")
            throw URLError(.badURL)
        }
        do {
            _ = try await c.summarize(transcript: "x", goal: nil)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? HTTPCloudAssistError, .insecureEndpoint)
        }
    }
}

/// Reminders that keep coming while the app stays closed (weekly repeating triggers).
final class RepeatingReminderTests: XCTestCase {
    private var cal: Calendar { Fixtures.calendar }

    func testAWeekAwayStillGetsEveryMorningAndEvening() {
        let snap = Fixtures.snapshot(today: Fixtures.today())
        let now = Fixtures.date(Fixtures.todayKey, 14)
        let plan = NotificationPlanner(calendar: cal).schedule(snapshot: snap, now: now)
        let mornings = plan.filter { $0.kind == .morning }
        let evenings = plan.filter { $0.kind == .evening }
        XCTAssertEqual(mornings.count, 7)
        XCTAssertTrue(mornings.allSatisfy(\.repeatsWeekly))
        XCTAssertEqual(Set(mornings.map(\.weekday)), Set(1...7))
        XCTAssertTrue(mornings.allSatisfy { $0.body == Fixtures.goalText })
        // Today's morning has passed: its weekly repeat first fires next Tuesday.
        let tuesday = mornings.first { $0.day == Fixtures.todayKey }
        XCTAssertEqual(tuesday?.date, Fixtures.date(Fixtures.todayKey.adding(days: 7, calendar: cal), 7))
        XCTAssertEqual(tuesday?.identifier, "compass.morning.weekly.3")

        // Tonight: a one-off with today's step; the other six evenings repeat weekly.
        XCTAssertEqual(evenings.count, 7)
        let tonight = evenings.first { $0.day == Fixtures.todayKey }
        XCTAssertEqual(tonight?.repeatsWeekly, false)
        XCTAssertEqual(tonight?.body, Fixtures.stepTitle)
        XCTAssertEqual(tonight?.identifier, "compass.evening.2026-11-10")
        XCTAssertEqual(evenings.filter(\.repeatsWeekly).count, 6)
        XCTAssertTrue(evenings.filter(\.repeatsWeekly).allSatisfy { $0.body == NotificationPlanner.noStepEveningBody })
        XCTAssertLessThanOrEqual(plan.count, 64)
        XCTAssertEqual(Set(plan.map(\.identifier)).count, plan.count)
        XCTAssertTrue(plan.allSatisfy { $0.date > now })
    }

    func testMorningHandledBeforeItsTimeSkipsOnlyToday() {
        let snap = Fixtures.snapshot(today: Fixtures.today())
        XCTAssertTrue(snap.day(Fixtures.todayKey)?.morningHandled ?? false)
        let plan = NotificationPlanner(calendar: cal).schedule(snapshot: snap, now: Fixtures.date(Fixtures.todayKey, 6, 30))
        let mornings = plan.filter { $0.kind == .morning }
        XCTAssertEqual(mornings.count, 6)
        XCTAssertFalse(mornings.contains { $0.day == Fixtures.todayKey })
    }

    func testReflectedTodayHasNoEveningTonightButRepeatsOtherDays() {
        let snap = Fixtures.snapshot(today: Fixtures.today(done: true, reflection: Fixtures.savedReflection))
        let plan = NotificationPlanner(calendar: cal).schedule(snapshot: snap, now: Fixtures.date(Fixtures.todayKey, 20))
        let evenings = plan.filter { $0.kind == .evening }
        XCTAssertEqual(evenings.count, 6)
        XCTAssertFalse(evenings.contains { $0.day == Fixtures.todayKey })
    }

    func testNoStepTonightUsesTheWeeklyQuestion() {
        let snap = Fixtures.snapshot(today: nil)
        let plan = NotificationPlanner(calendar: cal).schedule(snapshot: snap, now: Fixtures.date(Fixtures.todayKey, 14))
        let tonight = plan.first { $0.kind == .evening && $0.day == Fixtures.todayKey }
        XCTAssertEqual(tonight?.repeatsWeekly, true)
        XCTAssertEqual(tonight?.date, Fixtures.date(Fixtures.todayKey, 21))
    }

    func testOffOrNoGoalSchedulesNothing() {
        var snap = Fixtures.snapshot(today: nil)
        snap.settings.notificationsEnabled = false
        XCTAssertTrue(NotificationPlanner(calendar: cal).schedule(snapshot: snap, now: Fixtures.referenceDate).isEmpty)
        XCTAssertTrue(NotificationPlanner(calendar: cal).schedule(snapshot: .empty, now: Fixtures.referenceDate).isEmpty)
    }
}
