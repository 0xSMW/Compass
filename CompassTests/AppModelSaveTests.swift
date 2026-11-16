import XCTest
import CompassCore
@testable import Compass

/// Counts what `AppModel`'s single save path does after each change.
@MainActor
final class EffectsSpy {
    var widgetReloads = 0
    var syncNotifications = 0
    var storeCatchUps = 0

    var effects: SnapshotEffects {
        SnapshotEffects(
            reloadWidgets: { [self] in widgetReloads += 1 },
            didChangeLocally: { [self] in syncNotifications += 1 },
            storeCaughtUp: { [self] in storeCatchUps += 1 }
        )
    }
}

/// Helpers for live-path tests: a model on a real store with a fixed clock and spied effects.
@MainActor
enum TestModel {
    static func make(snapshot: CompassSnapshot = Fixtures.snapshot(today: Fixtures.today()),
                     store: Store? = nil,
                     now: Date = Fixtures.date(Fixtures.todayKey, 14),
                     spy: EffectsSpy) -> (AppModel, Store) {
        let store = store ?? InMemoryStore(snapshot)
        let model = AppModel(snapshot: snapshot, store: store, calendar: Fixtures.calendar, now: { now }, effects: spy.effects)
        return (model, store)
    }
}

@MainActor
final class AppModelSaveTests: XCTestCase {
    func testTodayChangeSavesNotifiesSyncAndReloadsWidget() throws {
        let spy = EffectsSpy()
        let (model, store) = TestModel.make(spy: spy)
        model.setStepDone(true)
        XCTAssertEqual(try store.load(), model.snapshot)
        XCTAssertNotNil(try store.load().day(Fixtures.todayKey)?.step?.completedAt)
        XCTAssertEqual(spy.widgetReloads, 1)
        XCTAssertEqual(spy.syncNotifications, 1)
    }

    func testUnchangedMutationDoesNothing() {
        let spy = EffectsSpy()
        let (model, store) = TestModel.make(spy: spy)
        let saves = (store as? InMemoryStore)?.saveCount
        model.mutate { _ in }
        XCTAssertEqual((store as? InMemoryStore)?.saveCount, saves)
        XCTAssertEqual(spy.widgetReloads, 0)
        XCTAssertEqual(spy.syncNotifications, 0)
    }

    func testRemoteMergeSavesAndReloadsWidgetWithoutCountingAsLocal() throws {
        let spy = EffectsSpy()
        let (model, store) = TestModel.make(spy: spy)
        var merged = model.snapshot
        merged.updateDay(Fixtures.todayKey) { $0.step = nil }
        model.commit(merged, origin: .remote)
        XCTAssertNil(try store.load().day(Fixtures.todayKey)?.step)
        XCTAssertEqual(spy.widgetReloads, 1)
        XCTAssertEqual(spy.syncNotifications, 0)
    }

    func testHistoryEditGoesThroughTheSavePath() throws {
        let spy = EffectsSpy()
        let (model, store) = TestModel.make(spy: spy)
        let yesterday = Fixtures.todayKey.adding(days: -1, calendar: Fixtures.calendar)
        model.saveHistoryEdit(yesterday, summary: "Called Lena.", moved: true, partID: nil)
        XCTAssertEqual(try store.load().day(yesterday)?.reflection?.summary, "Called Lena.")
        XCTAssertEqual(spy.widgetReloads, 1)
        XCTAssertEqual(spy.syncNotifications, 1)

        model.deleteHistoryDay(yesterday)
        XCTAssertNil(try store.load().day(yesterday))
        XCTAssertEqual(spy.widgetReloads, 2)
        XCTAssertGreaterThanOrEqual(spy.syncNotifications, 2)
    }

    func testGoalEditsGoThroughTheSavePath() throws {
        let spy = EffectsSpy()
        let (model, store) = TestModel.make(spy: spy)
        model.updateGoalText("Run a calm studio.")
        XCTAssertEqual(try store.load().goal?.text, "Run a calm studio.")
        model.addGoalPart(title: "Health")
        XCTAssertEqual(try store.load().goal?.parts.last?.title, "Health")
        model.markGoalAchieved()
        XCTAssertEqual(try store.load().goal?.status, .achieved)
        XCTAssertEqual(spy.widgetReloads, 3)
        XCTAssertEqual(spy.syncNotifications, 3)
    }

    func testSettingsChangeSavesAndUpdatesCalendar() throws {
        let spy = EffectsSpy()
        let (model, store) = TestModel.make(spy: spy)
        model.updateSettings { $0.timeZoneID = "Asia/Tokyo" }
        XCTAssertEqual(try store.load().settings.timeZoneID, "Asia/Tokyo")
        XCTAssertEqual(model.calendar.timeZone.identifier, "Asia/Tokyo")
        XCTAssertEqual(spy.widgetReloads, 1)
        XCTAssertEqual(spy.syncNotifications, 1)
    }

    func testRestoreSavesAsLocalChange() throws {
        let spy = EffectsSpy()
        let (model, store) = TestModel.make(snapshot: .empty, spy: spy)
        let restored = Fixtures.restorableSnapshot
        model.applyRestoredSnapshot(restored)
        XCTAssertEqual(try store.load(), restored)
        XCTAssertEqual(spy.widgetReloads, 1)
        XCTAssertEqual(spy.syncNotifications, 1)
    }

    func testDeleteEverythingClearsStoreAndReloadsWidget() throws {
        let spy = EffectsSpy()
        let (model, store) = TestModel.make(spy: spy)
        model.deleteEverything()
        XCTAssertEqual(model.snapshot, .empty)
        XCTAssertEqual(try store.load(), .empty)
        XCTAssertEqual(spy.widgetReloads, 1)
        // The wipe reaches sync through LiveSync.wipeEverywhere, never as an ordinary local change.
        XCTAssertEqual(spy.syncNotifications, 0)
    }

    /// N4: A1's question never offers a backup that Delete everything just removed, and "Start a new
    /// goal" answers it.
    func testRestoreQuestionIsForgottenAfterDeleteEverythingAndStartingANewGoal() {
        let (model, _) = TestModel.make(spy: EffectsSpy())
        let routing = model.restoreRouting
        func found() {
            routing.backupFound = true
            routing.foundSummary = BackupSummary(goalText: "Old goal.", steps: 212, memos: 186, goals: 1)
            routing.choosing = true
        }
        found()
        model.deleteEverything()
        XCTAssertFalse(routing.backupFound)
        XCTAssertNil(routing.foundSummary)
        XCTAssertFalse(routing.choosing)

        found()
        routing.chooseNewGoal(model)
        XCTAssertFalse(routing.backupFound)
        XCTAssertNil(routing.foundSummary)
        XCTAssertFalse(routing.choosing)
        XCTAssertFalse(routing.restoreChosen)
        XCTAssertEqual(model.current, .a2)
    }

    // MARK: S3 · failed saves, the widget's writes

    /// A save that fails (full disk) is remembered and shown; becoming active retries it instead of
    /// reading the stale file back as a local edit (which would record the new note as deleted).
    func testFailedSaveIsSurfacedAndTheStaleFileIsNeverAdopted() throws {
        let spy = EffectsSpy()
        let start = Fixtures.snapshot(today: Fixtures.today(notes: []))
        let store = InMemoryStore(start)
        let (model, _) = TestModel.make(snapshot: start, store: store, spy: spy)
        store.failsSaving = true
        model.addNote("typed while the disk was full")
        XCTAssertTrue(model.saveFailed)
        XCTAssertEqual(try store.load(), start, "nothing reached the disk")

        model.reloadFromStore()
        XCTAssertEqual(model.today?.notes.count, 1, "the stale file did not replace memory")
        XCTAssertNil(model.today?.removedItems)
        XCTAssertTrue(model.saveFailed)

        store.failsSaving = false
        model.reloadFromStore()
        XCTAssertFalse(model.saveFailed)
        XCTAssertEqual(try store.load().day(Fixtures.todayKey)?.notes.count, 1)
    }

    /// A retry that goes through tells sync, which records a wipe it held back while the store didn't
    /// hold the snapshot (review 9, P2). A retry that fails again tells nobody.
    func testARetriedSaveThatGoesThroughTellsSync() {
        let spy = EffectsSpy()
        let start = Fixtures.snapshot(today: Fixtures.today(notes: []))
        let store = InMemoryStore(start)
        let (model, _) = TestModel.make(snapshot: start, store: store, spy: spy)
        store.failsSaving = true
        model.addNote("typed while the disk was full")
        model.reloadFromStore()
        XCTAssertEqual(spy.storeCatchUps, 0)
        let reloads = spy.widgetReloads

        store.failsSaving = false
        model.reloadFromStore()
        XCTAssertFalse(model.saveFailed)
        XCTAssertEqual(spy.storeCatchUps, 1)
        XCTAssertEqual(spy.widgetReloads, reloads + 1)

        // Nothing failed: becoming active again is not a catch-up.
        model.reloadFromStore()
        XCTAssertEqual(spy.storeCatchUps, 1)
    }

    /// The widget completes the step in its own process; the app takes that in when it becomes active,
    /// and its own next save doesn't overwrite it.
    func testWidgetCompletionIsTakenInAndNeverOverwritten() throws {
        let spy = EffectsSpy()
        let start = Fixtures.snapshot(today: Fixtures.today(notes: []))
        let store = InMemoryStore(start)
        let (model, _) = TestModel.make(snapshot: start, store: store, spy: spy)
        model.addNote("first")
        var widget = try store.load()
        widget.updateDay(Fixtures.todayKey) {
            $0.step?.completedAt = Fixtures.date(Fixtures.todayKey, 15)
            $0.step?.updatedAt = Fixtures.date(Fixtures.todayKey, 15)
            $0.step?.completionChangedAt = Fixtures.date(Fixtures.todayKey, 15)
        }
        store.writeExternally(widget, at: Date().addingTimeInterval(60))
        // The app saves before it has looked: the widget's completion survives.
        model.addNote("second")
        let saved = try store.load().day(Fixtures.todayKey)
        XCTAssertEqual(saved?.notes.count, 2)
        XCTAssertTrue(saved?.step?.isDone ?? false)
        XCTAssertTrue(model.today?.step?.isDone ?? false)

        // And on becoming active.
        var undone = try store.load()
        undone.updateDay(Fixtures.todayKey) {
            $0.step?.completedAt = nil
            $0.step?.completionChangedAt = Fixtures.date(Fixtures.todayKey, 16)
        }
        store.writeExternally(undone, at: Date().addingTimeInterval(120))
        model.reloadFromStore()
        XCTAssertFalse(model.today?.step?.isDone ?? true)
        XCTAssertEqual(model.today?.notes.count, 2)
    }
}

@MainActor
final class StoreRoundTripTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CompassTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMissingFileLoadsEmpty() throws {
        let store = JSONFileStore(url: directory.appendingPathComponent("Compass/compass.json"))
        XCTAssertEqual(try store.load(), .empty)
    }

    func testModelChangesSurviveARelaunch() throws {
        let url = directory.appendingPathComponent("Compass/compass.json")
        let spy = EffectsSpy()
        let (model, _) = TestModel.make(store: JSONFileStore(url: url), spy: spy)
        model.addNote("Ask Sam about Friday")
        model.setStepDone(true)

        // A new process reads the same file (the widget does exactly this).
        let reloaded = try JSONFileStore(url: url).load()
        XCTAssertEqual(reloaded, model.snapshot)
        XCTAssertEqual(reloaded.day(Fixtures.todayKey)?.notes.last?.text, "Ask Sam about Friday")
        XCTAssertNotNil(reloaded.day(Fixtures.todayKey)?.step?.completedAt)
    }

    /// The clock has fractions of a second; the file doesn't. The model holds what the file holds, so sync
    /// compares its dates with other devices' on equal terms and an evening entry keeps its identity (E5).
    func testTheModelHoldsWhatTheFileHoldsWhenTheClockHasFractionsOfASecond() throws {
        let url = directory.appendingPathComponent("Compass/compass.json")
        let spy = EffectsSpy()
        let now = Fixtures.date(Fixtures.todayKey, 21).addingTimeInterval(0.7)
        let (model, store) = TestModel.make(store: JSONFileStore(url: url), now: now, spy: spy)
        model.addNote("Ask Sam about Friday")
        XCTAssertEqual(model.snapshot, try store.load())
        model.eveningSession.outcome = .moved
        model.saveEveningTake(transcript: "Called Lena", recording: nil, transcriptionFailed: false)
        XCTAssertEqual(model.snapshot, try store.load())
        for date in [model.today?.reflection?.createdAt, model.today?.notes.last?.createdAt] {
            XCTAssertEqual(try XCTUnwrap(date).timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1), 0)
        }
    }

    func testDeleteEverythingRemovesTheFile() throws {
        let url = directory.appendingPathComponent("Compass/compass.json")
        let spy = EffectsSpy()
        let (model, _) = TestModel.make(store: JSONFileStore(url: url), spy: spy)
        model.addNote("Something")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        model.deleteEverything()
        XCTAssertEqual(try JSONFileStore(url: url).load(), .empty)
    }

    func testSharedStorageCalendarFollowsSettings() {
        var settings = Settings()
        settings.timeZoneID = "Europe/London"
        XCTAssertEqual(SharedStorage.calendar(for: settings).timeZone.identifier, "Europe/London")
    }
}
