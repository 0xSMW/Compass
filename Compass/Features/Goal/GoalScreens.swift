import SwiftUI
import CompassCore

/// Goal changes (goal.html): G1 your goal, G2 achieved, G3 past goals. Every change keeps history;
/// removing a part archives it and its past steps stay visible.
enum GoalScreens {
    /// G1 G2 G3
    static let ids: [ScreenID] = Flow.goal.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        switch id {
        case .g1: YourGoalView()
        case .g2: GoalAchievedView()
        case .g3: PastGoalsView()
        // ScreenRegistry routes only this flow's IDs here; every one has a case above.
        default: EmptyView()
        }
    }
}

// MARK: - G1 · Your goal

struct YourGoalView: View {
    @Environment(AppModel.self) private var model
    @State private var editingGoal = false
    @State private var goalDraft = ""
    @State private var partSheet: PartSheet?
    @State private var partTitle = ""
    @State private var confirmAchieved = false
    @FocusState private var goalFocused: Bool

    struct PartSheet: Identifiable {
        var id: UUID
        var isNew: Bool
        var title: String
    }

    var body: some View {
        let goal = model.goal
        FlowScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if editingGoal {
                        UnderlineField(prompt: "Where are you going?", text: $goalDraft, style: .title, focused: $goalFocused,
                                       label: "Your goal", onSubmit: commitGoal)
                    } else {
                        CompassText(goal?.text ?? "No goal yet.", style: .title)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let goal {
                        CompassText(sinceLine(goal), style: .caption, color: .ink3)
                            .padding(.top, Space.xs)
                    }

                    if let goal {
                        VStack(spacing: 0) {
                            ForEach(goal.activeParts) { part in
                                ListRow(icon: CompassIcon(part.symbol), tile: true, title: part.title, action: {
                                    openPart(PartSheet(id: part.id, isNew: false, title: part.title))
                                }) {
                                    RowChevron()
                                }
                                .accessibilityHint("Rename or remove this part")
                            }
                            Button {
                                openPart(PartSheet(id: UUID(), isNew: true, title: ""))
                            } label: {
                                HStack(spacing: Space.s) {
                                    Icon(.plus, size: IconSize.xs)
                                        .foregroundStyle(.ink)
                                        .frame(width: 40, height: 40)
                                        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                            .strokeBorder(Color.line2, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                                    CompassText("Add a part")
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: 56)
                                .overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel("Add a part")
                        }
                        .padding(.top, Space.m)

                        VStack(spacing: 0) {
                            if goal.status == .active {
                                ListRow(icon: .flag, title: "Mark as achieved", action: { confirmAchieved = true })
                            } else {
                                ListRow(icon: .flag, title: "Achieved", value: goal.endedAt.map { HistoryFormat.shortDate($0, calendar: model.calendar) },
                                        action: { model.go(.g2) })
                            }
                            ListRow(icon: .swap, title: goal.status == .active ? "Replace with a new goal" : "Set the next goal",
                                    action: { model.startNewGoal() })
                            ListRow(icon: .arch, title: "Past goals", action: { model.go(.g3) }) {
                                RowChevron()
                            }
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
                        }
                        .padding(.top, Space.m)
                    } else {
                        VStack(spacing: 0) {
                            ListRow(icon: .plus, title: "Set a goal", action: { model.startNewGoal() })
                            ListRow(icon: .arch, title: "Past goals", action: { model.go(.g3) }) {
                                RowChevron()
                            }
                        }
                        .padding(.top, Space.m)
                    }
                }
                .padding(.horizontal, Space.inset)
                .padding(.bottom, Space.xl)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .region(.custom(top: 128, bottom: 844, inset: 0))

            NavBar(
                leading: .quietBack("Back") { model.back() },
                trailing: trailingItem
            )
            .region(.nav)
        }
        .compassSheet(isPresented: Binding(get: { partSheet != nil }, set: { if !$0 { partSheet = nil } }), height: 392,
                      label: partSheet?.isNew == true ? "Add a part" : "Edit part") {
            if let sheet = partSheet {
                PartEditor(sheet: sheet, title: $partTitle, onRemove: removeAction(for: sheet), onSubmit: savePart)
            }
        } actions: {
            PrimaryButton("Save", action: savePart)
        }
        .confirmSheet(isPresented: $confirmAchieved, title: "Mark your goal as achieved?",
                      message: "Your line and memos stay. You can set the next goal after.", confirm: "Mark as achieved") {
            model.markGoalAchieved()
            model.go(.g2)
        }
    }

    private func openPart(_ sheet: PartSheet) {
        partTitle = sheet.title
        partSheet = sheet
    }

    /// Save on 712: rename, or add; an empty name just closes.
    private func savePart() {
        guard let sheet = partSheet else { return }
        let title = partTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            if sheet.isNew { model.addGoalPart(title: title) } else { model.renameGoalPart(sheet.id, to: title) }
        }
        partSheet = nil
    }

    private func removeAction(for sheet: PartSheet) -> (() -> Void)? {
        guard !sheet.isNew else { return nil }
        return {
            model.archiveGoalPart(sheet.id)
            partSheet = nil
        }
    }

    private var trailingItem: NavItem? {
        guard model.goal != nil else { return nil }
        if editingGoal { return NavItem.text("Done", quiet: false, action: commitGoal) }
        return NavItem.text("Edit", quiet: false, action: startEditing)
    }

    private func sinceLine(_ goal: Goal) -> String {
        let cal = model.calendar
        let sameYear = cal.component(.year, from: goal.createdAt) == cal.component(.year, from: model.now)
        let since = HistoryFormat.formatter(sameYear ? "d MMM" : "d MMM yyyy", calendar: cal).string(from: goal.createdAt)
        return "Since \(since) · \(HistoryFormat.steps(model.snapshot.steps(for: goal)))"
    }

    private func startEditing() {
        goalDraft = model.goal?.text ?? ""
        editingGoal = true
        goalFocused = true
    }

    private func commitGoal() {
        let text = goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { model.updateGoalText(text) }
        editingGoal = false
        goalFocused = false
    }
}

/// Rename / add / remove a part: the sheet's content. Save sits on the 712 line, Cancel under it.
private struct PartEditor: View {
    let sheet: YourGoalView.PartSheet
    @Binding var title: String
    let onRemove: (() -> Void)?
    let onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            CompassText(sheet.isNew ? "Add a part" : "Edit part", style: .heading).accessibilityAddTraits(.isHeader)
            UnderlineField(prompt: "Stay strong", text: $title, style: .body, lines: 1...1, focused: $focused,
                           label: "Part name", onSubmit: onSubmit)
            if let onRemove {
                LinkButton("Remove part", tone: .destructive, padding: 0, action: onRemove)
                    .accessibilityHint("Its past steps stay visible")
            }
        }
        .onAppear { focused = sheet.isNew }
    }
}

// MARK: - G2 · Achieved

struct GoalAchievedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let goal = model.goal ?? model.snapshot.pastGoals.first
        let moved = goal.map { g in model.snapshot.days(for: g).filter(\.moved) } ?? []
        let end = goal?.endedAt ?? model.now

        FlowScreen {
            // The end marker, filled (48pt ink disc with a ground centre).
            GoalEndMarker(achieved: true, size: 48)
                .frame(maxWidth: .infinity, alignment: .leading)
                .region(.custom(top: 128, bottom: 176))

            VStack(alignment: .leading, spacing: 0) {
                CompassText("You arrived.", style: .display).accessibilityAddTraits(.isHeader)
                if let goal {
                    CompassText("\(HistoryFormat.steps(moved.count)) over \(HistoryFormat.span(from: goal.createdAt, to: end)).",
                                style: .heading, color: .ink2)
                        .padding(.top, Space.s)
                }
                VStack(alignment: .leading, spacing: Space.m) {
                    if let first = moved.first { stepBlock("First step", first) }
                    if let last = moved.last, last.key != moved.first?.key { stepBlock("Last step", last) }
                }
                .padding(.top, Space.l)
            }
            .scrollingRegion(.custom(top: 224, bottom: 668))

            // "Later" keeps the Today frame (DayPhase.goalEnded): History, Settings and Export stay
            // reachable, and Today's card offers "Set the next goal".
            ButtonDock(primary: "Set the next goal", link: "Later", onPrimary: { model.startNewGoal() }, onLink: {
                model.goToEntry()
            })
        }
    }

    private func stepBlock(_ title: String, _ day: Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CompassText("\(title) · \(HistoryFormat.shortDate(day.key.date(in: model.calendar, hour: 12), calendar: model.calendar))",
                        style: .caption, color: .ink3)
            CompassText(day.step.flatMap { $0.isDone ? $0.title : nil } ?? day.reflection?.displayText ?? "", style: .heading)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - G3 · Past goals

struct PastGoalsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FlowScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    CompassText("Past goals", style: .title).accessibilityAddTraits(.isHeader)
                    if model.snapshot.pastGoals.isEmpty {
                        CompassText("Goals you finish or replace stay here, each with its full line and memos.", color: .ink2)
                            .padding(.top, Space.s)
                    }
                    VStack(spacing: Space.s) {
                        ForEach(model.snapshot.pastGoals) { goal in
                            PastGoalCard(goal: goal) {
                                model.historySelection.goalID = goal.id
                                model.go(.e3)
                            }
                        }
                    }
                    .padding(.top, Space.m)
                }
                .padding(.horizontal, Space.inset)
                .padding(.bottom, Space.xl)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .region(.custom(top: 128, bottom: 844, inset: 0))

            NavBar(leading: .quietBack("Back") {
                model.historySelection.goalID = nil
                model.back()
            })
            .region(.nav)
        }
        .onAppear { model.historySelection.goalID = nil }
    }
}

/// goal.html `.gcard`: goal sentence, "Jan–Apr 2026 · 64 steps · achieved", and its line as 6pt dots
/// (one per evening answered: ink = moved, #3A3A3E = not), up to two rows of the most recent; the card
/// opens the whole line.
private struct PastGoalCard: View {
    @Environment(AppModel.self) private var model
    let goal: Goal
    let action: () -> Void

    var body: some View {
        let days = model.snapshot.days(for: goal)
        let movedKeys = Set(days.filter(\.moved).map(\.key))
        // goal.html `.mdots`: one dot per evening answered, ink when it moved, dim when not.
        let marks = days.filter { $0.reflection != nil }.map(\.moved)
        let end = goal.endedAt ?? model.now
        let caption = "\(HistoryFormat.monthSpan(from: goal.createdAt, to: end, calendar: model.calendar)) · \(HistoryFormat.steps(movedKeys.count)) · \(goal.status == .achieved ? "achieved" : "replaced")"

        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.xs) {
                CompassText(goal.text, style: .heading)
                CompassText(caption, style: .caption, color: .ink3)
                if !marks.isEmpty {
                    DotLine(marks: marks)
                        .padding(.top, Space.xs)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.m)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .multilineTextAlignment(.leading)
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(goal.text) \(caption)")
        .accessibilityHint("Opens its weeks")
    }
}

/// goal.html `.mdots`: 6pt dots, 4pt gap, wrapping, at most two rows (the most recent marks that fit,
/// oldest first): 29 to a row on the 294pt card.
private struct DotLine: View {
    let marks: [Bool]
    var rows: Int = 2

    private let dot: CGFloat = 6
    private let gap: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let perRow = max(1, Int((geo.size.width + gap) / (dot + gap)))
            let shown = Array(marks.suffix(perRow * rows))
            VStack(alignment: .leading, spacing: gap) {
                ForEach(0..<Int((Double(shown.count) / Double(perRow)).rounded(.up)), id: \.self) { row in
                    HStack(spacing: gap) {
                        ForEach(Array(shown[(row * perRow)..<min(shown.count, (row + 1) * perRow)].enumerated()), id: \.offset) { _, moved in
                            Circle().fill(moved ? Color.ink : Color.line2).frame(width: dot, height: dot)
                        }
                    }
                }
            }
        }
        .frame(height: dot * CGFloat(rows) + gap * CGFloat(rows - 1))
    }
}
