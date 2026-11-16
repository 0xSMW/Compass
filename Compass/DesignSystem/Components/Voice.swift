import SwiftUI
import CompassCore

/// kit.css `.pill` — the Note button: 64 tall, surface, mic + "Note". In the Today dock next to the keyboard.
/// `recording: true` turns it into the recorder (C5): mini waveform + 48pt stop button.
struct NotePill: View {
    var title: String = "Note"
    /// `.kb` when Settings › Start with is Typing: the pill opens the typed note.
    var icon: CompassIcon = .mic
    var recording: Bool = false
    var levels: [Float] = FakeAudioRecorder.designLevels
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if recording {
            HStack(spacing: Space.s) {
                HStack(spacing: 3) {
                    ForEach(Array(levels.prefix(30).enumerated()), id: \.offset) { _, level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.ink)
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
                    Icon(icon, size: typeSize.isAccessibilitySize ? IconSize.m : IconSize.i)
                    // The pill keeps its 64pt height; its label scales (`pill axB` on C11).
                    CompassText(title, weight: .medium).lineLimit(1)
                }
                .foregroundStyle(.ink)
                .frame(maxWidth: .infinity, minHeight: ControlSize.notePill, maxHeight: ControlSize.notePill)
                .background(Color.surface, in: Capsule())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(icon == .kb ? "Type a note" : "Record a note")
        }
    }
}

/// kit.css `.tdock` — Today dock: keyboard circle (56; glyph 28 at AX) + Note pill (64).
/// `typingFirst` (Settings › Start with: Typing) swaps their jobs: the pill types, the circle records.
/// Place with `.region(.todayDock)`.
struct TodayDock: View {
    var recording: Bool = false
    var typingFirst: Bool = false
    var levels: [Float] = FakeAudioRecorder.designLevels
    let onKeyboard: () -> Void
    let onNote: () -> Void

    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        let swapped = typingFirst && !recording
        HStack(spacing: Space.s) {
            CircleButton(swapped ? .mic : .kb,
                         label: recording ? "Switch to typing" : (swapped ? "Record a note" : "Type a note"),
                         iconSize: dts.isAccessibilitySize ? IconSize.m : IconSize.i,
                         action: swapped ? onNote : onKeyboard)
            NotePill(icon: swapped ? .kb : .mic, recording: recording, levels: levels, action: swapped ? onKeyboard : onNote)
        }
        .frame(height: ControlSize.notePill)
    }
}

/// kit.css `.mic` (96 ink circle) with `.ringw` (Center rings), `.glow` (listening) and `.stop` (recording).
struct MicButton: View {
    enum Mode: Equatable {
        /// Plain mic.
        case idle
        /// Two still rings (inset 16 #3A3A3E, inset 32 #2A2A2D).
        case rings
        /// Rings that breathe: expand 4 s, settle 4 s. Reduced motion: still rings.
        case breathing
        /// Listening: soft ink glow (inset 24, 10%), stop square inside.
        case listening
        /// Recording without glow: stop square inside.
        case recording
    }

    var mode: Mode = .idle
    var size: CGFloat = ControlSize.voice
    /// Icon inside when not recording (`.play` for the 56pt player button).
    var icon: CompassIcon = .mic
    var label: String? = nil
    let action: () -> Void

    @Environment(\.motionReduced) private var reduced
    @State private var breathe = false

    init(mode: Mode = .idle, size: CGFloat = ControlSize.voice, icon: CompassIcon = .mic, label: String? = nil, action: @escaping () -> Void) {
        self.mode = mode
        self.size = size
        self.icon = icon
        self.label = label
        self.action = action
    }

    private var isStop: Bool { mode == .listening || mode == .recording }

    var body: some View {
        Button(action: action) {
            ZStack {
                if mode == .rings || mode == .breathing {
                    let scale: CGFloat = (mode == .breathing && breathe && !reduced) ? 1.08 : 1
                    Circle().stroke(Color.line, lineWidth: 1)
                        .frame(width: size + 64, height: size + 64)
                        .scaleEffect(scale)
                    Circle().stroke(Color.line2, lineWidth: 1)
                        .frame(width: size + 32, height: size + 32)
                        .scaleEffect(scale)
                }
                if mode == .listening {
                    Circle().fill(Color.ink.opacity(0.1))
                        .frame(width: size + 48, height: size + 48)
                }
                Circle().fill(Color.ink).frame(width: size, height: size)
                if isStop {
                    RoundedRectangle(cornerRadius: 4).fill(Color.ground).frame(width: 28 * size / 96, height: 28 * size / 96)
                } else {
                    Icon(icon, size: size >= 96 ? IconSize.l : IconSize.s).foregroundStyle(.ground)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label ?? (isStop ? "Stop recording" : "Record"))
        .onAppear { startBreathing() }
        .onChange(of: mode) { _, _ in startBreathing() }
    }

    private func startBreathing() {
        guard mode == .breathing, !reduced else { breathe = false; return }
        withAnimation(.easeInOut(duration: Motion.breath).repeatForever(autoreverses: true)) {
            breathe = true
        }
    }
}

/// kit.css `.wavebar` — 4pt bars, 4pt gap, radius 2, up to 40 tall. Lit bars ink, the rest #2A2A2D.
/// With Reduce Motion a live wave becomes a `LevelBar` ("live · reduced: level bar"); a still wave
/// (`isStatic`: the board's bars in screenshots, nothing moving) keeps its bars.
struct Waveform: View {
    /// 0...1 levels, oldest first.
    var levels: [Float] = FakeAudioRecorder.designLevels
    /// Bars drawn in ink (words already said); the rest in line colour. nil = all ink.
    var lit: Int? = 32
    var count: Int = 38
    var isStatic: Bool = false

    @Environment(\.motionReduced) private var reduced

    var body: some View {
        Group {
            if reduced && !isStatic {
                LevelBar(level: levels.last.map { CGFloat($0) } ?? 0)
            } else {
                HStack(spacing: 4) {
                    ForEach(0..<min(count, levels.count), id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i < (lit ?? count) ? Color.ink : Color.line)
                            .frame(width: 4, height: max(4, CGFloat(levels[i]) * 40))
                    }
                }
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .clipped()
            }
        }
        .accessibilityHidden(true)
    }
}

/// Reduced-motion stand-in for the waveform: a 4pt track with an ink fill for the current level.
struct LevelBar: View {
    var level: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.line)
                Capsule().fill(Color.ink).frame(width: max(4, geo.size.width * min(1, max(0, level))))
            }
        }
        .frame(height: 4)
        .frame(maxHeight: 40)
        .accessibilityHidden(true)
    }
}

/// kit.css `.minw` — the player's small waveform: 3pt bars, 3pt gap, #6E6E74, 75% height.
struct MiniWaveform: View {
    var levels: [Float] = Array(FakeAudioRecorder.designLevels.prefix(20))
    var color: Color = .dim

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 3, height: max(4, (CGFloat(level) * 40 * 0.75).rounded()))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 40)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// kit.css `.dockc` + `.choice` — two 96pt answers on the 712 line, labels 768–792. The Done/Yes check
/// is `svg.l` (36). Tapping one turns it into the mic on the same line in 240 ms (spec "Answer → record";
/// cut with Reduce Motion), then answers. At accessibility sizes they become 72pt labelled full-width
/// buttons: the yes button keeps the 712 line and the no button sits 16 above it (D7).
/// Place with `.region(.dock)`.
struct ChoiceCircles: View {
    let yes: String
    let no: String
    var yesIcon: CompassIcon? = .ok
    let onYes: () -> Void
    let onNo: () -> Void

    @Environment(\.dynamicTypeSize) private var dts
    @Environment(\.motionReduced) private var reduced
    /// The answer being turned into the mic (true = yes).
    @State private var answering: Bool?

    var body: some View {
        if dts.isAccessibilitySize {
            PrimaryButton(yes, icon: yesIcon, height: ControlSize.accessibleChoice, action: onYes)
                .overlay(alignment: .top) {
                    SecondaryButton(no, height: ControlSize.accessibleChoice, action: onNo)
                        .offset(y: -(ControlSize.accessibleChoice + Space.s))
                }
        } else {
            GeometryReader { geo in
                // Each circle's centre to the dock's centre: a quarter of the width plus half the gap.
                let shift = (geo.size.width - Space.m) / 4 + Space.m / 2
                HStack(alignment: .top, spacing: Space.m) {
                    choice(yes, filled: true, shift: shift) { answer(true, then: onYes) }
                    choice(no, filled: false, shift: -shift) { answer(false, then: onNo) }
                }
            }
            .frame(height: ControlSize.voice + Space.xs + 24, alignment: .top)
            .frame(height: ControlSize.voice, alignment: .top)
        }
    }

    private func answer(_ isYes: Bool, then action: @escaping () -> Void) {
        guard answering == nil else { return }
        guard let animation = Motion.animation(Motion.answerToRecord, reduced: reduced) else { action(); return }
        withAnimation(animation) { answering = isYes }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.answerToRecord) {
            action()
            answering = nil
        }
    }

    private func choice(_ title: String, filled: Bool, shift: CGFloat, action: @escaping () -> Void) -> some View {
        let isTapped = answering == filled
        let isOther = answering != nil && !isTapped
        return Button(action: action) {
            VStack(spacing: Space.xs) {
                ZStack {
                    Circle().fill(Color.ink).opacity(filled || isTapped ? 1 : 0)
                    if !filled { Circle().strokeBorder(Color.dim, lineWidth: 2).opacity(isTapped ? 0 : 1) }
                    if filled, let yesIcon {
                        Icon(yesIcon, size: IconSize.l).foregroundStyle(.ground).opacity(isTapped ? 0 : 1)
                    }
                    RoundedRectangle(cornerRadius: 4).fill(Color.ground).frame(width: 28, height: 28)
                        .opacity(isTapped ? 1 : 0)
                }
                .frame(width: ControlSize.voice, height: ControlSize.voice)
                .offset(x: isTapped ? shift : 0)
                CompassText(title, weight: .medium, color: filled ? .ink : .ink2)
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(answering == nil ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .opacity(isOther ? 0 : 1)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
    }
}

/// kit.css `.dock` + `.side` — voice dock: keyboard (56, left; glyph 28 at AX) · mic (96, centre on 712)
/// · side (56, right: Skip, or empty). Place with `.region(.dock)`.
struct VoiceDock<Side: View>: View {
    var micMode: MicButton.Mode = .rings
    var micLabel: String? = nil
    var keyboardLabel: String = "Type instead"
    let onKeyboard: () -> Void
    let onMic: () -> Void
    @ViewBuilder var side: Side

    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        HStack(spacing: 0) {
            CircleButton(.kb, label: keyboardLabel, iconSize: dts.isAccessibilitySize ? IconSize.m : IconSize.i, action: onKeyboard)
            Spacer(minLength: 0)
            MicButton(mode: micMode, label: micLabel, action: onMic)
            Spacer(minLength: 0)
            ZStack { Color.clear; side }.frame(width: 56, height: 56)
        }
        .frame(height: ControlSize.voice)
    }
}

extension VoiceDock where Side == EmptyView {
    init(micMode: MicButton.Mode = .rings, micLabel: String? = nil, keyboardLabel: String = "Type instead",
         onKeyboard: @escaping () -> Void, onMic: @escaping () -> Void) {
        self.init(micMode: micMode, micLabel: micLabel, keyboardLabel: keyboardLabel, onKeyboard: onKeyboard, onMic: onMic,
                  side: { EmptyView() })
    }
}

/// "Skip" in the voice dock's side slot: 17pt quiet, 22pt at AX (B8), inside the fixed 56 slot.
struct DockSkip: View {
    var accessibilityLabel: String = "Skip"
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        Button(action: action) {
            CompassText("Skip", style: .nav, color: .ink2)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 56, height: 56)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

/// kit.css `.player` — 80 tall surface card centred on 712: play (56 mic style) · mini wave · duration
/// (`micro mono`; `mono axC` 22/28 at AX) · redo (`svg.s` 20; 28 at AX, D8). Place with `.region(.player)`.
struct Player: View {
    var duration: TimeInterval
    var isPlaying: Bool = false
    var levels: [Float] = Array(FakeAudioRecorder.designLevels.prefix(20))
    var showsRedo: Bool = true
    let onPlay: () -> Void
    var onRedo: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        HStack(spacing: Space.s) {
            MicButton(mode: isPlaying ? .recording : .idle, size: ControlSize.secondary, icon: .play,
                      label: isPlaying ? "Pause memo" : "Play memo", action: onPlay)
            MiniWaveform(levels: levels)
            CompassText(Self.format(duration), style: .micro, color: .ink2)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("\(Int(duration.rounded())) seconds")
            if showsRedo {
                IconButton(.redo, label: "Record again", bare: true,
                           iconSize: dts.isAccessibilitySize ? IconSize.m : IconSize.s, action: onRedo)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ControlSize.player)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    /// "0:14", "1:02"
    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
}
