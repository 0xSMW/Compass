import SwiftUI
import CompassCore

/// History flow (history.html): E1 this week, E2 a day, E3 earlier weeks, E4 edit a past day,
/// E5 two devices changed the same day, E6 largest text on a day.
/// Marks only: moved = solid dot, missed = half-size grey dot, goal = ringed end marker. No streaks or scores.
enum HistoryScreens {
    /// E1 E2 E3 E4 E5 E6
    static let ids: [ScreenID] = Flow.history.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        switch id {
        case .e1: HistoryWeekView()
        case .e2, .e6: HistoryDayView(id: id)
        case .e3: HistoryWeeksView()
        case .e4: HistoryEditDayView()
        case .e5: HistoryConflictView()
        // ScreenRegistry routes only this flow's IDs here; every one has a case above.
        default: EmptyView()
        }
    }
}

// MARK: - E1 · This week

struct HistoryWeekView: View {
    @Environment(AppModel.self) private var model
    private var selection: HistorySelection { model.historySelection }

    var body: some View {
        let ctx = model.historyContext
        let builder = model.history
        let end = selection.weekEnd ?? ctx.today
        let week = builder.week(ending: end, snapshot: ctx.snapshot, today: ctx.today)
        let isThisWeek = selection.weekEnd == nil || end == ctx.today
        let goal = ctx.snapshot.goal
        let entries = week.entries.reversed().filter { $0.mark != .empty || $0.text != nil }

        FlowScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    CompassText(isThisWeek ? "This week" : builder.label(for: week), style: .title)
                        .accessibilityAddTraits(.isHeader)

                    if let goal, !goal.activeParts.isEmpty {
                        PartTotals(goal: goal, week: week)
                            .padding(.top, Space.s)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        if let goal {
                            GoalTermRow(goal: goal) { model.go(.g1) }
                        }
                        ForEach(entries) { entry in
                            let step = ctx.snapshot.day(entry.key)?.step
                            DayRow(entry: entry, label: HistoryFormat.rowLabel(entry.key, today: model.todayKey, calendar: model.calendar),
                                   stepTitle: step?.isDone == true ? step?.title : nil) {
                                model.openHistoryDay(entry.key)
                            }
                        }
                    }
                    .background(alignment: .topLeading) {
                        // history.html `.vl::before`: 2pt #3A3A3E from the first marker to the last.
                        Rectangle().fill(Color.line2)
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                            .padding(.vertical, 28)
                            .padding(.leading, 15)
                            .accessibilityHidden(true)
                    }
                    .padding(.top, Space.m)

                    LinkButton("Earlier weeks") { model.go(.e3) }
                        .padding(.leading, -12)
                }
                .padding(.horizontal, Space.inset)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .region(.custom(top: 128, bottom: 844, inset: 0))

            NavBar(leading: .quietBack(isThisWeek && selection.goalID == nil ? "Today" : "Weeks") { leave(isThisWeek) }, solid: false)
                .region(.nav)
        }
    }

    private func leave(_ isThisWeek: Bool) {
        if !isThisWeek || selection.goalID != nil { selection.weekEnd = nil }
        if model.canGoBack { model.back() } else { model.goToEntry() }
    }
}

/// "▟ 2   🏃 2   👥 2": moved days this week for each part, heading size. Totals, never a streak.
private struct PartTotals: View {
    let goal: Goal
    let week: HistoryWeek

    var body: some View {
        HStack(spacing: Space.m) {
            ForEach(goal.activeParts) { part in
                let n = week.entries.filter { $0.mark == .moved && $0.partID == part.id }.count
                HStack(spacing: Space.xs) {
                    Icon(CompassIcon(part.symbol), size: IconSize.s)
                    CompassText("\(n)", style: .heading).lineLimit(1).fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(part.title): \(n)")
            }
        }
    }
}

/// history.html `.term`: the goal's ringed end marker with the goal sentence; opens G1.
struct GoalTermRow: View {
    let goal: Goal
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                GoalEndMarker(achieved: goal.status == .achieved)
                CompassText(goal.text, weight: .medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                RowChevron()
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Your goal: open goal options")
    }
}

/// history.html `.dr`: a day on the line (`DayMarkView`, `.line`): label (`.label`, #8A8A90) over what
/// you did. A row is a one-line glance: the evening summary when it fits on one line, else the step
/// you completed (E1: "Dinner with Sam and Priya" for Saturday, whose summary wraps).
private struct DayRow: View {
    let entry: HistoryEntry
    let label: String
    var stepTitle: String? = nil
    let action: () -> Void

    var body: some View {
        let words = entry.text ?? (entry.mark == .missed ? "Missed" : "Not yet")
        let color: Color = entry.mark == .missed ? .ink3 : .ink
        Button(action: action) {
            HStack(spacing: Space.s) {
                DayMarkView(mark: entry.mark, size: .line)
                VStack(alignment: .leading, spacing: 0) {
                    CompassText(label, style: .label, color: .ink3).lineLimit(1)
                    if let stepTitle, stepTitle != words {
                        ViewThatFits(in: .horizontal) {
                            CompassText(words, color: color).lineLimit(1)
                            CompassText(stepTitle, color: color).lineLimit(3)
                        }
                    } else {
                        CompassText(words, color: color).lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, Space.xs)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(entry.mark == .moved ? "moved" : entry.mark == .missed ? "missed" : "open"): \(entry.text ?? "")")
        .accessibilityHint("Opens the day")
    }
}

// MARK: - E3 · Earlier weeks

struct HistoryWeeksView: View {
    @Environment(AppModel.self) private var model
    private var selection: HistorySelection { model.historySelection }

    var body: some View {
        let ctx = model.historyContext
        let builder = model.history
        let weeks = builder.weeks(snapshot: ctx.snapshot, today: ctx.today)

        FlowScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    CompassText(selection.goalID == nil ? "Weeks" : (ctx.snapshot.goal?.text ?? "Weeks"), style: .title)
                        .padding(.bottom, Space.m)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(weeks) { week in
                        WeekRow(label: builder.label(for: week), week: week) {
                            model.openHistoryWeek(endingOn: week.end)
                        }
                    }
                }
                .padding(.horizontal, Space.inset)
                .padding(.bottom, Space.xl)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .region(.custom(top: 128, bottom: 844, inset: 0))

            NavBar(leading: .quietBack(selection.goalID == nil ? "This week" : "Past goals") {
                if model.canGoBack { model.back() } else { model.goToEntry() }
            })
            .region(.nav)
        }
    }
}

/// history.html `.wk`: label (112 wide) · seven 12pt marks · moved count. Empty weeks stay visible.
private struct WeekRow: View {
    let label: String
    let week: HistoryWeek
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                CompassText(label, style: .caption, color: .ink2)
                    .lineLimit(2)
                    .frame(width: 112, alignment: .leading)
                HStack(spacing: Space.xs) {
                    ForEach(Array(week.marks.enumerated()), id: \.offset) { _, mark in
                        DayMarkView(mark: mark, size: .week)
                    }
                }
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                CompassText("\(week.movedCount)", style: .heading).lineLimit(1).fixedSize()
            }
            .frame(minHeight: 56)
            .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): moved on \(week.movedCount) of 7 days")
        .accessibilityHint("Opens the week")
    }
}
