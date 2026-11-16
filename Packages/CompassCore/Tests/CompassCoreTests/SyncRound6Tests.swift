import Foundation
import XCTest
@testable import CompassCore

/// Round-6 sync review: a fresh goal that an old device first received through a merge and then replaced
/// with a slow clock (N3). Runs on the same devices and iCloud as `SyncRound4Tests`.
final class SyncRound6Tests: XCTestCase {
    typealias World = SyncRound4Tests.World
    typealias Device = SyncRound4Tests.Device
    func d(_ h: Int, _ m: Int = 0) -> Date { SyncRound4Tests.d(h, m) }
    func goalID(_ n: Int) -> UUID { SyncRound4Tests.goalID(n) }

    /// Probe W5: new device C makes U2 and keeps its fresh marker (its first pass read no goals). Old device
    /// B merges U2, which lands in its past goals marked `demotedByMerge`, ended at C's time. The user then
    /// sets U3 on B, whose clock is minutes behind, so U3 is dated before U2. B moved on from U2 knowingly,
    /// so C doesn't put U2 back on top; both settle on U3.
    func testW5_mergedThenReplacedOnASlowClockIsNotUndone() throws {
        let g1 = Goal(id: goalID(1), text: "G1", createdAt: d(7))
        let u2 = Goal(id: goalID(2), text: "U2", createdAt: d(10, 10))
        var w = World([Device("B", CompassSnapshot(goal: g1), savedAt: d(8)),
                       Device("C", CompassSnapshot(goal: u2), savedAt: d(10, 10), fresh: u2.id)])
        w.push(1)
        w.pull(0, at: d(10, 0))
        XCTAssertEqual(w.show(0), "B: cur=G1/active past=[\"U2/replaced*\"]")

        w.setGoal(0, "U3", at: d(10, 2)); w.push(0)
        let ended = try XCTUnwrap(w.devices[0].snapshot.pastGoals.first { $0.id == u2.id })
        XCTAssertNil(ended.demotedByMerge, "B moved on from U2 itself")
        XCTAssertEqual(ended.endedAt, w.devices[0].snapshot.goal?.createdAt, "ended on B's clock, when U3 was set")

        w.pull(1, at: d(10, 20))
        XCTAssertEqual(w.show(1), "C: cur=U3/active past=[\"G1/replaced\", \"U2/replaced\"]")
        XCTAssertNil(w.devices[1].freshGoalID)
        w.push(1)

        XCTAssertTrue(w.settle(from: d(11)), "\(w.log)")
        XCTAssertTrue(w.converged, (0..<2).map(w.show).joined(separator: " | "))
        for i in 0..<2 { XCTAssertEqual(w.show(i).dropFirst(3), "cur=U3/active past=[\"G1/replaced\", \"U2/replaced\"]") }
        XCTAssertNil(w.violation())
    }

    /// Setting a goal restamps the end of a replaced goal a merge demoted, and nothing else: an achieved
    /// goal keeps its achievement time (marked or not), and a goal a user ended keeps its own end.
    func testSettingAGoalRestampsOnlyMergeDemotedReplacedGoals() throws {
        func past(_ n: Int, _ status: GoalStatus, endedAt: Date, marked: Bool) -> Goal {
            var g = Goal(id: goalID(n), text: "P\(n)", createdAt: d(6))
            g.status = status
            g.endedAt = endedAt
            g.demotedByMerge = marked ? true : nil
            return g
        }
        let demoted = past(1, .replaced, endedAt: d(10, 30), marked: true)
        let achievedDemoted = past(2, .achieved, endedAt: d(9), marked: true)
        let achieved = past(3, .achieved, endedAt: d(9, 10), marked: false)
        let replaced = past(4, .replaced, endedAt: d(9, 20), marked: false)
        let current = Goal(id: goalID(5), text: "OLD", createdAt: d(7))
        let old = CompassSnapshot(goal: current, pastGoals: [demoted, achievedDemoted, achieved, replaced])

        var ended = current
        ended.status = .replaced
        ended.endedAt = d(10)
        let next = Goal(id: goalID(6), text: "NEXT", createdAt: d(10))
        let new = CompassSnapshot(goal: next, pastGoals: [ended] + old.pastGoals)
        let device = DeviceIdentity(id: "B", model: "iPhone")
        let stamped = LocalEdits.stamp(new, since: old, at: d(10), device: device)
        func find(_ g: Goal) throws -> Goal { try XCTUnwrap(stamped.pastGoals.first { $0.id == g.id }) }

        XCTAssertEqual(try find(demoted).endedAt, next.createdAt)
        XCTAssertNil(try find(demoted).demotedByMerge)
        XCTAssertEqual(try find(achievedDemoted).endedAt, d(9), "an achievement keeps its time")
        XCTAssertEqual(try find(achievedDemoted).status, .achieved)
        XCTAssertNil(try find(achievedDemoted).demotedByMerge)
        XCTAssertEqual(try find(achieved).endedAt, d(9, 10))
        XCTAssertEqual(try find(replaced).endedAt, d(9, 20))
        XCTAssertEqual(try find(ended).endedAt, d(10))

        // An edit that sets no new goal leaves a demoted goal as the merge wrote it.
        var edited = old
        edited.goal?.text = "OLD, renamed"
        let kept = LocalEdits.stamp(edited, since: old, at: d(10), device: device)
        XCTAssertEqual(kept.pastGoals.first { $0.id == demoted.id }, demoted)
    }
}
