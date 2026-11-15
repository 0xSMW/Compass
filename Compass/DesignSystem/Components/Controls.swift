import SwiftUI
import CompassCore

/// kit.css `.pill` — the Note button: 64 tall, surface, mic + "Note". In the Today dock next to the keyboard.
/// `recording: true` turns it into the recorder (C5): mini waveform + 48pt stop button.
struct NotePill: View {
    var title: String = "Note"
    var recording: Bool = false
    var levels: [Float] = FakeAudioRecorder.designLevels
    let action: () -> Void

    var body: some View {
        if recording {
            HStack(spacing: Space.s) {
                HStack(spacing: 3) {
                    ForEach(Array(levels.prefix(30).enumerated()), id: \.offset) { i, level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i < 24 ? Color.ink : Color.line)
                            .frame(width: 3, height: max(4, CGFloat(level) * 40))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 40)
                .clipped()
                .accessibilityHidden(true)
                Button(action: action) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.ground).frame(width: 16, height: 16)
                        .frame(width: 48, height: 48)
                        .background(Color.ink, in: Circle())
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Stop and save note")
            }
            .padding(.leading, Space.m)
            .padding(.trailing, Space.xs)
            .frame(maxWidth: .infinity, minHeight: ControlSize.notePill, maxHeight: ControlSize.notePill)
            .background(Color.surface, in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recording note")
        } else {
            Button(action: action) {
                HStack(spacing: Space.xs) {
                    Icon(.mic)
                    Text(title).compassFont(.body, weight: .medium)
                }
                .foregroundStyle(.ink)
                .frame(maxWidth: .infinity, minHeight: ControlSize.notePill, maxHeight: ControlSize.notePill)
                .background(Color.surface, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Record a note")
        }
    }
}

/// kit.css `.tdock` — Today dock: keyboard circle (56) + Note pill (64). Place with `.region(.todayDock)`.
struct TodayDock: View {
    var recording: Bool = false
    let onKeyboard: () -> Void
    let onNote: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            CircleButton(.kb, label: recording ? "Switch to typing" : "Type a note", action: onKeyboard)
            NotePill(recording: recording, action: onNote)
        }
        .frame(height: 64)
    }
}

/// kit.css `.note` — a note row above the step card: wave icon (spoken) · text (caption, #A1A1A6) · mono duration.
struct NoteRow: View {
    let text: String
    var duration: TimeInterval? = nil
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Icon(duration == nil ? .pen : .wave, size: IconSize.s)
                Text(text).compassFont(.caption).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                if let duration {
                    Text(Player.format(duration)).compassFont(.micro).foregroundStyle(.ink3)
                }
            }
            .foregroundStyle(.ink2)
            .frame(minHeight: 44)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(duration == nil ? "Note: \(text)" : "Voice note, \(Int(duration!.rounded())) seconds: \(text)")
    }
}

/// kit.css `.chip` — 44 tall, outlined, part symbol + label + optional chevron. "Keep close friends ⌄".
struct Chip: View {
    let title: String
    var icon: CompassIcon? = nil
    var trailing: CompassIcon? = nil
    var accessibilityLabel: String? = nil
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let icon { Icon(icon, size: IconSize.s) }
                Text(title).compassFont(.caption).lineLimit(2)
                if let trailing { Icon(trailing, size: IconSize.xs) }
            }
            .foregroundStyle(.ink2)
            .padding(.leading, 12)
            .padding(.trailing, Space.s)
            .frame(minHeight: 44)
            .overlay(Capsule().strokeBorder(Color.line, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}

/// kit.css `.tile` — 40pt rounded (12) surface square with an ink icon. Used in lists (A5 parts, H1).
struct Tile: View {
    let icon: CompassIcon

    var body: some View {
        Icon(icon)
            .foregroundStyle(.ink)
            .frame(width: 40, height: 40)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
    }
}

/// kit.css `.lr` — list row: min 56, top hairline, optional leading icon/tile, title, trailing value
/// (#A1A1A6) and accessory.
struct ListRow<Accessory: View>: View {
    var icon: CompassIcon? = nil
    var tile: Bool = false
    let title: String
    var value: String? = nil
    var showsTopLine: Bool = true
    var tint: Color = .ink
    var action: (() -> Void)? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let row = HStack(spacing: Space.s) {
            if let icon {
                if tile { Tile(icon: icon) } else { Icon(icon) }
            }
            Text(title).compassFont(.body).foregroundStyle(tint).frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(value).compassFont(.body).foregroundStyle(.ink2)
            }
            accessory
        }
        .frame(minHeight: 56)
        .overlay(alignment: .top) {
            if showsTopLine { Rectangle().fill(Color.line).frame(height: 1) }
        }
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { row }.buttonStyle(PressableStyle())
        } else {
            row.accessibilityElement(children: .combine)
        }
    }
}

extension ListRow where Accessory == EmptyView {
    init(icon: CompassIcon? = nil, tile: Bool = false, title: String, value: String? = nil, showsTopLine: Bool = true,
         tint: Color = .ink, action: (() -> Void)? = nil) {
        self.init(icon: icon, tile: tile, title: title, value: value, showsTopLine: showsTopLine, tint: tint, action: action, accessory: { EmptyView() })
    }
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
/// Typed text goes where spoken words would appear, in the same type style.
struct UnderlineField: View {
    let prompt: String
    @Binding var text: String
    var style: CompassType = .title
    var axis: Axis = .vertical
    var focused: FocusState<Bool>.Binding? = nil
    /// Draw the focused underline without real focus (screenshots of keyboard states).
    var showsFocus: Bool = false

    @FocusState private var internalFocus: Bool

    var body: some View {
        let isFocused = showsFocus || (focused?.wrappedValue ?? internalFocus)
        VStack(alignment: .leading, spacing: Space.s) {
            field
                .compassFont(style)
                .foregroundStyle(.ink)
                .tint(.ink)
            Rectangle().fill(isFocused ? Color.ink : Color.line2).frame(height: 1.5)
        }
    }

    @ViewBuilder
    private var field: some View {
        let tf = TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Color.dim), axis: axis)
        if let focused {
            tf.focused(focused)
        } else {
            tf.focused($internalFocus)
        }
    }
}

/// kit.css `.notice` — surface card, radius 24, padding 16, icon + #D6D6D8 caption text, optional action link.
/// Notices take the notes row above the Today card (I2, I3) or the focal slot (I1, I4, D6).
struct Notice: View {
    var icon: CompassIcon? = nil
    let text: String
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            if let icon { Icon(icon, size: IconSize.s).foregroundStyle(.ink2) }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(text).compassFont(.caption).foregroundStyle(.noticeInk).frame(maxWidth: .infinity, alignment: .leading)
                if let actionTitle {
                    Button(action: action) {
                        Text(actionTitle).compassFont(.caption, weight: .medium).foregroundStyle(.ink)
                            .frame(minHeight: 32)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// History segmented control (history.html `.seg`): 44 tall, ground track, ink selected segment.
struct SegmentedPill: View {
    let options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, title in
                Button { selection = i } label: {
                    Text(title)
                        .compassFont(.caption, weight: i == selection ? .semibold : .regular)
                        .foregroundStyle(i == selection ? Color.ground : Color.ink2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { if i == selection { Capsule().fill(Color.ink) } }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(i == selection ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(height: 44)
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
            VStack(alignment: .leading, spacing: Space.xs) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Space.m)
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
        (Text(settled) + Text(pending.isEmpty || settled.isEmpty ? pending : " " + pending).foregroundColor(Color.dim))
            .compassFont(style)
            .foregroundStyle(.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(settled + (pending.isEmpty ? "" : " " + pending))
    }
}

/// History marks (history.html `.dot`, `.dr .d`, `.tm`). Moved = solid dot; missed = half-size grey dot;
/// goal = ringed end marker (filled centre once achieved). No streaks or scores anywhere.
struct DayMarkView: View {
    enum Size { case week, line }

    let mark: DayMark
    var size: Size = .week

    var body: some View {
        let d: CGFloat = size == .week ? 12 : 16
        ZStack {
            switch mark {
            case .moved: Circle().fill(Color.ink).frame(width: d, height: d)
            case .missed: Circle().fill(Color.dim).frame(width: d / 2, height: d / 2)
            case .empty: Color.clear
            }
        }
        .frame(width: size == .week ? 12 : 32, height: size == .week ? 12 : 16)
        .accessibilityLabel(mark == .moved ? "Moved" : mark == .missed ? "Missed" : "")
    }
}

/// The goal's end marker on the History line: 32pt ring (6pt ink border) with an 8pt centre dot.
struct GoalEndMarker: View {
    var achieved: Bool = false

    var body: some View {
        ZStack {
            Circle().fill(achieved ? Color.ink : Color.ground)
            Circle().strokeBorder(Color.ink, lineWidth: 6)
            Circle().fill(achieved ? Color.ground : Color.ink).frame(width: 8, height: 8)
        }
        .frame(width: 32, height: 32)
        .accessibilityLabel(achieved ? "Goal achieved" : "Goal")
    }
}
