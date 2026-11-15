import Foundation

// MARK: - Counts shown in R1/R2, H2

extension CompassSnapshot {
    /// Days that moved, across the current and past goals ("212 steps").
    public var totalSteps: Int { days.filter(\.moved).count }

    /// Recordings kept: spoken notes, spoken evening entries (all versions), spoken intentions, the why ("186 memos").
    public var memoCount: Int {
        var n = 0
        for d in days {
            n += d.notes.filter(\.isSpoken).count
            n += d.reflectionVersions.filter { $0.duration != nil }.count
            if d.intention?.duration != nil { n += 1 }
        }
        for g in [goal].compactMap({ $0 }) + pastGoals where g.why?.isSpoken == true { n += 1 }
        return n
    }

    /// Goals in the snapshot, current and past ("1 goal").
    public var goalCount: Int { (goal == nil ? 0 : 1) + pastGoals.count }

    /// Steps toward one goal: moved days tagged with it (untagged days count for the current goal).
    public func steps(for goal: Goal) -> Int {
        days.filter { d in d.moved && (d.goalID == goal.id || (d.goalID == nil && self.goal?.id == goal.id)) }.count
    }

    /// Days belonging to one goal, oldest first.
    public func days(for goal: Goal) -> [Day] {
        sortedDays.filter { d in d.goalID == goal.id || (d.goalID == nil && self.goal?.id == goal.id) }
    }
}

// MARK: - Backup / restore (R1–R3)

/// What an iCloud backup holds, for R1 ("212 steps · 186 memos · 1 goal") and R2.
public struct BackupSummary: Hashable, Sendable {
    public var goalText: String?
    public var steps: Int
    public var memos: Int
    public var goals: Int
    public var savedAt: Date?
    public var deviceName: String?

    public init(goalText: String?, steps: Int, memos: Int, goals: Int, savedAt: Date? = nil, deviceName: String? = nil) {
        self.goalText = goalText
        self.steps = steps
        self.memos = memos
        self.goals = goals
        self.savedAt = savedAt
        self.deviceName = deviceName
    }

    public init(snapshot: CompassSnapshot, savedAt: Date? = nil, deviceName: String? = nil) {
        self.init(goalText: snapshot.goal?.text, steps: snapshot.totalSteps, memos: snapshot.memoCount,
                  goals: snapshot.goalCount, savedAt: savedAt, deviceName: deviceName)
    }

    /// "212 steps · 186 memos · 1 goal"
    public var line: String {
        "\(steps) \(steps == 1 ? "step" : "steps") · \(memos) \(memos == 1 ? "memo" : "memos") · \(goals) \(goals == 1 ? "goal" : "goals")"
    }
}

public enum NothingToRestoreReason: Hashable, Sendable {
    /// R3: "There’s nothing from Compass in the iCloud account on this iPhone."
    case empty
    /// No iCloud account, iCloud Drive off for Compass, or a build without the iCloud entitlement.
    case iCloudUnavailable
}

public enum BackupAvailability: Hashable, Sendable {
    case available(BackupSummary)
    case nothing(NothingToRestoreReason)
}

public enum RestoreError: Error, Equatable, Sendable {
    case nothingToRestore
    case iCloudUnavailable
    case cancelled
}

/// Restores Compass from the user's iCloud (no account). Onboarding's R1–R3 use it:
/// `availability()` decides R1 vs R3; `restore(progress:)` drives R1's bar and returns the snapshot
/// for R2 ("Welcome back."). The caller puts the snapshot into the app model.
public protocol BackupRestoring: AnyObject, Sendable {
    func availability() async -> BackupAvailability
    /// Fetches the snapshot and its audio. `progress` reports 0...1 (any thread).
    func restore(progress: @escaping @Sendable (Double) -> Void) async throws -> CompassSnapshot
    /// R1 "Cancel". A running `restore` throws `RestoreError.cancelled`.
    func cancel()
}

/// Deterministic restorer for screenshots and tests: R1/R2 restore the standard fixture, R3 has nothing.
public final class FakeBackupRestoring: BackupRestoring, @unchecked Sendable {
    private let lock = NSLock()
    public var snapshot: CompassSnapshot?
    private var cancelled = false

    public init(snapshot: CompassSnapshot?) {
        self.snapshot = snapshot
    }

    /// R1/R2 restore the fixture's history and goal; R3 (`iCloudBackupAvailable == false`) has nothing.
    public convenience init(conditions: SystemConditions) {
        self.init(snapshot: conditions.iCloudBackupAvailable ? Fixtures.restorableSnapshot : nil)
    }

    public func availability() async -> BackupAvailability {
        guard let snapshot else { return .nothing(.empty) }
        return .available(BackupSummary(snapshot: snapshot))
    }

    public func restore(progress: @escaping @Sendable (Double) -> Void) async throws -> CompassSnapshot {
        lock.withLock { cancelled = false }
        guard let snapshot else { throw RestoreError.nothingToRestore }
        for step in 1...5 {
            if lock.withLock({ cancelled }) { throw RestoreError.cancelled }
            progress(Double(step) / 5)
        }
        return snapshot
    }

    public func cancel() { lock.withLock { cancelled = true } }
}

extension Fixtures {
    /// G3: the past goals' own lines ("64 steps · achieved", "38 steps · replaced"), patterned like goal.html.
    public static func pastGoalDays(calendar: Calendar = Fixtures.calendar) -> [Day] {
        let lines: [(Goal, String, Int, Int)] = [
            (pastGoals[0], "110111101110111111011110110111111101111011101111110111101", 64, 31),
            (pastGoals[1], "1100110100111001000110011000101100100011010001100010011", 38, 41),
        ]
        var days: [Day] = []
        for (goal, pattern, steps, part) in lines {
            let marks = Array(pattern)
            var key = DayKey(goal.createdAt, calendar: calendar)
            var moved = 0, i = 0
            while moved < steps {
                var day = Day(key: key, goalID: goal.id)
                let at = { (h: Int) in key.date(in: calendar, hour: h) }
                let partID = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", part))
                if marks[i % marks.count] == "1" {
                    moved += 1
                    let title = goal.parts.first?.symbol == .strength ? "Ran \(3 + i % 8) km" : "Wrote a page"
                    day.step = Step(id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", part * 1000 + i))!,
                                    title: title, partID: partID, createdAt: at(7), completedAt: at(18))
                    day.reflection = Reflection(outcome: .moved, transcript: title, summary: title, duration: 8, partID: partID, createdAt: at(21))
                } else {
                    day.reflection = Reflection(outcome: .notToday, transcript: "Busy.", summary: "Busy.", duration: 4, createdAt: at(21))
                }
                days.append(day)
                key = key.adding(days: 1, calendar: calendar)
                i += 1
            }
        }
        return days
    }

    /// What R1/R2 bring back: the standard goal and history, without past goals ("1 goal").
    public static var restorableSnapshot: CompassSnapshot {
        var s = snapshot(today: nil)
        s.pastGoals = []
        return s
    }
}
