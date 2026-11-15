import SwiftUI
import UIKit
import CompassCore

// Pieces shared by the Morning (B) and Evening (D) rituals. Built only from design-system
// components; they add the board's labels and the AX sizes the boards draw (B8, D7, D8).

/// Close (×) top-left with the board's label ("Not now" on Morning, "Close and keep what was said"
/// while reflecting).
extension NavItem {
    static func ritualClose(_ label: String, action: @escaping () -> Void) -> NavItem {
        NavItem(content: .icon(.x), label: label, quiet: false, action: action)
    }
}

/// kit.css `.ctx` for rituals: 20pt symbol (28 at AX) + body text in #A1A1A6, up to three lines,
/// with an optional bare redo button on the right ("Say your intention again", B3/B4).
struct RitualSubject: View {
    var icon: CompassIcon? = nil
    let text: String
    var redoLabel: String? = nil
    var onRedo: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            if let icon {
                Icon(icon, size: dts.isAccessibilitySize ? IconSize.m : IconSize.s).padding(.top, 2)
            }
            Text(text)
                .compassFont(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let onRedo {
                IconButton(.redo, label: redoLabel ?? "Say it again", bare: true, action: onRedo)
                    .padding(.top, -10)
                    .padding(.trailing, -10)
            }
        }
        .foregroundStyle(.ink2)
        .accessibilityElement(children: .contain)
    }
}

/// kit.css `.dock` with the board's labels: keyboard (56, left) · mic (96, on 712) · side (56, right).
/// Place with `.region(.dock)`.
struct RitualVoiceDock<Side: View>: View {
    var micMode: MicButton.Mode
    var micLabel: String
    var keyboardLabel: String = "Type instead"
    let onKeyboard: () -> Void
    let onMic: () -> Void
    @ViewBuilder var side: Side

    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        HStack(spacing: 0) {
            // kit.css `.c56`; the keyboard glyph is 28 at AX (B8), the circle keeps its size.
            Button(action: onKeyboard) {
                Icon(.kb, size: dts.isAccessibilitySize ? IconSize.m : IconSize.i)
                    .foregroundStyle(.ink2)
                    .frame(width: ControlSize.secondary, height: ControlSize.secondary)
                    .overlay(Circle().strokeBorder(Color.line, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(keyboardLabel)
            Spacer(minLength: 0)
            MicButton(mode: micMode, label: micLabel, action: onMic)
            Spacer(minLength: 0)
            ZStack { Color.clear; side }.frame(width: 56, height: 56)
        }
        .frame(height: ControlSize.voice)
    }
}

extension RitualVoiceDock where Side == EmptyView {
    init(micMode: MicButton.Mode, micLabel: String, keyboardLabel: String = "Type instead",
         onKeyboard: @escaping () -> Void, onMic: @escaping () -> Void) {
        self.init(micMode: micMode, micLabel: micLabel, keyboardLabel: keyboardLabel,
                  onKeyboard: onKeyboard, onMic: onMic, side: { EmptyView() })
    }
}

/// "Skip" bottom-right in a voice dock. 17pt; 22pt at AX (B8), inside the fixed 56 slot.
struct DockSkip: View {
    var accessibilityLabel: String = "Skip"
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        Button(action: action) {
            Text("Skip")
                .compassFont(dts.isAccessibilitySize ? .caption : .body)
                .foregroundStyle(.ink2)
                .fixedSize()
                .frame(width: 56, height: 56)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The question greys and the words land under it (B2, D3, D3L, D4). Place with `.region(.focal)`:
/// the transcript fills to 592, then older lines scroll up under a 72pt fade.
struct ListeningFocal: View {
    let question: String
    let settled: String
    var pending: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(question)
                .ritualFont(.title)
                .foregroundStyle(.ink2)
                .fixedSize(horizontal: false, vertical: true)
            TranscriptScroll(settled: settled, pending: pending)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct TranscriptScroll: View {
    let settled: String
    var pending: String = ""

    @State private var overflowing = false

    var body: some View {
        ScrollView {
            LiveTranscript(settled: settled, pending: pending)
                .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentSize.height > geo.containerSize.height + 1
        } action: { _, isOverflowing in
            overflowing = isOverflowing
        }
        .mask {
            if overflowing {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 72)
                    Color.black
                }
            } else {
                Color.black
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The listening waveform on 616–656. Live levels follow the voice (level bar with Reduce Motion).
/// Fixture levels are static, so screenshots draw the board's bars even with motion reduced.
struct ListeningWave: View {
    var levels: [Float]
    var isStatic: Bool

    var body: some View {
        Waveform(levels: levels, lit: isStatic ? 32 : nil, count: VoiceCapture.barCount)
            .transformEnvironment(\.motionReduced) { reduced in
                if isStatic { reduced = false }
            }
    }
}

/// Keyboard stand-in for screenshots of typing states (the CI simulator has no software keyboard):
/// #1C1C1F from 508 to the bottom with three rows of keys. Place with `.region(.custom(top: 508, bottom: 844, inset: 0))`.
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

/// kit.css `.chip` as a part picker: part symbol in ink, title, chevron. At AX the chip grows to fit,
/// the symbol is 28 and the chevron goes (D8). Tapping lists the goal's parts.
struct PartPickerChip: View {
    let parts: [GoalPart]
    let selected: GoalPart?
    let onSelect: (GoalPart) -> Void

    @Environment(\.dynamicTypeSize) private var dts

    var body: some View {
        let ax = dts.isAccessibilitySize
        Menu {
            ForEach(parts) { part in
                Button(part.title) { onSelect(part) }
            }
        } label: {
            HStack(spacing: Space.xs) {
                if let selected {
                    Icon(CompassIcon(selected.symbol), size: ax ? IconSize.m : IconSize.s).foregroundStyle(.ink)
                }
                Text(selected?.title ?? "Choose a part")
                    .compassFont(.caption)
                    .foregroundStyle(.ink2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !ax { Icon(.down, size: IconSize.xs).foregroundStyle(.ink2) }
            }
            .padding(.leading, 12)
            .padding(.trailing, Space.s)
            .padding(.vertical, ax ? Space.xs : 0)
            .frame(minHeight: 44)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(selected.map { "Counts toward \($0.title). Change" } ?? "Choose a part")
    }
}

/// I1 / I4 in a ritual: the notice sits just above the dock, "Type instead" takes the 712 line and a
/// link sits under it. Used when the microphone is off or storage is full.
struct TypeInsteadDock: View {
    let reason: VoiceCapture.StartError
    let onType: () -> Void

    var body: some View {
        Group {
            Notice(icon: reason == .storageFull ? .disk : .micoff, text: noticeText)
                .region(.growsUp(bottom: 660))
            PrimaryButton("Type instead", icon: .kb, action: onType)
                .region(.buttonDock)
            LinkButton(linkTitle) { Self.openSettings() }
                .frame(maxWidth: .infinity)
                .region(.linkDock)
        }
    }

    private var noticeText: String {
        switch reason {
        case .storageFull: "Your iPhone is full, so audio can’t be saved. Typing still works, and nothing you saved before is affected."
        case .microphoneOff: "The microphone is off for Compass."
        case .unavailable: "The microphone isn’t available right now."
        }
    }

    private var linkTitle: String {
        reason == .storageFull ? "Manage storage" : "Turn on the microphone"
    }

    @MainActor static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// Typing in a ritual: the action rides above the keyboard at 436–492. With `drawsKeyboard` (fixture
/// screenshots) the keyboard is drawn; in the app the real keyboard rises underneath.
struct AboveKeyboardAction: View {
    let title: String
    var enabled: Bool = true
    var drawsKeyboard: Bool = false
    let action: () -> Void

    var body: some View {
        Group {
            PrimaryButton(title, action: action)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
                .region(.aboveKeyboard)
            if drawsKeyboard {
                KeyboardPlaceholder().region(.custom(top: 508, bottom: 844, inset: 0))
            }
        }
    }
}

/// `compassFont` keeps the spec's line height only when it is taller than Inter Tight's natural line.
/// Display (44/48, 56/60 at AX5) and title (34/40, 48/52) are tighter, so ritual text would grow a few
/// points per line and drift off the boards. This applies the negative leading too.
private struct RitualTightFontModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dts
    let style: CompassType

    func body(content: Content) -> some View {
        let size = style.size(for: dts)
        let leading = style.lineHeight(for: dts) - style.uiFont(for: dts).lineHeight
        content
            .font(style.font(for: dts))
            .tracking(style.spec.tracking * size)
            .lineSpacing(leading)
            .padding(.vertical, leading / 2)
    }
}

extension View {
    /// Display / title with the board's exact line boxes (see `RitualTightFontModifier`).
    func ritualFont(_ style: CompassType) -> some View {
        modifier(RitualTightFontModifier(style: style))
    }
}

/// The current microphone situation for a ritual dock: nil when recording can start.
@MainActor
func ritualMicProblem(_ model: AppModel, _ last: VoiceCapture.StartError?) -> VoiceCapture.StartError? {
    if let last { return last }
    if model.recorder.permission == .denied { return .microphoneOff }
    return nil
}
