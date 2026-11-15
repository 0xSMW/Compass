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
    /// No goal yet (A flow).
    case onboarding
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

/// Picks the phase from the clock and history. Pure and deterministic.
///
/// Rules (from the v3 map and boards):
/// - No active goal → onboarding.
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
        guard let goal = snapshot.goal, goal.status == .active else { return .onboarding }
        let todayKey = DayKey(now, calendar: calendar)
        let today = snapshot.day(todayKey) ?? Day(key: todayKey, goalID: goal.id)
        let time = TimeOfDay(now, calendar: calendar)
        let rhythm = snapshot.settings.rhythm
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

        let dayNumber = goalDayNumber(goal: goal, today: todayKey)
        let firstWeek = dayNumber <= firstWeekLength
        let planning: MorningPlan.Planning
        if quiet >= 1 {
            planning = .suggestion(partID: quietestPart(goal: goal, snapshot: snapshot, endingBefore: todayKey)?.id, size: .smaller)
        } else if firstWeek {
            planning = .nameYourOwn
        } else {
            planning = .suggestion(partID: quietestPart(goal: goal, snapshot: snapshot, endingBefore: todayKey)?.id, size: .regular)
        }
        let beforeNoon = time < .noon
        let asksWhy = beforeNoon && dayNumber == whyDay && goal.why == nil && !goal.whyAsked
        return .morning(MorningPlan(startsWithCenter: beforeNoon, asksWhy: asksWhy, planning: planning, quietDays: quiet))
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
