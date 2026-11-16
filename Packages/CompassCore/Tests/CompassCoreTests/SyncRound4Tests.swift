import Foundation
import XCTest
@testable import CompassCore

/// Round-4 sync review: a merge-demoted goal nobody holds (S1) and a goal-less envelope using up the
/// fresh-goal marker (S2). The fuzz runs two and three devices the way `SyncCoordinator` does (push, full
/// and partial pulls, set a goal, achieve, delete everything) and checks what every order must give.
final class SyncRound4Tests: XCTestCase {
    static let cal = Fixtures.calendar
    static let key = DayKey(year: 2026, month: 11, day: 10)
    static func d(_ h: Int, _ m: Int = 0) -> Date { key.date(in: cal, hour: h, minute: m) }
    func d(_ h: Int, _ m: Int = 0) -> Date { Self.d(h, m) }
    /// Fixed goal ids, so a run (tie-breaks included) is the same every time.
    static func goalID(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

    // MARK: - Devices and iCloud, as SyncCoordinator runs them

    struct Device {
        let identity: DeviceIdentity
        var snapshot: CompassSnapshot
        /// The envelope's `savedAt`: the last change made here (not a merge).
        var savedAt: Date
        var freshGoalID: UUID?
        var tombstones: [DayTombstone] = []
        var wipedAt: Date?
        var appliedWipe: Date?

        init(_ id: String, _ snapshot: CompassSnapshot = .empty, savedAt: Date = .distantPast, fresh: UUID? = nil) {
            identity = DeviceIdentity(id: id, model: id)
            self.snapshot = snapshot
            self.savedAt = savedAt
            freshGoalID = fresh
        }

        var envelope: SyncEnvelope {
            SyncEnvelope(deviceID: identity.id, deviceName: identity.model, savedAt: savedAt, snapshot: snapshot,
                         tombstones: tombstones, wipedAt: wipedAt)
        }

        mutating func change(at now: Date, _ body: (inout CompassSnapshot) -> Void) {
            var next = snapshot
            body(&next)
            snapshot = LocalEdits.stamp(next, since: snapshot, at: now, device: identity)
            savedAt = now
        }
    }

    struct World {
        var devices: [Device]
        /// The envelope files in iCloud, by device id.
        var cloud: [String: SyncEnvelope] = [:]
        var log: [String] = []
        /// Newest "Delete everything" so far.
        var lastWipe: Date?
        /// Every goal a user made after the newest wipe: the merge must keep each one somewhere.
        var made: [UUID: Date] = [:]
        /// Every goal a user marked achieved on some device after the newest wipe: once settled it must be
        /// achieved on every device (there is no un-achieve).
        var achieved: Set<UUID> = []
        var nextGoal = 100
        /// Every wipe so far: its stamp and the goals the wiping device held (and so deleted).
        var wipes: [(stamp: Date, deleted: Set<UUID>)] = []
        /// For each goal a user set: the newest wipe its device had carried out when it set it.
        var appliedWhenMade: [UUID: Date] = [:]

        init(_ devices: [Device]) {
            self.devices = devices
            for dev in devices { for g in [dev.snapshot.goal].compactMap({ $0 }) + dev.snapshot.pastGoals { made[g.id] = g.createdAt } }
        }

        /// `pushNow`: a wipe this device hasn't carried out yet means it merges first instead.
        mutating func push(_ i: Int) {
            let known = devices[i].appliedWipe ?? .distantPast
            if let wipe = cloud.values.compactMap(\.wipedAt).max(), wipe > known { log.append("push\(i)-deferred"); return }
            cloud[devices[i].identity.id] = devices[i].envelope
            log.append("push\(i)")
        }

        /// `pull` + `apply`. `only` limits the read to the files already downloaded.
        @discardableResult
        mutating func pull(_ i: Int, only: Set<String>? = nil, at now: Date) -> SyncApplyPlan.Action? {
            let remote = cloud.values.filter { only?.contains($0.deviceID) ?? true }.sorted { $0.deviceID < $1.deviceID }
            var dev = devices[i]
            log.append("pull\(i)\(only.map { "\($0.sorted())" } ?? "")")
            guard let plan = SyncApply.plan(SyncApplyInput(local: dev.envelope, remote: remote, appliedWipe: dev.appliedWipe,
                                                           freshGoalID: dev.freshGoalID, now: now)) else { return nil }
            dev.tombstones = plan.merged.tombstones
            dev.wipedAt = plan.merged.wipedAt
            if plan.newWipe { dev.appliedWipe = plan.merged.wipedAt }
            dev.freshGoalID = plan.freshGoalID
            switch plan.action {
            case .keep: break
            case .eraseLocal:
                dev.snapshot = .empty
                dev.tombstones = []
            case .adopt(let next, .merge): dev.snapshot = next
            case .adopt(let next, .localChange):
                dev.snapshot = LocalEdits.stamp(next, since: dev.snapshot, at: now, device: dev.identity)
                dev.savedAt = now
            }
            devices[i] = dev
            return plan.action
        }

        /// `AppModel.setGoal`: the current goal (if any) ends as replaced and the new one is current.
        mutating func setGoal(_ i: Int, _ text: String, at now: Date) {
            let goal = Goal(id: SyncRound4Tests.goalID(nextGoal), text: text, createdAt: now)
            nextGoal += 1
            devices[i].change(at: now) { s in
                if var old = s.goal {
                    if old.status == .active { old.status = .replaced }
                    old.endedAt = old.endedAt ?? now
                    s.pastGoals.insert(old, at: 0)
                }
                s.goal = goal
            }
            made[goal.id] = now
            if let applied = devices[i].appliedWipe { appliedWhenMade[goal.id] = applied }
            log.append("setGoal\(i) \(text)")
        }

        mutating func achieve(_ i: Int, at now: Date) {
            guard let goal = devices[i].snapshot.goal, goal.status == .active else { return }
            achieved.insert(goal.id)
            devices[i].change(at: now) { s in
                s.goal?.status = .achieved
                s.goal?.endedAt = now
            }
            log.append("achieve\(i)")
        }

        /// `wipeEverywhere`: dated by `SyncEnvelope.wipeDate` (this device's clock `now`, unless it holds
        /// something stamped later or knows a later wipe); iCloud is cleared and holds only this device's marker.
        mutating func wipe(_ i: Int, at now: Date) {
            let old = devices[i]
            let stamp = old.envelope.wipeDate(now: now, knownWipe: old.appliedWipe)
            wipes.append((stamp, Set(([old.snapshot.goal].compactMap { $0 } + old.snapshot.pastGoals).map(\.id))))
            var dev = Device(old.identity.id, savedAt: stamp)
            dev.wipedAt = stamp
            dev.appliedWipe = stamp
            devices[i] = dev
            cloud = [dev.identity.id: dev.envelope]
            lastWipe = stamp
            made = made.filter { $0.value >= stamp }
            achieved = achieved.filter { made[$0] != nil }
            log.append("wipe\(i)")
        }

        /// Full rounds (every device reads every file, then pushes) until one changes nothing.
        /// Returns false if the devices are still changing after `limit` rounds.
        /// `offsets`: each device's clock, ahead (+) or behind (-) real time.
        mutating func settle(from start: Date, limit: Int = 6, offsets: [TimeInterval]? = nil) -> Bool {
            var now = start
            for _ in 0..<limit {
                let before = (devices.map(\.snapshot), cloud)
                var changed = false
                for i in devices.indices {
                    now += 60
                    if let action = pull(i, at: now + (offsets?[i] ?? 0)), action != .keep { changed = true }
                    push(i)
                }
                if !changed && before.0 == devices.map(\.snapshot) && before.1 == cloud { return true }
            }
            return false
        }

        var converged: Bool {
            devices.dropFirst().allSatisfy { $0.snapshot == devices[0].snapshot }
                && devices.allSatisfy { cloud[$0.identity.id]?.snapshot == $0.snapshot }
        }

        /// Past goals by text: two can end at the same moment, and their order then follows random ids.
        func show(_ i: Int) -> String {
            func g(_ goal: Goal) -> String { "\(goal.text)/\(goal.status)\(goal.demotedByMerge == true ? "*" : "")" }
            let s = devices[i].snapshot
            return "\(devices[i].identity.id): cur=\(s.goal.map(g) ?? "nil") past=\(s.pastGoals.sorted { $0.text < $1.text }.map(g))"
        }

        /// What every settled world must hold; nil when it does.
        func violation() -> String? {
            for (i, dev) in devices.enumerated() {
                let s = dev.snapshot
                let all = [s.goal].compactMap { $0 } + s.pastGoals
                if Set(all.map(\.id)).count != all.count { return "goal listed twice on \(show(i))" }
                if all.contains(where: { !$0.isEndedByUser }) && s.goal == nil {
                    return "a goal nobody ended, but no current goal: \(show(i))"
                }
                if s.pastGoals.contains(where: { $0.status == .active }) { return "an active past goal: \(show(i))" }
                let kept = Set(all.map(\.id))
                if let lost = made.keys.first(where: { !kept.contains($0) }) { return "goal \(lost) lost: \(show(i))" }
                if let g = all.first(where: { achieved.contains($0.id) && $0.status != .achieved }) {
                    return "an achieved goal shown as \(g.status): \(show(i))"
                }
            }
            return nil
        }

        /// What a settled world must hold when clocks disagree and devices wipe: the newest wipe (by stamp)
        /// deleted everything the wiping device held, and kept every goal set on a device that had already
        /// carried it out, whatever that device's clock said. A goal made around the wipe on a device that had
        /// not heard of it can go either way (only its clock says which side it falls on); not checked.
        func wipeViolation() -> String? {
            for (i, dev) in devices.enumerated() {
                let s = dev.snapshot
                let all = [s.goal].compactMap { $0 } + s.pastGoals
                if Set(all.map(\.id)).count != all.count { return "goal listed twice on \(show(i))" }
                guard let newest = wipes.map(\.stamp).max() else { continue }
                let kept = Set(all.map(\.id))
                if let back = wipes.filter({ $0.stamp == newest }).flatMap(\.deleted).first(where: kept.contains) {
                    return "goal \(back) deleted by the wipe is back: \(show(i))"
                }
                if let lost = appliedWhenMade.first(where: { $0.value >= newest && !kept.contains($0.key) }) {
                    return "goal \(lost.key) set after carrying out the wipe lost: \(show(i))"
                }
            }
            return nil
        }
    }

    /// SplitMix64: the same sequence on every platform and toolchain.
    struct Seeded {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(n))
        }
    }

    let oldGoal = Goal(id: SyncRound4Tests.goalID(1), text: "OLD", createdAt: SyncRound4Tests.d(6))
    let n1 = Goal(id: SyncRound4Tests.goalID(2), text: "N1", createdAt: SyncRound4Tests.d(9))
    let n2 = Goal(id: SyncRound4Tests.goalID(3), text: "N2", createdAt: SyncRound4Tests.d(9, 30))

    // MARK: - S1 · a merge-demoted goal nobody holds

    /// Probe R9: old phone A holds OLD; new devices B and C each start a goal before seeing A. C reads B
    /// before A's file has downloaded (N2 over N1), then A (OLD is earliest; N2 demoted, C's marker spent);
    /// B reads A (N1 over OLD). Every current goal is now ended somewhere, and N2, which nobody ended,
    /// comes back as current everywhere instead of every device settling on none.
    func testR9_twoNewDevicesBesideAnOldOneKeepACurrentGoal() {
        var w = World([Device("A", CompassSnapshot(goal: oldGoal), savedAt: d(8)),
                       Device("B", CompassSnapshot(goal: n1), savedAt: d(9), fresh: n1.id),
                       Device("C", CompassSnapshot(goal: n2), savedAt: d(9, 30), fresh: n2.id)])
        w.push(0); w.push(1)
        w.pull(2, only: ["B"], at: d(9, 31))
        XCTAssertEqual(w.show(2), "C: cur=N2/active past=[\"N1/replaced\"]")
        w.pull(2, at: d(9, 32)); w.push(2)
        XCTAssertEqual(w.show(2), "C: cur=OLD/active past=[\"N1/replaced\", \"N2/replaced*\"]")
        w.pull(1, at: d(9, 33)); w.push(1)
        XCTAssertEqual(w.show(1), "B: cur=N1/active past=[\"N2/replaced*\", \"OLD/replaced\"]")

        XCTAssertTrue(w.settle(from: d(10)), "\(w.log)")
        XCTAssertTrue(w.converged, (0..<3).map(w.show).joined(separator: " | "))
        for dev in w.devices {
            XCTAssertEqual(dev.snapshot.goal?.id, n2.id, "\(dev.identity.id)")
            XCTAssertEqual(dev.snapshot.goal?.status, .active)
            XCTAssertNil(dev.snapshot.goal?.demotedByMerge)
            XCTAssertEqual(Set(dev.snapshot.pastGoals.map(\.id)), [n1.id, oldGoal.id])
            XCTAssertTrue(dev.snapshot.pastGoals.allSatisfy { $0.status == .replaced && $0.demotedByMerge == nil })
        }
        XCTAssertNil(w.violation())
    }

    /// Probe R11, seed 644: two devices, no third needed. Each sets goals offline with partial syncs in
    /// between, until A holds N1 (which B ended) and B holds U0 (which A achieved and moved on from). The
    /// newest goal a merge demoted, U2 (the last one the user set), comes back as current on both.
    func testR11_twoDevicesSettingGoalsOfflineKeepACurrentGoal() {
        var w = World([Device("A", CompassSnapshot(goal: oldGoal), savedAt: d(8)),
                       Device("B", CompassSnapshot(goal: n1), savedAt: d(9), fresh: n1.id)])
        var minute = 0
        func t() -> Date { minute += 1; return d(10, minute) }
        w.push(1); _ = t()
        w.setGoal(0, "U0", at: t())
        w.pull(1, at: t())
        w.push(0); _ = t()
        w.achieve(0, at: t())
        w.setGoal(0, "U1", at: t())
        w.push(1); _ = t()
        w.push(1); _ = t()
        w.setGoal(1, "U2", at: t())
        w.pull(1, at: t())
        XCTAssertEqual(w.show(1), "B: cur=U0/active past=[\"N1/replaced\", \"OLD/replaced\", \"U2/replaced*\"]")
        w.pull(0, at: t())
        XCTAssertEqual(w.show(0), "A: cur=N1/active past=[\"OLD/replaced\", \"U0/achieved\", \"U1/replaced*\"]")
        w.pull(1, at: t())
        w.pull(0, at: t())

        XCTAssertTrue(w.settle(from: d(11)), "\(w.log)")
        XCTAssertTrue(w.converged, (0..<2).map(w.show).joined(separator: " | "))
        for i in 0..<2 {
            XCTAssertEqual(w.show(i).dropFirst(3),
                           "cur=U2/active past=[\"N1/replaced\", \"OLD/replaced\", \"U0/achieved\", \"U1/replaced*\"]")
        }
        XCTAssertNil(w.violation())
    }

    /// The fallback never brings back a goal some device ended itself, and picks the newest of several.
    func testOnlyAGoalNobodyEndedComesBack() throws {
        func ended(_ g: Goal, demoted: Bool) -> Goal {
            var g = g
            g.status = .replaced
            g.endedAt = d(10)
            g.demotedByMerge = demoted ? true : nil
            return g
        }
        let u = Goal(id: Self.goalID(4), text: "U", createdAt: d(9, 45))
        // A holds N1, which B ended; B holds OLD, which A ended. N2 and U were only demoted by merges.
        let a = CompassSnapshot(goal: n1, pastGoals: [ended(n2, demoted: true), ended(oldGoal, demoted: false)])
        let b = CompassSnapshot(goal: oldGoal, pastGoals: [ended(u, demoted: true), ended(n1, demoted: false)])
        for order in [[("A", a, d(11)), ("B", b, d(12))], [("B", b, d(11)), ("A", a, d(12))]] {
            let out = try XCTUnwrap(SnapshotMerger.merge(order.map {
                SyncEnvelope(deviceID: $0.0, deviceName: $0.0, savedAt: $0.2, snapshot: $0.1)
            })).snapshot
            XCTAssertEqual(out.goal?.id, u.id, "the newest goal nobody ended")
            XCTAssertEqual(out.goal?.status, .active)
            XCTAssertNil(out.goal?.demotedByMerge)
            XCTAssertNil(out.goal?.endedAt)
            let past = Dictionary(uniqueKeysWithValues: out.pastGoals.map { ($0.id, $0) })
            XCTAssertEqual(Set(past.keys), [n1.id, n2.id, oldGoal.id])
            XCTAssertEqual(past[n2.id]?.demotedByMerge, true, "still only demoted")
            XCTAssertNil(past[n1.id]?.demotedByMerge)
            XCTAssertNil(past[oldGoal.id]?.demotedByMerge)
        }

        // An achieved goal a merge demoted comes back achieved.
        var achieved = ended(u, demoted: true)
        achieved.status = .achieved
        let c = CompassSnapshot(goal: oldGoal, pastGoals: [achieved, ended(n1, demoted: false)])
        let out = try XCTUnwrap(SnapshotMerger.merge([SyncEnvelope(deviceID: "A", deviceName: "A", savedAt: d(11), snapshot: a),
                                                      SyncEnvelope(deviceID: "C", deviceName: "C", savedAt: d(12), snapshot: c)])).snapshot
        XCTAssertEqual(out.goal?.id, u.id)
        XCTAssertEqual(out.goal?.status, .achieved)
        XCTAssertEqual(out.goal?.endedAt, d(10))
    }

    // MARK: - S2 · a goal-less envelope keeps the fresh-goal marker

    /// Probe R1: the first pass after the fresh goal sees only a never-onboarded install's blank envelope
    /// (the old phone's file is still downloading); the second sees the old phone. The fresh goal stays.
    func testR1_goallessEnvelopeKeepsTheFreshGoalMarker() {
        let newGoal = Goal(id: Self.goalID(2), text: "NEW", createdAt: d(9))
        var w = World([Device("A", CompassSnapshot(goal: oldGoal), savedAt: d(8)),
                       Device("B", CompassSnapshot(goal: newGoal), savedAt: d(9), fresh: newGoal.id),
                       Device("D")])
        w.push(0); w.push(2); w.push(1)
        w.pull(1, only: ["D"], at: d(9, 1))
        XCTAssertEqual(w.devices[1].freshGoalID, newGoal.id, "a goal-less envelope says nothing about the backup")
        XCTAssertEqual(w.show(1), "B: cur=NEW/active past=[]")
        w.pull(1, at: d(9, 2))
        XCTAssertNil(w.devices[1].freshGoalID)
        XCTAssertEqual(w.show(1), "B: cur=NEW/active past=[\"OLD/replaced\"]")

        XCTAssertTrue(w.settle(from: d(10)))
        XCTAssertTrue(w.converged)
        for i in 0..<3 { XCTAssertEqual(w.show(i).dropFirst(3), "cur=NEW/active past=[\"OLD/replaced\"]") }
    }

    // MARK: - The fuzz

    /// One random run: `ops` random steps from the scenario's start, then full rounds. With `skewMinutes`,
    /// each device's clock is off real time by up to that much (and now and then jumps), every run may wipe,
    /// and the run is judged by `wipeViolation` instead of `violation`.
    func fuzzRun(seed: UInt64, devices count: Int, skewMinutes skew: Int = 0) -> (World, String?) {
        var rng = Seeded(state: seed &* 0x2545_F491_4F6C_DD1D &+ UInt64(count) &+ (skew > 0 ? 0x5EED : 0))
        var devices = [Device("A", CompassSnapshot(goal: oldGoal), savedAt: d(8)),
                       Device("B", CompassSnapshot(goal: n1), savedAt: d(9), fresh: rng.next(3) == 0 ? nil : n1.id)]
        if count == 3 {
            switch rng.next(3) {
            case 0: devices.append(Device("C", CompassSnapshot(goal: n2), savedAt: d(9, 30), fresh: n2.id))
            case 1: devices.append(Device("C", CompassSnapshot(goal: n2), savedAt: d(9, 30)))
            default: devices.append(Device("C")) // installed, never onboarded: a goal-less envelope
            }
        }
        var w = World(devices)
        let wipes = skew > 0 || rng.next(5) == 0
        func clock() -> TimeInterval { TimeInterval((rng.next(2 * skew + 1) - skew) * 60) }
        var offset = (0..<count).map { _ in skew > 0 ? clock() : 0 }
        var now = d(10)
        var goals = 0
        for _ in 0..<(4 + rng.next(14)) {
            now += 60
            let i = rng.next(count)
            if skew > 0, rng.next(25) == 0 { offset[i] = clock() }
            let local = now + offset[i]
            switch rng.next(20) {
            case 0...5: w.push(i)
            case 6...9: w.pull(i, at: local)
            case 10...13:
                let others = w.devices.indices.filter { $0 != i }
                w.pull(i, only: [w.devices[others[rng.next(others.count)]].identity.id], at: local)
            case 14, 15:
                w.setGoal(i, "U\(goals)", at: local)
                goals += 1
            case 16, 17: w.achieve(i, at: local)
            case 18 where wipes: w.wipe(i, at: local)
            case 19 where skew > 0: w.wipe(i, at: local)
            default: w.push(i)
            }
        }
        guard w.settle(from: now, offsets: offset) else { return (w, "unstable") }
        guard w.converged else { return (w, "diverged") }
        return (w, skew > 0 ? w.wipeViolation() : w.violation())
    }

    func fuzz(devices count: Int, runs: Int, skewMinutes skew: Int = 0) {
        var failures: [String: Int] = [:]
        for seed in 0..<UInt64(runs) {
            let (w, problem) = fuzzRun(seed: seed, devices: count, skewMinutes: skew)
            guard let problem else { continue }
            let kind = String(problem.prefix(while: { $0 != ":" }))
            failures[kind, default: 0] += 1
            if failures.values.reduce(0, +) <= 3 {
                XCTFail("\(count) devices, seed \(seed): \(problem)\n\(w.log)\n"
                        + w.devices.indices.map(w.show).joined(separator: " | "))
            }
        }
        XCTAssertEqual(failures, [:], "\(count) devices, \(runs) runs, clocks up to \(skew) min apart")
    }

    /// Two devices: the old phone and a new one (fresh marker in two runs of three), with goal changes,
    /// achievements and the odd wipe.
    func testFuzzTwoDevicesConvergeOnOneCurrentGoal() {
        fuzz(devices: 2, runs: 3000)
    }

    /// Three devices: the third holds a second new goal (fresh or not) or is installed but never onboarded.
    func testFuzzThreeDevicesConvergeOnOneCurrentGoal() {
        fuzz(devices: 3, runs: 4000)
    }

    /// Two and three devices whose clocks are up to 30 minutes off real time (and sometimes jump), with
    /// wipes in every run, each dated as `wipeEverywhere` dates it: no goal set on a device that had already
    /// carried out the newest wipe is lost, and nothing the wiping device held survives it.
    func testFuzzWipesWithClocksThirtyMinutesApart() {
        fuzz(devices: 2, runs: 3000, skewMinutes: 30)
        fuzz(devices: 3, runs: 4000, skewMinutes: 30)
    }
}
