import Foundation
import XCTest
@testable import CompassCore

/// Round-5 sync review: an achieved goal shown as replaced after another device set the next goal (N1),
/// and a fresh goal promoted over a goal whose device had already ended it (N2). Runs on the same devices
/// and iCloud as `SyncRound4Tests`.
final class SyncRound5Tests: XCTestCase {
    typealias World = SyncRound4Tests.World
    typealias Device = SyncRound4Tests.Device
    func d(_ h: Int, _ m: Int = 0) -> Date { SyncRound4Tests.d(h, m) }
    func goalID(_ n: Int) -> UUID { SyncRound4Tests.goalID(n) }

    // MARK: - N1 · achieved stays achieved

    /// Probe U1: iPad and iPhone both hold G. On the iPad the user marks G achieved at 10:00; on the iPhone,
    /// before that syncs, they set the next goal at 10:05, which ends the iPhone's copy of G as replaced.
    /// Both devices settle on the next goal with G achieved at 10:00, the same as those taps on one device.
    func testN1_goalAchievedOnIPadStaysAchievedWhenIPhoneSetsTheNextGoal() {
        let g = Goal(id: goalID(1), text: "G", createdAt: d(6))
        var w = World([Device("iPad", CompassSnapshot(goal: g), savedAt: d(8)),
                       Device("iPhone", CompassSnapshot(goal: g), savedAt: d(8))])
        w.push(0); w.push(1)
        w.achieve(0, at: d(10)); w.push(0)
        w.setGoal(1, "NEXT", at: d(10, 5)); w.push(1)

        XCTAssertTrue(w.settle(from: d(11)), "\(w.log)")
        XCTAssertTrue(w.converged, (0..<2).map(w.show).joined(separator: " | "))
        for dev in w.devices {
            XCTAssertEqual(dev.snapshot.goal?.text, "NEXT", dev.identity.id)
            XCTAssertEqual(dev.snapshot.goal?.status, .active)
            let ended = dev.snapshot.pastGoals.first { $0.id == g.id }
            XCTAssertEqual(ended?.status, .achieved, dev.identity.id)
            XCTAssertEqual(ended?.endedAt, d(10), "ended when it was achieved, not when the next goal was set")
            XCTAssertNil(ended?.demotedByMerge)
        }
        XCTAssertNil(w.violation())

        var one = World([Device("iPhone", CompassSnapshot(goal: g), savedAt: d(8))])
        one.achieve(0, at: d(10))
        one.setGoal(0, "NEXT", at: d(10, 5))
        XCTAssertEqual(one.show(0).dropFirst("iPhone: ".count), w.show(0).dropFirst("iPad: ".count))
    }

    /// An achieved copy a merge also demoted still wins over a copy a user ended as replaced, and over an
    /// active one, in either order; the merge marker doesn't survive on a goal a user ended.
    func testN1_achievedWinsEvenWhenAMergeDemotedThatCopy() throws {
        let g = Goal(id: goalID(4), text: "G", createdAt: d(9))
        var achievedDemoted = g
        achievedDemoted.status = .achieved
        achievedDemoted.endedAt = d(10)
        achievedDemoted.demotedByMerge = true
        var replaced = g
        replaced.status = .replaced
        replaced.endedAt = d(10, 5)
        var active = g
        active.updatedAt = d(10, 30)

        for other in [replaced, active] {
            for (a, b) in [(achievedDemoted, other), (other, achievedDemoted)] {
                let picked = SnapshotMerger.pickGoal(a, b)
                XCTAssertEqual(picked.status, .achieved)
                XCTAssertEqual(picked.endedAt, d(10))
            }
        }

        // Through the merge: the old phone holds OLD and ended G as replaced; the other device holds NEXT
        // with its achieved copy of G demoted below it.
        let old = Goal(id: goalID(1), text: "OLD", createdAt: d(6))
        let next = Goal(id: goalID(5), text: "NEXT", createdAt: d(10, 10))
        let a = CompassSnapshot(goal: old, pastGoals: [replaced])
        let b = CompassSnapshot(goal: next, pastGoals: [achievedDemoted])
        for order in [[("A", a, d(11)), ("B", b, d(12))], [("B", b, d(11)), ("A", a, d(12))]] {
            let out = try XCTUnwrap(SnapshotMerger.merge(order.map {
                SyncEnvelope(deviceID: $0.0, deviceName: $0.0, savedAt: $0.2, snapshot: $0.1)
            })).snapshot
            let merged = try XCTUnwrap(out.pastGoals.first { $0.id == g.id })
            XCTAssertEqual(merged.status, .achieved)
            XCTAssertEqual(merged.endedAt, d(10))
            XCTAssertNil(merged.demotedByMerge, "a user ended it (A's copy)")
        }
    }

    // MARK: - N2 · promoting only what the merge demoted

    /// Probe U2: two new devices finish onboarding in the same second. Dates are saved as ISO-8601 without
    /// fractions, so both goals have the same `createdAt`. Only the goal the merge put below the other
    /// (by id) comes back; both devices then keep the same current goal instead of each ending the other's.
    func testN2_freshGoalsMadeInTheSameSecondKeepOneCurrentGoal() {
        let t = d(9)
        let encoded = try? JSONFileStore.decoder().decode(Goal.self, from: JSONFileStore.encoder()
            .encode(Goal(text: "N", createdAt: t.addingTimeInterval(0.7))))
        XCTAssertEqual(encoded?.createdAt, t, "saved without fractions of a second")

        let n1 = Goal(id: goalID(2), text: "N1", createdAt: t)
        let n2 = Goal(id: goalID(3), text: "N2", createdAt: t)
        XCTAssertLessThan(n1.id.uuidString, n2.id.uuidString, "the merge keeps N1 and demotes N2")
        for demotedFirst in [true, false] {
            var w = World([Device("A", CompassSnapshot(goal: n1), savedAt: d(9), fresh: n1.id),
                           Device("B", CompassSnapshot(goal: n2), savedAt: d(9), fresh: n2.id)])
            w.push(0); w.push(1)
            let first = demotedFirst ? 1 : 0
            w.pull(first, at: d(9, 2)); w.push(first)
            w.pull(1 - first, at: d(9, 3)); w.push(1 - first)

            XCTAssertTrue(w.settle(from: d(10)), "\(w.log)")
            XCTAssertTrue(w.converged, (0..<2).map(w.show).joined(separator: " | "))
            for i in 0..<2 {
                XCTAssertEqual(w.show(i).dropFirst(3), "cur=N2/active past=[\"N1/replaced\"]", "demotedFirst=\(demotedFirst)")
            }
            XCTAssertNil(w.violation())
        }
    }

    /// Probe U3: new device A makes N and still holds its fresh marker. Device D syncs N and the user
    /// replaces it with U, but D's clock is slow, so U is dated before N. D chose U knowingly, so A doesn't
    /// put N back on top; both settle on U with N replaced.
    func testN2_slowClockReplacementOfAFreshGoalIsNotUndone() {
        let n = Goal(id: goalID(2), text: "N", createdAt: d(9))
        var w = World([Device("A", CompassSnapshot(goal: n), savedAt: d(9), fresh: n.id), Device("D")])
        w.push(0)
        w.pull(1, at: d(8, 55))
        XCTAssertEqual(w.show(1), "D: cur=N/active past=[]")
        w.setGoal(1, "U", at: d(8, 56)); w.push(1)
        w.pull(0, at: d(9, 10))
        XCTAssertEqual(w.show(0), "A: cur=U/active past=[\"N/replaced\"]")
        XCTAssertNil(w.devices[0].freshGoalID)

        XCTAssertTrue(w.settle(from: d(10)), "\(w.log)")
        XCTAssertTrue(w.converged, (0..<2).map(w.show).joined(separator: " | "))
        for i in 0..<2 { XCTAssertEqual(w.show(i).dropFirst(3), "cur=U/active past=[\"N/replaced\"]") }
        XCTAssertNil(w.violation())
    }

    /// Same as U3, but D achieves N first and sets U later: N stays achieved and U current.
    func testN2_achievedThenReplacedFreshGoalIsNotUndone() {
        let n = Goal(id: goalID(2), text: "N", createdAt: d(9))
        var w = World([Device("A", CompassSnapshot(goal: n), savedAt: d(9), fresh: n.id), Device("D")])
        w.push(0)
        w.pull(1, at: d(8, 50))
        w.achieve(1, at: d(8, 52))
        w.setGoal(1, "U", at: d(8, 56)); w.push(1)
        w.pull(0, at: d(9, 10))

        XCTAssertTrue(w.settle(from: d(10)), "\(w.log)")
        XCTAssertTrue(w.converged, (0..<2).map(w.show).joined(separator: " | "))
        for i in 0..<2 { XCTAssertEqual(w.show(i).dropFirst(3), "cur=U/active past=[\"N/achieved\"]") }
        XCTAssertNil(w.violation())
    }
}
