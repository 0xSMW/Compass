import SwiftUI
import AudioToolbox
import UIKit

/// The one sound in the app: a dry completion click. Uses System Sound Services, so it follows
/// the silent switch. Toggle off with Settings → Sound and haptics (`Feedback.enabled`).
@MainActor
enum Feedback {
    static var enabled = true
    private static var clickID: SystemSoundID = {
        var id: SystemSoundID = 0
        if let url = Bundle.main.url(forResource: "click", withExtension: "wav") {
            AudioServicesCreateSystemSoundID(url as CFURL, &id)
        }
        return id
    }()

    /// Click + light haptic + VoiceOver "Done, undo available".
    static func complete() {
        guard enabled else { return }
        if clickID != 0 { AudioServicesPlaySystemSound(clickID) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

/// kit.css `.c56.done` / `.c56.done.on` — the completion circle (56, 2pt ink ring). Tap completes:
/// fills from the centre in 240 ms (instant with Reduce Motion), one click, light haptic, and
/// VoiceOver announces "Done, undo available". Tap for completion, never voice.
struct CompletionCircle: View {
    @Binding var isDone: Bool
    var onChange: (Bool) -> Void = { _ in }

    @Environment(\.motionReduced) private var reduced

    var body: some View {
        Button {
            let newValue = !isDone
            withAnimation(Motion.animation(Motion.complete, reduced: reduced)) { isDone = newValue }
            if newValue {
                Feedback.complete()
                Feedback.announce("Done, undo available")
            }
            onChange(newValue)
        } label: {
            ZStack {
                Circle().strokeBorder(Color.ink, lineWidth: 2)
                Circle().fill(Color.ink)
                    .scaleEffect(isDone ? 1 : 0.001)
                Icon(.ok).foregroundStyle(.ground).opacity(isDone ? 1 : 0)
            }
            .frame(width: ControlSize.secondary, height: ControlSize.secondary)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDone ? "Done. Tap to reopen" : "Mark step done")
    }
}

/// kit.css `.slot` — the Today step card: surface, radius 24, padding 24, min 176, grows up from 656.
/// Title (Heading) on top; bottom row (56) = part label · ••• options · completion circle (centre 604).
struct StepCard: View {
    enum State: Equatable {
        /// C1/C2: "No step yet" / "No step today" with a + (Plan a step).
        case empty(title: String, label: String)
        case open
        /// C4: "Done · Undo" in the label slot for 5 s.
        case justDone
        case done
    }

    var title: String
    var partTitle: String? = nil
    var partIcon: CompassIcon? = nil
    var state: State = .open
    var onToggle: (Bool) -> Void = { _ in }
    var onUndo: () -> Void = {}
    var onOptions: () -> Void = {}
    var onPlan: () -> Void = {}
    /// Hide the ••• button (C6 while the options sheet is up).
    var showsOptions: Bool = true

    @SwiftUI.State private var done = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(cardTitle)
                .compassFont(.heading)
                .foregroundStyle(isDimTitle ? Color.ink2 : Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.s)
            HStack(spacing: Space.xs) {
                label.frame(maxWidth: .infinity, alignment: .leading)
                switch state {
                case .empty:
                    CircleButton(.plus, label: "Plan a step", style: .ink, action: onPlan)
                default:
                    if showsOptions { IconButton(.more, label: "Step options", bare: true, action: onOptions) }
                    CompletionCircle(isDone: $done) { onToggle($0) }
                }
            }
            .frame(height: 56)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onAppear { done = state == .justDone || state == .done }
        .onChange(of: state) { _, s in done = s == .justDone || s == .done }
    }

    private var cardTitle: String {
        if case .empty(let t, _) = state { return t }
        return title
    }

    private var isDimTitle: Bool {
        switch state {
        case .empty, .justDone, .done: true
        case .open: false
        }
    }

    @ViewBuilder
    private var label: some View {
        switch state {
        case .empty(_, let label):
            Text(label).compassFont(.caption).foregroundStyle(.ink3)
        case .justDone:
            HStack(spacing: Space.xs) {
                Text("Done").compassFont(.caption).foregroundStyle(.ink)
                LinkButton("Undo", tone: .ink, action: onUndo)
            }
            .accessibilityElement(children: .contain)
        case .open, .done:
            HStack(spacing: Space.xs) {
                if let partIcon { Icon(partIcon, size: typeSize.isAccessibilitySize ? IconSize.m : IconSize.s) }
                if let partTitle { Text(partTitle).compassFont(.caption).lineLimit(2) }
            }
            .foregroundStyle(.ink3)
        }
    }
}

/// kit.css `.scrim` + `.sheet` + `.grab` — a Compass sheet: raised (#1C1C1F), radius 24 top / 48 bottom,
/// grab handle at 8. Overlays keep the 712 line: Save on 712, Cancel 744–792.
/// Use as `.compassSheet(isPresented: $show, height: 312) { … }` on a FlowScreen/TodayScaffold.
struct CompassSheet<Content: View>: View {
    var height: CGFloat
    var label: String = "Sheet"
    var onDismiss: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.scrim
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                Capsule().fill(Color.line2).frame(width: 40, height: 5).padding(.top, Space.xs)
                    .accessibilityHidden(true)
                content
                    .padding(.horizontal, Space.inset)
                    .padding(.top, Space.m - 13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: Radius.card, bottomLeadingRadius: Radius.sheetBottom,
                                       bottomTrailingRadius: Radius.sheetBottom, topTrailingRadius: Radius.card, style: .continuous)
                    .fill(Color.raised)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isModal)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Present a Compass sheet over this screen (not a system sheet: it keeps the design's anchors).
    func compassSheet<Content: View>(isPresented: Binding<Bool>, height: CGFloat, label: String = "Sheet",
                                     @ViewBuilder content: @escaping () -> Content) -> some View {
        overlay {
            if isPresented.wrappedValue {
                CompassSheet(height: height, label: label, onDismiss: { isPresented.wrappedValue = false }, content: content)
                    .transition(.opacity)
            }
        }
    }
}
