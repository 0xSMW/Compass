import Foundation
import XCTest
@testable import CompassCore

final class StoreTests: XCTestCase {
    var tempURL: URL!

    override func setUp() {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compass-tests-\(UUID().uuidString)")
            .appendingPathComponent("compass.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    func roundTrip(_ store: Store) throws {
        XCTAssertEqual(try store.load(), .empty)
        let snap = Fixtures.snapshot(today: Fixtures.today())
        try store.save(snap)
        XCTAssertEqual(try store.load(), snap)
    }

    func testInMemoryRoundTrip() throws {
        try roundTrip(InMemoryStore())
    }

    func testJSONFileRoundTrip() throws {
        try roundTrip(JSONFileStore(url: tempURL))
        // A second store instance on the same file reads the same data (widget + app share a file).
        let other = JSONFileStore(url: tempURL)
        XCTAssertEqual(try other.load().goal?.text, Fixtures.goalText)
    }

    func testJSONFileMissingIsEmpty() throws {
        XCTAssertEqual(try JSONFileStore(url: tempURL).load(), .empty)
    }

    func testJSONFileCorruptThrows() throws {
        try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: tempURL)
        XCTAssertThrowsError(try JSONFileStore(url: tempURL).load()) { error in
            guard case StoreError.corrupt = error else { return XCTFail("\(error)") }
        }
    }

    func testJSONDeleteAll() throws {
        let store = JSONFileStore(url: tempURL)
        try store.save(Fixtures.snapshot(today: nil))
        try store.deleteAll()
        XCTAssertEqual(try store.load(), .empty)
    }

    func testCompleteAndUndoStep() throws {
        for store in [InMemoryStore(Fixtures.snapshot(today: Fixtures.today())) as Store, JSONFileStore(url: tempURL)] {
            if store is JSONFileStore { try store.save(Fixtures.snapshot(today: Fixtures.today())) }
            let at = Fixtures.date(Fixtures.todayKey, 15)
            try store.setStepDone(true, on: Fixtures.todayKey, at: at)
            XCTAssertEqual(try store.load().day(Fixtures.todayKey)?.step?.completedAt, at)
            XCTAssertTrue(try store.load().day(Fixtures.todayKey)!.moved)
            try store.setStepDone(false, on: Fixtures.todayKey, at: at)
            XCTAssertNil(try store.load().day(Fixtures.todayKey)?.step?.completedAt)
        }
    }

    func testUpdateCreatesDay() throws {
        let store = InMemoryStore(CompassSnapshot(goal: Fixtures.goal))
        let key = Fixtures.todayKey
        try store.update { snap in
            snap.updateDay(key) { $0.notes.append(Fixtures.note) }
        }
        let day = try XCTUnwrap(try store.load().day(key))
        XCTAssertEqual(day.goalID, Fixtures.goalID)
        XCTAssertEqual(day.notes.first?.text, Fixtures.noteText)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testDatesSurviveJSON() throws {
        let store = JSONFileStore(url: tempURL)
        var snap = Fixtures.snapshot(today: Fixtures.today(done: true, reflection: Fixtures.savedReflection))
        snap.settings.timeZoneID = "Asia/Tokyo"
        try store.save(snap)
        let loaded = try store.load()
        XCTAssertEqual(loaded.day(Fixtures.todayKey)?.reflection?.summary, Fixtures.reflectionSummary)
        XCTAssertEqual(loaded.settings.timeZoneID, "Asia/Tokyo")
        XCTAssertEqual(loaded.settings.rhythm.morning.description, "07:00")
        XCTAssertEqual(loaded.settings.rhythm.evening.description, "21:00")
    }
}
