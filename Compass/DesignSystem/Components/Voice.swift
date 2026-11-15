import SwiftUI
import CompassCore

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
/// With Reduce Motion it becomes a `LevelBar` ("live · reduced: level bar").
struct Waveform: View {
    /// 0...1 levels, oldest first.
    var levels: [Float] = FakeAudioRecorder.designLevels
    /// Bars drawn in ink (words already said); the rest in line colour.
    var lit: Int? = 32
    var count: Int = 38

    @Environment(\.motionReduced) private var reduced

    var body: some View {
        Group {
            if reduced {
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

/// kit.css `.dockc` + `.choice` — two 96pt answers on the 712 line, labels 768–792.
/// At accessibility sizes they become 72pt labelled full-width buttons: the yes button keeps the
/// 712 line and the no button sits 16 above it (D7). Place with `.region(.dock)`.
struct ChoiceCircles: View {
    let yes: String
    let no: String
    var yesIcon: CompassIcon? = .ok
    let onYes: () -> Void
    let onNo: () -> Void

    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        if dts.isAccessibilitySize {
            PrimaryButton(yes, icon: yesIcon, height: ControlSize.accessibleChoice, action: onYes)
                .overlay(alignment: .top) {
                    SecondaryButton(no, height: ControlSize.accessibleChoice, action: onNo)
                        .offset(y: -(ControlSize.accessibleChoice + Space.s))
                }
        } else {
            HStack(alignment: .top, spacing: Space.m) {
                choice(yes, filled: true, action: onYes)
                choice(no, filled: false, action: onNo)
            }
            .frame(height: ControlSize.voice, alignment: .top)
        }
    }

    private func choice(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                ZStack {
                    if filled {
                        Circle().fill(Color.ink)
                        if let yesIcon { Icon(yesIcon, size: IconSize.m).foregroundStyle(.ground) }
                    } else {
                        Circle().strokeBorder(Color.dim, lineWidth: 2)
                    }
                }
                .frame(width: ControlSize.voice, height: ControlSize.voice)
                Text(title)
                    .compassFont(.body, weight: .medium)
                    .foregroundStyle(filled ? Color.ink : Color.ink2)
                    .fixedSize()
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
    }
}

/// kit.css `.dock` + `.side` — voice dock: keyboard (56, left) · mic (96, centre on 712) · side (56, right; Skip).
/// Place with `.region(.dock)`.
struct VoiceDock<Side: View>: View {
    var micMode: MicButton.Mode = .rings
    var keyboardLabel: String = "Type instead"
    let onKeyboard: () -> Void
    let onMic: () -> Void
    @ViewBuilder var side: Side

    var body: some View {
        HStack(spacing: 0) {
            CircleButton(.kb, label: keyboardLabel, action: onKeyboard)
            Spacer(minLength: 0)
            MicButton(mode: micMode, action: onMic)
            Spacer(minLength: 0)
            side.frame(width: 56, height: 56)
        }
        .frame(height: ControlSize.voice)
    }
}

extension VoiceDock where Side == EmptyView {
    init(micMode: MicButton.Mode = .rings, keyboardLabel: String = "Type instead", onKeyboard: @escaping () -> Void, onMic: @escaping () -> Void) {
        self.init(micMode: micMode, keyboardLabel: keyboardLabel, onKeyboard: onKeyboard, onMic: onMic, side: { EmptyView() })
    }
}

/// kit.css `.player` — 80 tall surface card centred on 712: play (56 mic style) · mini wave · duration · redo.
/// Place with `.region(.player)`.
struct Player: View {
    var duration: TimeInterval
    var isPlaying: Bool = false
    var levels: [Float] = Array(FakeAudioRecorder.designLevels.prefix(20))
    var showsRedo: Bool = true
    let onPlay: () -> Void
    var onRedo: () -> Void = {}

    var body: some View {
        HStack(spacing: Space.s) {
            MicButton(mode: isPlaying ? .recording : .idle, size: ControlSize.secondary, icon: .play,
                      label: isPlaying ? "Pause memo" : "Play memo", action: onPlay)
            MiniWaveform(levels: levels)
            Text(Self.format(duration))
                .compassFont(.micro)
                .foregroundStyle(.ink2)
                .accessibilityLabel("\(Int(duration.rounded())) seconds")
            if showsRedo {
                IconButton(.redo, label: "Record again", bare: true, action: onRedo)
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
