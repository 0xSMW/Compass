import XCTest
import CompassCore
@testable import Compass

/// The save path stamps local edits for sync (M1, M10); merges and restores are not stamped.
@MainActor
final class SyncStampingTests: XCTestCase {
    let now = Fixtures.date(Fixtures.todayKey, 14)

    /// Completing stamps the completion only (N2): `updatedAt` stays for title and part edits, so a title
    /// edit made on another device isn't lost to this later completion.
    func testCompletingTheStepStampsIt() {
        let (model, _) = TestModel.make(now: now, spy: EffectsSpy())
        let editStamp = model.today?.step?.updatedAt
        model.setStepDone(true)
        XCTAssertEqual(model.today?.step?.completionChangedAt, now)
        XCTAssertEqual(model.today?.step?.updatedAt, editStamp)
        XCTAssertNil(model.goal?.updatedAt, "untouched items stay unstamped")
    }

    func testNewNoteCarriesThisDevicesID() {
        let (model, _) = TestModel.make(now: now, spy: EffectsSpy())
        model.addNote("Sam replied")
        let note = model.today?.notes.last
        XCTAssertEqual(note?.deviceID, model.deviceIdentity.id)
        XCTAssertEqual(note?.device, model.deviceIdentity.model, "stored as the model, not \"This iPhone\"")
    }

    func testRemoteAndRestoredSnapshotsAreNotStamped() {
        let spy = EffectsSpy()
        let (model, _) = TestModel.make(snapshot: .empty, now: now, spy: spy)
        var restored = Fixtures.restorableSnapshot
        restored.updateDay(Fixtures.todayKey) { $0.notes.append(Note(text: "from the old phone", createdAt: now, device: "This iPhone")) }
        model.applyRestoredSnapshot(restored)
        XCTAssertEqual(model.snapshot, restored, "restored items keep their own devices and times")
        XCTAssertEqual(spy.syncNotifications, 1, "a restore still syncs")

        var merged = restored
        merged.settings.cloudAssist.toggle()
        model.commit(merged, origin: .remote)
        XCTAssertNil(model.settings.updatedAt)
    }
}
