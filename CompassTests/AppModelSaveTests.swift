import XCTest
import CompassCore
@testable import Compass

/// Counts what `AppModel`'s single save path does after each change.
@MainActor
final class EffectsSpy {
    var widgetReloads = 0
    var syncNotifications = 0

    var effects: SnapshotEffects {
        SnapshotEffects(
            reloadWidgets: { [self] in widgetReloads += 1 },
            didChangeLocally: { [self] in syncNotifications += 1 }
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
