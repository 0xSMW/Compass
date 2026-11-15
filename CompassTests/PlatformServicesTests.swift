import XCTest
import CompassCore
@testable import Compass

/// Export (one zip, cleaned up), cloud-help availability and the reconnect retry rules.
@MainActor
final class DataExportTests: XCTestCase {
    private var audioDirectory: URL!

    override func setUp() async throws {
        DataExport.cleanUp()
        audioDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("CompassTestsAudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        DataExport.cleanUp()
        try? FileManager.default.removeItem(at: audioDirectory)
    }

    func testExportIsOneZipInsideTheExportFolder() throws {
        let memo = audioDirectory.appendingPathComponent("memo.m4a")
        try Data(repeating: 7, count: 4096).write(to: memo)
        let urls = DataExport.makeExport(Fixtures.snapshot(today: Fixtures.today()), audio: [memo], now: Fixtures.referenceDate)
        XCTAssertEqual(urls.count, 1)
        let zip = try XCTUnwrap(urls.first)
        XCTAssertEqual(zip.pathExtension, "zip")
        XCTAssertEqual(zip.lastPathComponent, "Compass export 2026-11-10.zip")
        XCTAssertTrue(zip.path.hasPrefix(DataExport.root.path))
        let header = try Data(contentsOf: zip).prefix(2)
        XCTAssertEqual(Array(header), [0x50, 0x4B], "PK zip signature")
        // The staging folder is gone; only the zip remains until the share sheet finishes.
        let left = try FileManager.default.contentsOfDirectory(atPath: DataExport.root.path)
        XCTAssertEqual(left, [zip.lastPathComponent])
        // The original recording is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: memo.path))
    }

    func testCleanUpRemovesEverythingTheExportWrote() throws {
        let urls = DataExport.makeExport(.empty, audio: [], now: Fixtures.referenceDate)
        XCTAssertFalse(urls.isEmpty)
        DataExport.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: DataExport.root.path))
        for url in urls { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }
}

@MainActor
final class CloudHelpAvailabilityTests: XCTestCase {
    func testNoEndpointMeansNotConfiguredAndNeverOn() {
        let spy = EffectsSpy()
        let snapshot = Fixtures.snapshot(today: Fixtures.today())
        XCTAssertTrue(snapshot.settings.cloudAssist)
        let model = AppModel(snapshot: snapshot, store: InMemoryStore(snapshot), calendar: Fixtures.calendar,
                             now: { Fixtures.date(Fixtures.todayKey, 14) }, effects: spy.effects,
                             cloud: HTTPCloudAssist(configuration: .none, switchOn: true))
        XCTAssertFalse(model.cloudHelpConfigured)
        XCTAssertFalse(model.cloudHelpOn, "the switch must not pretend when there is no endpoint")
    }

    func testHTTPSEndpointIsConfigured() {
        let spy = EffectsSpy()
        let snapshot = Fixtures.snapshot(today: nil)
        let config = CloudAssistConfiguration(endpointString: "https://assist.example.com/v1")
        let model = AppModel(snapshot: snapshot, store: InMemoryStore(snapshot), calendar: Fixtures.calendar,
                             now: { Fixtures.date(Fixtures.todayKey, 14) }, effects: spy.effects,
                             cloud: HTTPCloudAssist(configuration: config, switchOn: true))
        XCTAssertTrue(model.cloudHelpConfigured)
        XCTAssertTrue(model.cloudHelpOn)
    }

    func testPlainHTTPEndpointIsNotConfigured() {
        XCTAssertFalse(CloudAssistConfiguration(endpointString: "http://assist.example.com/v1").isConfigured)
    }
}
