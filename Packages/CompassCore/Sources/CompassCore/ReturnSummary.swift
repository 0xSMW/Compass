import Foundation

/// What the return screens say after quiet days (F2, F3): totals only, never a streak.
///
/// F2: "41" · "steps toward this goal" · "Last: Pitched Ridgeline, 9 days ago" · "Hear why you started".
/// F3: "41 steps. The last one was 34 days ago."
public struct ReturnSummary: Hashable, Sendable {
    /// Moved days toward the current goal.
    public var steps: Int
    /// What the last moved day was called (summary, else step title).
    public var lastTitle: String?
    /// Whole days from the last moved day to today.
    public var daysSinceLast: Int?
    /// The recorded "why", if any (B7).
    public var why: Note?

    public init(snapshot: CompassSnapshot, today: DayKey, calendar: Calendar) {
        steps = snapshot.movedCount
        let goalID = snapshot.goal?.id
        let last = snapshot.days
            .filter { $0.key < today && ($0.goalID == nil || $0.goalID == goalID) && $0.moved }
            .max { $0.key < $1.key }
        lastTitle = last.flatMap { day in
            if day.reflection?.outcome == .moved, let text = day.reflection?.displayText, !text.isEmpty { return text }
            return day.step?.title
        }
        daysSinceLast = last.map { $0.key.days(to: today, calendar: calendar) }
        why = snapshot.goal?.why
    }

    static func daysAgo(_ n: Int) -> String {
        switch n {
        case 0: "today"
        case 1: "yesterday"
        default: "\(n) days ago"
        }
    }

    /// F2: "steps toward this goal" / "step toward this goal".
    public var stepsCaption: String { steps == 1 ? "step toward this goal" : "steps toward this goal" }

    /// F2: "Last: Pitched Ridgeline, 9 days ago". nil when nothing has moved yet.
    public var lastLine: String? {
        guard let lastTitle, let daysSinceLast else { return nil }
        var title = lastTitle
        while let l = title.last, ".!?".contains(l) { title.removeLast() }
        return "Last: \(title), \(Self.daysAgo(daysSinceLast))"
    }

    /// F3: "41 steps. The last one was 34 days ago."
    public var checkLine: String {
        let total = "\(steps) \(steps == 1 ? "step" : "steps")."
        guard let daysSinceLast else { return total }
        return total + " The last one was \(Self.daysAgo(daysSinceLast))."
    }
}
