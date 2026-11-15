import SwiftUI
import Observation
import CompassCore

// MARK: - Selection (which day / week / goal History is showing)

/// History's navigation state. `AppModel` only carries the ScreenID stack, so the opened day, week and
/// goal live here. Screenshot runs leave it empty and fall back to the fixture's `selectedDay`.
@MainActor
@Observable
final class HistorySelection {
    static let shared = HistorySelection()

    /// E2/E4/E5/E6: the day that is open.
    var day: DayKey?
    /// E1 opened from E3: the last day of that week. nil = this week.
    var weekEnd: DayKey?
    /// G3 → a past goal's line. nil = the current goal.
    var goalID: UUID?
}

// MARK: - Model helpers

extension AppModel {
    /// The goal History is drawing (a past goal when opened from G3).
    var historyGoal: Goal? {
        if let id = HistorySelection.shared.goalID, let past = snapshot.pastGoals.first(where: { $0.id == id }) { return past }
        return goal
    }

    /// Snapshot as HistoryBuilder should see it: the drawn goal as `goal`, and "today" its last day.
    var historyContext: (snapshot: CompassSnapshot, today: DayKey) {
        guard let g = historyGoal, g.id != goal?.id else { return (snapshot, todayKey) }
        var s = snapshot
        s.goal = g
        s.days = snapshot.days(for: g)
        let end = g.endedAt.map { DayKey($0, calendar: calendar) } ?? todayKey
        return (s, min(end, todayKey))
    }

    /// The open day: History's selection, else the fixture's, else today.
    var historySelectedDay: DayKey {
        HistorySelection.shared.day ?? fixture?.selectedDay ?? todayKey
    }

    func openHistoryDay(_ key: DayKey) {
        HistorySelection.shared.day = key
        let day = snapshot.day(key)
        go(day?.hasConflict == true ? .e5 : .e2)
    }

    func openHistoryWeek(endingOn end: DayKey?) {
        HistorySelection.shared.weekEnd = end
        go(.e1)
    }

    /// E4 Save.
    func saveHistoryEdit(_ key: DayKey, summary: String, moved: Bool, partID: UUID?) {
        let now = self.now, calendar = self.calendar, device = SyncDevice.label
        // CompassCore's rule: unchanged text stays as it was (no "summary" copy of the transcript),
        // and "None" clears the part on the step too.
        updateDay(key) { day in
            HistoryEdit.apply(to: &day, summary: summary, moved: moved, partID: partID, now: now, calendar: calendar, device: device)
        }
    }

    /// E4 "Delete this day’s entry": the evening entry, step and notes for that day, and their audio.
    func deleteHistoryDay(_ key: DayKey) {
        let removed = snapshot.day(key)
        LiveSync.recordDeletion(of: key, at: now)
        if let removed { MemoAudio.deleteFiles(for: removed) }
        mutate { $0.days.removeAll { $0.key == key } }
    }

    /// E5 "Use this summary" / "Keep both".
    func resolveConflict(_ key: DayKey, keeping chosen: Reflection?) {
        let versions = snapshot.day(key)?.reflectionVersions ?? []
        let shown = chosen ?? snapshot.day(key)?.reflection
        // Both recordings are kept: the set-aside version's audio gets its note's file name too.
        MemoAudio.keepRecordings(of: versions.filter { $0.createdAt != shown?.createdAt })
        updateDay(key) { day in
            if let chosen { day.resolveConflict(keeping: chosen) } else { day.keepBothVersions() }
        }
    }
}

// MARK: - Formatting

enum HistoryFormat {
    static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = format
        return f
    }

    /// "Today", "Monday" (this week); "Mon 2 Nov" for older weeks.
    static func rowLabel(_ key: DayKey, today: DayKey, calendar: Calendar) -> String {
        if key == today { return "Today" }
        let date = key.date(in: calendar, hour: 12)
        if key.days(to: today, calendar: calendar) < 7 { return formatter("EEEE", calendar: calendar).string(from: date) }
        return formatter("EEE d MMM", calendar: calendar).string(from: date)
    }

    /// "Saturday, 7 Nov"
    static func dayTitle(_ key: DayKey, calendar: Calendar) -> String {
        formatter("EEEE, d MMM", calendar: calendar).string(from: key.date(in: calendar, hour: 12))
    }

    /// "Saturday"
    static func weekday(_ key: DayKey, calendar: Calendar) -> String {
        formatter("EEEE", calendar: calendar).string(from: key.date(in: calendar, hour: 12))
    }

    /// "21:14" — always 24-hour.
    static func time(_ date: Date, calendar: Calendar) -> String {
        formatter("HH:mm", calendar: calendar).string(from: date)
    }

    /// "14 Apr"
    static func shortDate(_ date: Date, calendar: Calendar) -> String {
        formatter("d MMM", calendar: calendar).string(from: date)
    }

    /// "Jan–Apr 2026", "Sep–Dec 2025", "Nov 2025–Feb 2026"
    static func monthSpan(from start: Date, to end: Date, calendar: Calendar) -> String {
        let m = formatter("MMM", calendar: calendar), my = formatter("MMM yyyy", calendar: calendar)
        let sy = calendar.component(.year, from: start), ey = calendar.component(.year, from: end)
        if sy == ey {
            let a = m.string(from: start), b = m.string(from: end)
            return a == b ? my.string(from: end) : "\(a)–\(b) \(ey)"
        }
        return "\(my.string(from: start))–\(my.string(from: end))"
    }

    static func number(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"]
        return n < words.count ? words[n] : "\(n)"
    }

    /// "seven months", "five weeks", "two years" — no streak language, just time.
    static func span(from start: Date, to end: Date) -> String {
        let days = max(1, Int((end.timeIntervalSince(start) / 86_400).rounded()))
        func unit(_ n: Int, _ word: String) -> String { "\(number(n)) \(word)\(n == 1 ? "" : "s")" }
        if days < 14 { return unit(days, "day") }
        if days < 61 { return unit(Int((Double(days) / 7).rounded()), "week") }
        if days < 548 { return unit(Int((Double(days) / 30.44).rounded()), "month") }
        return unit(Int((Double(days) / 365.25).rounded()), "year")
    }

    static func steps(_ n: Int) -> String { "\(n) \(n == 1 ? "step" : "steps")" }
}

/// history.html `.micro` labels ("Today", "Monday"): Inter Tight 13/16 medium (not the mono micro).
struct HistoryLabelFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dts

    func body(content: Content) -> some View {
        let size = 13 + (17 - 13) * CompassType.progress(dts)
        content.font(.custom("InterTight-Medium", fixedSize: size))
    }
}

extension View {
    func historyLabelFont() -> some View { modifier(HistoryLabelFont()) }
}
