import SwiftUI
import CompassCore

/// C10 · the note field that rides on the keyboard: 56 tall pill, 1.5pt ink border, surface fill,
/// with the save circle (ink, check) beside it.
struct TodayNoteField: View {
    @Binding var text: String
    var prompt: String = "Note"
    var label: String = "Note"
    var saveLabel: String = "Save note"
    var focus: FocusState<Bool>.Binding
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            CompassTextEditor(text: $text, prompt: prompt, style: .body, lines: 1...1, focused: focus, label: label,
                              onSubmit: onSave)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
                .background(Color.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.ink, lineWidth: 1.5))
                .contentShape(Capsule())
            CircleButton(.ok, label: saveLabel, style: .fill, action: onSave)
        }
        .frame(height: 56)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

/// C6 · Step options sheet content: Change step · Counts toward: <part> › · Delete step. The sheet adds
/// Cancel on 744–792.
struct TodayStepOptions: View {
    let part: GoalPart?
    let onChange: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ListRow(icon: .mic, title: "Change step", showsTopLine: false, action: { onChange() })
            ListRow(icon: part.map { CompassIcon($0.symbol) } ?? .flag,
                    title: part.map { "Counts toward: \($0.title)" } ?? "Counts toward: the whole goal",
                    action: { onMove() }) {
                RowChevron()
            }
            .accessibilityHint("Choose the part of your goal this step counts toward")
            ListRow(icon: .trash, title: "Delete step", action: { onDelete() })
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// 24 above the rows, 56 per row, 16 to the actions, then Cancel at 744–792 and 52 to the bottom edge.
    static func sheetHeight(rows: Int) -> CGFloat { 24 + 56 * CGFloat(rows) + 16 + 4 + 48 + 52 }
}

/// All of today's notes (tap the notes row when there's more than one), newest first.
struct TodayNotesList: View {
    let notes: [Note]
    /// A row opens that note.
    var onSelect: (Note) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(notes.reversed().enumerated()), id: \.element.id) { i, note in
                NoteRow(note: note) { onSelect(note) }
                    .frame(minHeight: 56)
                    .overlay(alignment: .top) {
                        if i > 0 { Rectangle().fill(Color.line).frame(height: 1) }
                    }
            }
        }
    }
}
