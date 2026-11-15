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
        default: ScreenStub(id: id)
        }
    }
}

// MARK: - G1 · Your goal

struct YourGoalView: View {
    @Environment(AppModel.self) private var model
    @State private var editingGoal = false
    @State private var goalDraft = ""
    @State private var partSheet: PartSheet?
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
                        UnderlineField(prompt: "Where are you going?", text: $goalDraft, style: .title, focused: $goalFocused)
                            .onSubmit(commitGoal)
                    } else {
                        Text(goal?.text ?? "No goal yet.")
                            .compassFont(.title)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                    }
                    if let goal {
                        Text(sinceLine(goal))
                            .compassFont(.caption)
                            .foregroundStyle(.ink3)
                            .padding(.top, Space.xs)
                    }

                    if let goal {
                        VStack(spacing: 0) {
                            ForEach(goal.activeParts) { part in
                                ListRow(icon: CompassIcon(part.symbol), tile: true, title: part.title, action: {
                                    partSheet = PartSheet(id: part.id, isNew: false, title: part.title)
                                }) {
                                    Icon(.right, size: IconSize.s).foregroundStyle(.ink3)
                                }
                                .accessibilityHint("Rename or remove this part")
                            }
                            Button {
                                partSheet = PartSheet(id: UUID(), isNew: true, title: "")
                            } label: {
                                HStack(spacing: Space.s) {
                                    Icon(.plus, size: IconSize.xs)
                                        .foregroundStyle(.ink)
                                        .frame(width: 40, height: 40)
                                        .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                                            .strokeBorder(Color.line2, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                                    Text("Add a part").compassFont(.body).foregroundStyle(.ink)
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
                            ListRow(icon: .swap, title: "Replace with a new goal", action: { model.go(.a2) })
                            ListRow(icon: .arch, title: "Past goals", action: { model.go(.g3) }) {
                                Icon(.right, size: IconSize.s).foregroundStyle(.ink3)
                            }
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
                        }
                        .padding(.top, Space.m)
                    } else {
                        VStack(spacing: 0) {
                            ListRow(icon: .plus, title: "Set a goal", action: { model.go(.a2) })
                            ListRow(icon: .arch, title: "Past goals", action: { model.go(.g3) }) {
                                Icon(.right, size: IconSize.s).foregroundStyle(.ink3)
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
                PartEditor(sheet: sheet, onSave: { title in
                    if sheet.isNew { model.addGoalPart(title: title) } else { model.renameGoalPart(sheet.id, to: title) }
                    partSheet = nil
                }, onRemove: removeAction(for: sheet), onCancel: { partSheet = nil })
            }
        }
        .confirmationDialog("Mark your goal as achieved?", isPresented: $confirmAchieved, titleVisibility: .visible) {
            Button("Mark as achieved") {
                model.markGoalAchieved()
                model.go(.g2)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your line and memos stay. You can set the next goal after.")
        }
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

/// Rename / add / remove a part. Save on the 712 line, Cancel under it.
private struct PartEditor: View {
    let sheet: YourGoalView.PartSheet
    let onSave: (String) -> Void
    let onRemove: (() -> Void)?
    let onCancel: () -> Void
    @State private var title = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.m) {
                Text(sheet.isNew ? "Add a part" : "Edit part").compassFont(.heading).accessibilityAddTraits(.isHeader)
                UnderlineField(prompt: "Stay strong", text: $title, style: .body, axis: .horizontal, focused: $focused)
                    .onSubmit(save)
                if let onRemove {
                    Button(action: onRemove) {
                        Text("Remove part").compassFont(.body).foregroundStyle(.destructive).frame(minHeight: 48)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityHint("Its past steps stay visible")
                }
            }
            .padding(.top, Space.xs)
            Spacer(minLength: Space.s)
            PrimaryButton("Save", action: save)
            LinkButton("Cancel", action: onCancel)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 52)
        }
        .onAppear {
            title = sheet.title
            focused = sheet.isNew
        }
    }

    private func save() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { onCancel() } else { onSave(t) }
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
            Circle().fill(Color.ink).frame(width: 48, height: 48)
                .overlay(Circle().fill(Color.ground).frame(width: 12, height: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .region(.custom(top: 128, bottom: 176))
                .accessibilityLabel("Goal achieved")

            VStack(alignment: .leading, spacing: 0) {
                Text("You arrived.").compassFont(.display).accessibilityAddTraits(.isHeader)
                if let goal {
                    Text("\(HistoryFormat.steps(moved.count)) over \(HistoryFormat.span(from: goal.createdAt, to: end)).")
                        .compassFont(.heading)
                        .foregroundStyle(.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.s)
                }
                VStack(alignment: .leading, spacing: Space.m) {
                    if let first = moved.first { stepBlock("First step", first) }
                    if let last = moved.last, last.key != moved.first?.key { stepBlock("Last step", last) }
                }
                .padding(.top, Space.l)
            }
            .region(.focal)

            ButtonDock(primary: "Set the next goal", link: "Later", onPrimary: { model.go(.a2) }, onLink: {
                model.reset(to: ScreenID.entry(for: .today, today: model.today))
            })
        }
    }

    private func stepBlock(_ title: String, _ day: Day) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(HistoryFormat.shortDate(day.key.date(in: model.calendar, hour: 12), calendar: model.calendar))")
                .compassFont(.caption)
                .foregroundStyle(.ink3)
            Text(day.step.flatMap { $0.isDone ? $0.title : nil } ?? day.reflection?.displayText ?? "")
                .compassFont(.heading)
                .fixedSize(horizontal: false, vertical: true)
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
                    Text("Past goals").compassFont(.title).accessibilityAddTraits(.isHeader)
                    if model.snapshot.pastGoals.isEmpty {
                        Text("Goals you finish or replace stay here, each with its full line and memos.")
                            .compassFont(.body)
                            .foregroundStyle(.ink2)
                            .padding(.top, Space.s)
                    }
                    VStack(spacing: Space.s) {
                        ForEach(model.snapshot.pastGoals) { goal in
                            PastGoalCard(goal: goal) {
                                HistorySelection.shared.goalID = goal.id
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
                HistorySelection.shared.goalID = nil
                model.back()
            })
            .region(.nav)
        }
        .onAppear { HistorySelection.shared.goalID = nil }
    }
}

/// goal.html `.gcard`: goal sentence, "Jan–Apr 2026 · 64 steps · achieved", and its line as 6pt dots
/// (one per day of the goal's life: ink = moved, #3A3A3E = not).
private struct PastGoalCard: View {
    @Environment(AppModel.self) private var model
    let goal: Goal
    let action: () -> Void

    var body: some View {
        let days = model.snapshot.days(for: goal)
        let movedKeys = Set(days.filter(\.moved).map(\.key))
        let marks = lineMarks(movedKeys: movedKeys)
        let end = goal.endedAt ?? model.now
        let caption = "\(HistoryFormat.monthSpan(from: goal.createdAt, to: end, calendar: model.calendar)) · \(HistoryFormat.steps(movedKeys.count)) · \(goal.status == .achieved ? "achieved" : "replaced")"

        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(goal.text).compassFont(.heading).foregroundStyle(.ink).fixedSize(horizontal: false, vertical: true)
                Text(caption).compassFont(.caption).foregroundStyle(.ink3)
                if !marks.isEmpty {
                    DotWrap(marks: marks)
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

    private func lineMarks(movedKeys: Set<DayKey>) -> [Bool] {
        guard !movedKeys.isEmpty else { return [] }
        let cal = model.calendar
        let start = DayKey(goal.createdAt, calendar: cal)
        let end = DayKey(goal.endedAt ?? model.now, calendar: cal)
        let count = max(0, min(730, start.days(to: end, calendar: cal) + 1))
        return (0..<count).map { movedKeys.contains(start.adding(days: $0, calendar: cal)) }
    }
}

/// goal.html `.mdots`: 6pt dots, 4pt gap, wrapping.
private struct DotWrap: View {
    let marks: [Bool]

    var body: some View {
        WrapLayout(spacing: 4, lineSpacing: 4) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, moved in
                Circle().fill(moved ? Color.ink : Color.line2).frame(width: 6, height: 6)
            }
        }
    }
}

/// Simple flow layout for equal-size marks.
private struct WrapLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += lineHeight + lineSpacing; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
