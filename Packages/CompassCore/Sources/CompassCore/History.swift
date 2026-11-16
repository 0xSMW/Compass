import Foundation

/// A History mark. No streaks or scores anywhere: marks only say moved or missed.
public enum DayMark: Hashable, Sendable {
    /// Moved toward the goal: solid dot (12pt in week rows, 16pt on the line).
    case moved
    /// Missed: half-size grey (#6E6E74) dot. A graphic, not text.
    case missed
    /// Not yet resolved (today before the evening) or outside the goal's life: nothing drawn.
    case empty
}

/// One row on the History line (E1 "This week").
public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public var key: DayKey
    public var mark: DayMark
    /// "Texted Sam. Friday dinner is on." / "Sick. Rested." — the summary, step, or reason.
    public var text: String?
    public var partID: UUID?

    public var id: DayKey { key }
}

/// A 7-day block, newest last. Weeks roll back from today ("4–10 Nov", "28 Oct–3 Nov").
public struct HistoryWeek: Identifiable, Hashable, Sendable {
    public var start: DayKey
    public var end: DayKey
    public var entries: [HistoryEntry]

    public var id: DayKey { start }
    public var marks: [DayMark] { entries.map(\.mark) }
    public var movedCount: Int { entries.filter { $0.mark == .moved }.count }
    public var isEmpty: Bool { movedCount == 0 }
}

/// The end marker of a goal's line: a ring, filled when the goal is achieved (G2).
public struct GoalMarker: Hashable, Sendable {
    public var achieved: Bool
    public var totalSteps: Int
}

public struct HistoryBuilder: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public func mark(for key: DayKey, snapshot: CompassSnapshot, today: DayKey) -> DayMark {
        if let goal = snapshot.goal, key < DayKey(goal.createdAt, calendar: calendar) { return .empty }
        if key > today { return .empty }
        let day = snapshot.day(key)
        if day?.moved == true { return .moved }
        if key == today {
            // Today only counts as missed once the evening said "Not today".
            return day?.reflection?.outcome == .notToday ? .missed : .empty
        }
        return .missed
    }

    public func entry(for key: DayKey, snapshot: CompassSnapshot, today: DayKey) -> HistoryEntry {
        let day = snapshot.day(key)
        let text = day?.reflection?.displayText ?? day?.step.flatMap { $0.isDone ? $0.title : nil }
        return HistoryEntry(
            key: key,
            mark: mark(for: key, snapshot: snapshot, today: today),
            text: text,
            partID: day?.reflection?.partID ?? day?.step?.partID
        )
    }

    /// The week ending `today` (E1), oldest first.
    public func thisWeek(snapshot: CompassSnapshot, today: DayKey) -> HistoryWeek {
        week(ending: today, snapshot: snapshot, today: today)
    }

    public func week(ending end: DayKey, snapshot: CompassSnapshot, today: DayKey) -> HistoryWeek {
        let start = end.adding(days: -6, calendar: calendar)
        let entries = (0..<7).map { entry(for: start.adding(days: $0, calendar: calendar), snapshot: snapshot, today: today) }
        return HistoryWeek(start: start, end: end, entries: entries)
    }

    /// Earlier weeks (E3), newest first, back to the week containing the goal's start. Empty weeks stay visible.
    public func weeks(snapshot: CompassSnapshot, today: DayKey, limit: Int = 520) -> [HistoryWeek] {
        let startKey = snapshot.goal.map { DayKey($0.createdAt, calendar: calendar) } ?? today
        var result: [HistoryWeek] = []
        var end = today
        while result.count < limit {
            let w = week(ending: end, snapshot: snapshot, today: today)
            result.append(w)
            if w.start <= startKey { break }
            end = end.adding(days: -7, calendar: calendar)
        }
        return result
    }

    public func goalMarker(snapshot: CompassSnapshot) -> GoalMarker {
        GoalMarker(achieved: snapshot.goal?.status == .achieved, totalSteps: snapshot.movedCount)
    }

    /// "4–10 Nov", "28 Oct–3 Nov", "29 Dec 2025–4 Jan" style label. Month names in `locale`, else the
    /// calendar's (the user's live; en_GB in the fixtures).
    public func label(for week: HistoryWeek, locale: Locale? = nil) -> String {
        let monthFormatter = DateFormatter()
        monthFormatter.calendar = calendar
        monthFormatter.timeZone = calendar.timeZone
        monthFormatter.locale = locale ?? calendar.locale ?? .autoupdatingCurrent
        monthFormatter.dateFormat = "MMM"
        let s = week.start, e = week.end
        let sm = monthFormatter.string(from: s.date(in: calendar, hour: 12))
        let em = monthFormatter.string(from: e.date(in: calendar, hour: 12))
        if s.month == e.month && s.year == e.year {
            return "\(s.day)–\(e.day) \(em)"
        }
        return "\(s.day) \(sm)–\(e.day) \(em)"
    }
}
