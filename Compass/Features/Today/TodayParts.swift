import SwiftUI
import CompassCore

/// Notes row (kit.css `.note`): wave (spoken) or pen (typed) · latest note · "0:12" or "3 notes".
/// At accessibility sizes the icon grows to 28 and the meta drops so the words get the width (C11).
struct TodayNoteRow: View {
    let note: Note
    var count: Int = 1
    var action: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var typeSize

    private var meta: String? {
        if count > 1 { return "\(count) notes" }
        return note.duration.map { Player.format($0) }
    }

    var body: some View {
        let ax = typeSize.isAccessibilitySize
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Icon(note.isSpoken ? .wave : .pen, size: ax ? IconSize.m : IconSize.s)
                Text(note.text.isEmpty ? "Voice note" : note.text)
                    .compassFont(.caption)
                    .lineLimit(ax ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !ax, let meta {
                    Text(meta).compassFont(.micro).foregroundStyle(.ink3)
                }
            }
            .foregroundStyle(.ink2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(count > 1 ? "Shows today’s \(count) notes" : "")
    }

    private var accessibilityText: String {
        let words = note.text.isEmpty ? "Voice note" : note.text
        if let d = note.duration { return "Voice note, \(Int(d.rounded())) seconds: \(words)" }
        return "Note: \(words)"
    }
}

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
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Color.dim))
                .focused(focus)
                .compassFont(.body)
                .foregroundStyle(.ink)
                .tint(.ink)
                .submitLabel(.done)
                .onSubmit { onSave() }
                .lineLimit(1)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
                .background(Color.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.ink, lineWidth: 1.5))
                .accessibilityLabel(label)
            Button { onSave() } label: {
                Icon(.ok)
                    .foregroundStyle(.ground)
                    .frame(width: ControlSize.secondary, height: ControlSize.secondary)
                    .background(Color.ink, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(saveLabel)
        }
        .frame(height: 56)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

/// Placeholder keyboard for screenshots (kit.css `.keys`): raised block 508–844, 10 columns of 44pt keys.
/// The CI simulator has no software keyboard.
struct TodayKeyboardPlaceholder: View {
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 10), spacing: 12) {
            ForEach(0..<30, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 6).fill(Color.line2).frame(height: 44)
            }
        }
        .padding(.top, Space.xs)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.raised)
        .accessibilityHidden(true)
    }
}

/// C6 · Step options sheet content: Change step · Counts toward: <part> › · Delete step · Cancel (744–792).
struct TodayStepOptions: View {
    let part: GoalPart?
    let onChange: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ListRow(icon: .mic, title: "Change step", showsTopLine: false, action: { onChange() })
            ListRow(icon: part.map { CompassIcon($0.symbol) } ?? .flag,
                    title: part.map { "Counts toward: \($0.title)" } ?? "Counts toward: the whole goal",
                    action: { onMove() }) {
                Icon(.right, size: IconSize.s).foregroundStyle(.ink3)
            }
            .accessibilityHint("Choose the part of your goal this step counts toward")
            ListRow(icon: .trash, title: "Delete step", action: { onDelete() })
            Spacer().frame(height: 20)
            LinkButton("Cancel") { onCancel() }
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// 24 above the rows, 56 per row, Cancel at 744–792, 52 to the bottom edge.
    static func sheetHeight(rows: Int) -> CGFloat { 24 + 56 * CGFloat(rows) + 20 + 48 + 52 }
}

/// C6 · Counts toward: choose a part (same sheet, one level in).
struct TodayPartPicker: View {
    let parts: [GoalPart]
    let selected: UUID?
    let onPick: (UUID) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { i, part in
                ListRow(icon: CompassIcon(part.symbol), title: part.title, showsTopLine: i > 0, action: { onPick(part.id) }) {
                    if part.id == selected { Icon(.ok, size: IconSize.s).foregroundStyle(.ink) }
                }
                .accessibilityAddTraits(part.id == selected ? .isSelected : [])
            }
            Spacer().frame(height: 20)
            LinkButton("Cancel") { onCancel() }
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

/// All of today's notes (tap the notes row when there's more than one). A row opens that note.
struct TodayNotesList: View {
    let notes: [Note]
    var onSelect: (Note) -> Void = { _ in }
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(notes.reversed().enumerated()), id: \.element.id) { i, note in
                        TodayNoteRow(note: note) { onSelect(note) }
                            .frame(minHeight: 56)
                            .overlay(alignment: .top) {
                                if i > 0 { Rectangle().fill(Color.line).frame(height: 1) }
                            }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            Spacer().frame(height: 20)
            LinkButton("Close") { onClose() }
                .frame(maxWidth: .infinity)
        }
    }
}
