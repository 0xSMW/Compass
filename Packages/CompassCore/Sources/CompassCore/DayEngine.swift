import Foundation

/// How the morning ritual should run today.
public struct MorningPlan: Hashable, Sendable {
    public enum Planning: Hashable, Sendable {
        /// First week: no history yet, so you name the step (B4).
        case nameYourOwn
        /// The quietest part of the goal gets the idea (B3). `size` is `.smaller` after 1–2 quiet days (F1).
        case suggestion(partID: UUID?, size: StepSize)
    }

    /// Center (B1) with breathing rings. False when opened after noon (B6).
    public var startsWithCenter: Bool
    /// Day 3: "Why does this matter to you?" (B7), asked once.
    public var asksWhy: Bool
    public var planning: Planning
    /// Quiet days before today (0 when yesterday had activity).
    public var quietDays: Int

    public init(startsWithCenter: Bool, asksWhy: Bool, planning: Planning, quietDays: Int) {
        self.startsWithCenter = startsWithCenter
        self.asksWhy = asksWhy
        self.planning = planning
        self.quietDays = quietDays
    }
}

public enum EveningKind: Hashable, Sendable {
    /// D1: "Did you do it?" Done / Not today.
    case stepOpen
    /// D2: goal is the subject, "Did you move toward it today?"
    case noStep
    /// D2b: already completed today, so only "Anything to add?"
    case doneEarlier
}

/// What the app should show when opened at a given moment.
public enum DayPhase: Hashable, Sendable {
    /// No goal and no history yet (A flow).
    case onboarding
    /// The goal was achieved (or ended) and the next one isn't set yet. History stays: Today's frame
    /// with "Set the next goal" on the card; History, Settings and Export stay reachable. No rituals.
    case goalEnded
    /// Morning ritual, or the afternoon start (B6) when opened after noon with nothing planned.
    case morning(MorningPlan)
    /// Today screen (C flow).
    case today
    /// After the evening time (21:00 by default) and not yet reflected.
    case evening(EveningKind)
    /// F2: 3–29 quiet days. What you've done, your own reason, one way back.
    case returning(quietDays: Int)
    /// F3: 30+ quiet days. Keep, revise or replace.
    case checkGoal(quietDays: Int)
}

extension DayEngine {
    /// Whether two phases put the same screen up: the same case, ignoring the morning's plan details
    /// and the quiet-day counts (those follow from other days' data, not from today moving on). A
    /// different evening question (the step was done elsewhere) counts as a change. Used to decide
    /// whether a merge from another device re-judges the screen (F2).
    public static func sameStage(_ a: DayPhase, _ b: DayPhase) -> Bool {
        switch (a, b) {
        case (.morning, .morning), (.returning, .returning), (.checkGoal, .checkGoal): return true
        default: return a == b
        }
    }
}

/// Picks the phase from the clock and history. Pure and deterministic.
///
/// Rules (from the v3 map and boards):
/// - No goal and no history → onboarding (A1). A goal that was achieved or ended, or history without a
///   goal → goalEnded (Today's frame with "Set the next goal"), never Welcome.
/// - Quiet days (no activity) before today, counted only while today has no activity yet:
///   30+ → checkGoal (F3), 3–29 → returning (F2), 1–2 → a smaller suggested step (F1).
/// - At or after the evening time (21:00) and no reflection today → evening:
///   step done → doneEarlier (D2b), step open → stepOpen (D1), no step → noStep (D2).
/// - Before noon with the morning not handled → morning with Center (B1). First week (days 1–7 of the
///   goal) names its own step (B4); day 3 also asks why (B7) if not asked yet.
/// - Noon to the evening time with the morning not handled → morning without Center (B6).
/// - Otherwise → today.
public struct DayEngine: Sendable {
    public var calendar: Calendar
    public var firstWeekLength: Int = 7
    public var whyDay: Int = 3

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    public func phase(at now: Date, snapshot: CompassSnapshot) -> DayPhase {
        guard let goal = snapshot.goal, goal.status == .active else {
            return snapshot.hasHistory ? .goalEnded : .onboarding
        }
        let todayKey = DayKey(now, calendar: calendar)
        let today = snapshot.day(todayKey) ?? Day(key: todayKey, goalID: goal.id)
        let time = TimeOfDay(now, calendar: calendar)
        let rhythm = snapshot.settings.rhythm.clamped
        let quiet = quietDays(before: todayKey, snapshot: snapshot)

        if !today.hasActivity {
            if quiet >= 30 { return .checkGoal(quietDays: quiet) }
            if quiet >= 3 { return .returning(quietDays: quiet) }
        }

        if time >= rhythm.evening {
            if today.reflection != nil { return .today }
            if let step = today.step {
                return .evening(step.isDone ? .doneEarlier : .stepOpen)
            }
            return .evening(.noStep)
        }

        if today.morningHandled { return .today }
        return .morning(morningPlan(goal: goal, today: todayKey, time: time, quietDays: quiet, snapshot: snapshot))
    }

    /// How today's morning plans: the one place the planning rules live. `phase` uses it while the
    /// morning is open; the ritual keeps using it (`morningPlan(at:snapshot:)`) after the intention is
    /// saved, which already counts as handled.
    /// - 1–2 quiet days → a smaller suggestion for the quietest part (F1).
    /// - First week (days 1–7) → name your own step (B4).
    /// - Otherwise → a regular suggestion for the quietest part (B3).
    /// - Before noon starts with Center (B1); day 3 asks why once (B7).
    func morningPlan(goal: Goal, today todayKey: DayKey, time: TimeOfDay, quietDays quiet: Int, snapshot: CompassSnapshot) -> MorningPlan {
        let dayNumber = goalDayNumber(goal: goal, today: todayKey)
        let quietest = { quietestPart(goal: goal, snapshot: snapshot, endingBefore: todayKey)?.id }
        let planning: MorningPlan.Planning
        if quiet >= 1 {
            planning = .suggestion(partID: quietest(), size: .smaller)
        } else if dayNumber <= firstWeekLength {
            planning = .nameYourOwn
        } else {
            planning = .suggestion(partID: quietest(), size: .regular)
        }
        let beforeNoon = time < .noon
        let asksWhy = beforeNoon && dayNumber == whyDay && goal.why == nil && !goal.whyAsked
        return MorningPlan(startsWithCenter: beforeNoon, asksWhy: asksWhy, planning: planning, quietDays: quiet)
    }

    /// 1-based day of the goal: the creation day is day 1.
    public func goalDayNumber(goal: Goal, today: DayKey) -> Int {
        DayKey(goal.createdAt, calendar: calendar).days(to: today, calendar: calendar) + 1
    }

    /// Consecutive days without activity immediately before `today`, bounded by the goal's start.
    public func quietDays(before today: DayKey, snapshot: CompassSnapshot) -> Int {
        guard let goal = snapshot.goal else { return 0 }
        let start = DayKey(goal.createdAt, calendar: calendar)
        let active = snapshot.days
            .filter { $0.key < today && $0.key >= start && $0.hasActivity }
            .map(\.key)
            .max()
        let anchor = active ?? start
        let gap = anchor.days(to: today, calendar: calendar) - 1
        // If nothing happened since the start day itself, the start day counts as active (onboarding happened).
        return max(0, gap)
    }

    /// The part with the fewest moved days in the 7 days before `endingBefore`. Ties keep goal order.
    public func quietestPart(goal: Goal, snapshot: CompassSnapshot, endingBefore today: DayKey) -> GoalPart? {
        let parts = goal.activeParts
        guard !parts.isEmpty else { return nil }
        let window = (1...7).map { today.adding(days: -$0, calendar: calendar) }
        var counts: [UUID: Int] = [:]
        for key in window {
            guard let day = snapshot.day(key), day.moved else { continue }
            if let pid = day.step?.partID ?? day.reflection?.partID { counts[pid, default: 0] += 1 }
        }
        return parts.min { (counts[$0.id] ?? 0) < (counts[$1.id] ?? 0) }
    }

    /// Moved days for a part in the 7 days ending today ("Keep close friends · 1 step this week").
    public func stepsThisWeek(partID: UUID, snapshot: CompassSnapshot, today: DayKey) -> Int {
        (0..<7).map { today.adding(days: -$0, calendar: calendar) }.filter { key in
            guard let d = snapshot.day(key), d.moved else { return false }
            return (d.step?.partID ?? d.reflection?.partID) == partID
        }.count
    }
}
