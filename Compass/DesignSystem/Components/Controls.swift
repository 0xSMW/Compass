import SwiftUI
import UIKit
import CompassCore

/// kit.css `.note` — a note row: wave (spoken) or pen (typed) · text (caption, #A1A1A6) · mono meta
/// ("0:12", or "3 notes" when it stands for several). At accessibility sizes the icon grows to 28 and the
/// meta drops so the words get the width (C11). Today's notes row, the notes sheet and History days.
struct NoteRow: View {
    let text: String
    var spoken: Bool = false
    var meta: String? = nil
    var spokenLabel: String
    var hint: String = ""
    var action: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var typeSize

    init(text: String, spoken: Bool = false, meta: String? = nil, spokenLabel: String? = nil, hint: String = "",
         action: @escaping () -> Void = {}) {
        self.text = text
        self.spoken = spoken
        self.meta = meta
        self.spokenLabel = spokenLabel ?? (spoken ? "Voice note: \(text)" : "Note: \(text)")
        self.hint = hint
        self.action = action
    }

    /// A day's note: "Voice note" when nothing was transcribed; `count > 1` shows "3 notes".
    init(note: Note, count: Int = 1, action: @escaping () -> Void = {}) {
        let words = note.text.isEmpty ? "Voice note" : note.text
        let label = note.duration.map { "Voice note, \(Int($0.rounded())) seconds: \(words)" } ?? "Note: \(words)"
        self.init(text: words, spoken: note.isSpoken,
                  meta: count > 1 ? "\(count) notes" : note.duration.map { Player.format($0) },
                  spokenLabel: label, hint: count > 1 ? "Shows today’s \(count) notes" : "", action: action)
    }

    var body: some View {
        let ax = typeSize.isAccessibilitySize
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Icon(spoken ? .wave : .pen, size: ax ? IconSize.m : IconSize.s)
                CompassText(text, style: .caption, color: .ink2)
                    .lineLimit(ax ? 3 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !ax, let meta {
                    CompassText(meta, style: .micro, color: .ink3).lineLimit(1).fixedSize()
                }
            }
            .foregroundStyle(.ink2)
            .frame(minHeight: ControlSize.minTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(hint)
    }
}

/// kit.css `.chip` — 44 tall, outlined, symbol + label + optional chevron: "Keep close friends ⌄" (part
/// picker), "Hear why you started" (F2, ink), or a plain label (E2, no action). At accessibility sizes the
/// chip grows to fit, the symbol is 28 and the chevron goes (D8).
struct Chip: View {
    let title: String
    var icon: CompassIcon? = nil
    /// Symbol colour; the label's colour when nil. Part chips draw the symbol in ink.
    var iconTint: Color? = nil
    var trailing: CompassIcon? = nil
    var accessibilityLabel: String? = nil
    /// Label colour: #A1A1A6, or ink for a chip that is the screen's one action (F2 "Hear why you started").
    var tint: Color = .ink2
    var action: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        if let action {
            Button(action: action) { face }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(accessibilityLabel ?? title)
        } else {
            face
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel ?? title)
        }
    }

    private var face: some View {
        let ax = dts.isAccessibilitySize
        return HStack(spacing: Space.xs) {
            if let icon { Icon(icon, size: ax ? IconSize.m : IconSize.s).foregroundStyle(iconTint ?? tint) }
            CompassText(title, style: .caption, color: tint)
                .lineLimit(ax ? nil : 1)
                .fixedSize(horizontal: !ax, vertical: true)
            if let trailing, !ax { Icon(trailing, size: IconSize.xs).foregroundStyle(tint) }
        }
        // CSS padding 0 16 0 12 sits inside the 1pt border.
        .padding(.leading, 13)
        .padding(.trailing, Space.s + 1)
        // At AX the chip is `height: auto; padding: 8` inside its 1pt border (46 for one line, D8/E6).
        .padding(.vertical, ax ? Space.xs + 1 : 0)
        .frame(minHeight: ControlSize.minTarget)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// kit.css `.tile` — 40pt rounded (12) surface square with a 20pt (`svg.s`) ink icon (A5, G1 parts).
struct Tile: View {
    let icon: CompassIcon

    var body: some View {
        Icon(icon, size: IconSize.s)
            .foregroundStyle(.ink)
            .frame(width: 40, height: 40)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

/// kit.css `.lr` — list row: min 56, top hairline, optional leading icon/tile, title, trailing value
/// (#A1A1A6, or mono for times) and accessory.
struct ListRow<Accessory: View>: View {
    var icon: CompassIcon? = nil
    var tile: Bool = false
    let title: String
    var value: String? = nil
    var valueStyle: CompassType = .body
    var showsTopLine: Bool = true
    var lineColor: Color = .line
    var tint: Color = .ink
    var action: (() -> Void)? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let row = HStack(spacing: Space.s) {
            if let icon {
                if tile { Tile(icon: icon) } else { Icon(icon).foregroundStyle(tint) }
            }
            CompassText(title, color: tint).frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                CompassText(value, style: valueStyle, color: .ink2).lineLimit(1).fixedSize()
            }
            accessory
        }
        .frame(minHeight: 56)
        .overlay(alignment: .top) {
            if showsTopLine { Rectangle().fill(lineColor).frame(height: 1) }
        }
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { row }
                .buttonStyle(PressableStyle())
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
        } else {
            row.accessibilityElement(children: .combine)
        }
    }
}

extension ListRow where Accessory == EmptyView {
    init(icon: CompassIcon? = nil, tile: Bool = false, title: String, value: String? = nil, valueStyle: CompassType = .body,
         showsTopLine: Bool = true, lineColor: Color = .line, tint: Color = .ink, action: (() -> Void)? = nil) {
        self.init(icon: icon, tile: tile, title: title, value: value, valueStyle: valueStyle, showsTopLine: showsTopLine,
                  lineColor: lineColor, tint: tint, action: action, accessory: { EmptyView() })
    }
}

/// onboarding.html A6 `.lr` (min 72): symbol · title · time (`.time`, Plex Mono 28/32) · − / + (`.ic44`,
/// 16pt glyphs). The one way to set a time: A6 rhythm and the Settings time sheet.
struct TimeStepperRow: View {
    var icon: CompassIcon? = nil
    let title: String
    let time: TimeOfDay
    var showsTopLine: Bool = true
    let earlier: () -> Void
    let later: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            if let icon { Icon(icon).foregroundStyle(.ink) }
            CompassText(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            CompassText(time.description, style: .time)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
                .accessibilityLabel("\(title) at \(time.description)")
            IconButton(.minus, label: "\(title) earlier", iconSize: IconSize.xs, action: earlier)
            IconButton(.plus, label: "\(title) later", iconSize: IconSize.xs, action: later)
        }
        .frame(minHeight: 72)
        .overlay(alignment: .top) {
            if showsTopLine { Rectangle().fill(Color.line).frame(height: 1) }
        }
    }
}

/// A row's trailing chevron (`svg.s.ink3`): › opens something, ⌄ changes something in place.
struct RowChevron: View {
    var icon: CompassIcon = .right
    var body: some View { Icon(icon, size: IconSize.s).foregroundStyle(.ink3) }
}

/// kit.css `.sw` — 52×32 switch. On: ink track, ground knob right. Off: #3A3A3E track, #A1A1A6 knob left.
struct CompassSwitch: View {
    let label: String
    @Binding var isOn: Bool

    @Environment(\.motionReduced) private var reduced

    var body: some View {
        Button {
            withAnimation(Motion.animation(0.2, reduced: reduced)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color.ink : Color.line2)
                Circle().fill(isOn ? Color.ground : Color.ink2).frame(width: 26, height: 26).padding(3)
            }
            .frame(width: 52, height: 32)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// kit.css `.field` — underline field: no box, 1.5pt #3A3A3E underline (ink when focused), 16pt below text.
/// Typed text goes where spoken words would appear, in the same type style and line boxes.
struct UnderlineField: View {
    let prompt: String
    @Binding var text: String
    var style: CompassType = .title
    /// Visible lines: `1...1` is a one-line field (Return submits); beyond the upper bound it scrolls.
    var lines: ClosedRange<Int> = 1...6
    var focused: FocusState<Bool>.Binding? = nil
    /// Draw the focused underline without real focus (screenshots of keyboard states).
    var showsFocus: Bool = false
    var label: String? = nil
    var returnKey: UIReturnKeyType = .done
    var onSubmit: (() -> Void)? = nil

    @FocusState private var internalFocus: Bool

    var body: some View {
        let isFocused = showsFocus || (focused?.wrappedValue ?? internalFocus)
        VStack(alignment: .leading, spacing: Space.s) {
            CompassTextEditor(text: $text, prompt: prompt, style: style, lines: lines, focused: focused ?? $internalFocus,
                              label: label ?? prompt, returnKey: returnKey, onSubmit: onSubmit)
            Rectangle().fill(isFocused ? Color.ink : Color.line2).frame(height: 1.5)
        }
    }
}

/// history.html E4 textarea: a boxed field (ground fill, 1pt #3A3A3E border, radius 12, 12/16 padding
/// inside the border: two lines are 74pt like the board).
struct BoxedField: View {
    let prompt: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 2...4
    var label: String
    var focused: FocusState<Bool>.Binding? = nil

    var body: some View {
        CompassTextEditor(text: $text, prompt: prompt, style: .body, lines: lines, focused: focused, label: label)
            .padding(.horizontal, Space.s + 1)
            .padding(.vertical, 13)
            .background(Color.ground, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).strokeBorder(Color.line2, lineWidth: 1))
    }
}

/// One action link in a notice (kit.css `.lnk.ink`, body 500): 44pt tall, at least 44 wide to the touch.
struct NoticeAction {
    var title: String
    var label: String? = nil
    var action: () -> Void
}

/// kit.css `.notice` — surface card, radius 24, icon (`svg.s`, #A1A1A6) + #D6D6D8 caption text.
/// - `.inline`: actions sit on the text's row, right (D6 "Try now", I2 "Turn on" + ×).
/// - `.stacked`: actions on a row under the text, aligned with it (I3 "OK · Keep Bangkok time",
///   D6b "Try again · Type a summary", Today's "Turn on the microphone").
/// Notices take the notes row above the Today card (I2, I3) or the slot above the dock (I1, I4, D6).
struct Notice: View {
    enum Layout { case inline, stacked }

    var icon: CompassIcon? = nil
    let text: String
    var actions: [NoticeAction] = []
    var layout: Layout = .stacked
    /// Gap between stacked action labels (I3 24, D6b 32: the boards' paddings plus the row's 8 gap).
    var actionSpacing: CGFloat = Space.m
    /// Stacked action height: 44 (I3), or `.lnk`'s 48 (D6b). Inline actions are 48.
    var actionHeight: CGFloat = ControlSize.minTarget
    /// Centre the icon on the text (one-line notices: I1, I2, D6); top otherwise.
    var centred: Bool = false
    var onDismiss: (() -> Void)? = nil

    init(icon: CompassIcon? = nil, text: String, actions: [NoticeAction] = [], layout: Layout = .stacked,
         actionSpacing: CGFloat = Space.m, actionHeight: CGFloat = ControlSize.minTarget, centred: Bool = false,
         onDismiss: (() -> Void)? = nil) {
        self.icon = icon
        self.text = text
        self.actions = actions
        self.layout = layout
        self.actionSpacing = actionSpacing
        self.actionHeight = actionHeight
        self.centred = centred
        self.onDismiss = onDismiss
    }

    /// One action: `Notice(icon: .micoff, text: …, actionTitle: "Turn on the microphone") { … }`.
    init(icon: CompassIcon? = nil, text: String, actionTitle: String?, action: @escaping () -> Void = {}) {
        self.init(icon: icon, text: text, actions: actionTitle.map { [NoticeAction(title: $0, action: action)] } ?? [])
    }

    var body: some View {
        Group {
            switch layout {
            case .inline:
                HStack(alignment: centred || !actions.isEmpty ? .center : .top, spacing: Space.xs) {
                    glyph
                    words
                    ForEach(Array(actions.enumerated()), id: \.offset) { _, a in link(a, padding: onDismiss == nil ? 4 : Space.xs) }
                    if let onDismiss {
                        IconButton(.x, label: "Dismiss", bare: true, iconSize: IconSize.xs, action: onDismiss)
                    }
                }
                .padding(.vertical, onDismiss == nil ? Space.s : Space.xs)
                .padding(.leading, Space.s)
                .padding(.trailing, onDismiss == nil ? Space.s : Space.xs)
            case .stacked:
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(alignment: centred ? .center : .top, spacing: Space.xs) {
                        glyph
                        words
                    }
                    if !actions.isEmpty {
                        HStack(spacing: actionSpacing) {
                            ForEach(Array(actions.enumerated()), id: \.offset) { _, a in link(a, padding: 0) }
                        }
                        .padding(.leading, icon == nil ? 0 : IconSize.s + Space.xs)
                    }
                }
                .padding(Space.s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var glyph: some View {
        if let icon { Icon(icon, size: IconSize.s).foregroundStyle(.ink2) }
    }

    private var words: some View {
        CompassText(text, style: .caption, color: .noticeInk)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func link(_ a: NoticeAction, padding: CGFloat) -> some View {
        LinkButton(a.title, tone: .ink, padding: padding, minHeight: layout == .inline ? 48 : actionHeight, action: a.action)
            .accessibilityLabel(a.label ?? a.title)
    }
}

/// History segmented control (history.html `.seg`): 44 track, ground, ink selected segment (inset 4).
/// Each segment's target is the full 44pt height.
struct SegmentedPill: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, title in
                Button { selection = i } label: {
                    CompassText(title, style: .caption, weight: i == selection ? .semibold : .regular,
                                color: i == selection ? .ground : .ink2)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { if i == selection { Capsule().fill(Color.ink).padding(.vertical, 4) } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(i == selection ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .frame(height: ControlSize.minTarget)
        .background(Color.ground, in: Capsule())
    }
}

/// history.html / return.html `.opt` — an option card: 1pt line border, radius 24, padding 24; selected = 2pt ink.
struct OptionCard<Content: View>: View {
    var selected: Bool = false
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            // CSS draws the border outside the 24 padding (1pt; the selected 2pt border eats 1 of it).
            VStack(alignment: .leading, spacing: Space.xs) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.m + 1)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(selected ? Color.ink : Color.line, lineWidth: selected ? 2 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Live words: settled text in ink, the word still being recognised in #6E6E74 (A3, B2, C5, D3).
struct LiveTranscript: View {
    let settled: String
    var pending: String = ""
    var style: CompassType = .live

    var body: some View {
        let tail = pending.isEmpty || settled.isEmpty ? pending : " " + pending
        CompassText(runs: [TextRun(text: settled, color: .ink), TextRun(text: tail, color: .dim)], style: style)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(settled + (pending.isEmpty ? "" : " " + pending))
    }
}

/// History marks, one drawing for every list. No streaks or scores anywhere.
/// - `.week` (history.html `.dot`, E3 rows): 12pt ink when moved; 6pt #6E6E74 when missed; blank before
///   the goal or before today is answered.
/// - `.line` (`.dr .d`, E1 rows on the line): 16pt ink with a 4pt ground ring; 8pt grey when missed;
///   a 12pt #3A3A3E ring for today, not yet answered.
struct DayMarkView: View {
    enum Size { case week, line }

    let mark: DayMark
    var size: Size = .week

    var body: some View {
        ZStack {
            switch (mark, size) {
            case (.moved, .week): Circle().fill(Color.ink).frame(width: 12, height: 12)
            case (.missed, .week): Circle().fill(Color.dim).frame(width: 6, height: 6)
            case (.empty, .week): Color.clear
            case (.moved, .line):
                Circle().fill(Color.ink).frame(width: 16, height: 16)
                    .background(Circle().fill(Color.ground).frame(width: 24, height: 24))
            case (.missed, .line): Circle().fill(Color.dim).frame(width: 8, height: 8)
            case (.empty, .line):
                Circle().strokeBorder(Color.line2, lineWidth: 2).frame(width: 12, height: 12)
                    .background(Circle().fill(Color.ground).frame(width: 16, height: 16))
            }
        }
        .frame(width: size == .week ? 12 : 32, height: size == .week ? 12 : 24)
        .accessibilityHidden(true)
    }
}

/// The goal's end marker on the History line: 32pt ring (6pt ink border) with an 8pt centre dot.
/// `size: 48` with `achieved` is G2's filled marker (48pt ink disc, 12pt ground centre).
struct GoalEndMarker: View {
    var achieved: Bool = false
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(achieved ? Color.ink : Color.ground)
            Circle().strokeBorder(Color.ink, lineWidth: 6 * size / 32)
            Circle().fill(achieved ? Color.ground : Color.ink).frame(width: size / 4, height: size / 4)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(achieved ? "Goal achieved" : "Goal")
    }
}

/// Stand-in for the system keyboard in screenshots of typing states (kit.css `.keys`, 508–844): the CI
/// simulator has no software keyboard. Raised block, three rows of ten 44pt keys. Place with
/// `.region(.keyboard)`; on a phone the real keyboard sits here.
struct KeyboardPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 6) {
                    ForEach(0..<10, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6).fill(Color.line2).frame(height: 44)
                    }
                }
            }
        }
        .padding(.top, Space.xs)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.raised)
        .accessibilityHidden(true)
    }
}
