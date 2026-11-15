import SwiftUI
import AudioToolbox
import UIKit
import CompassCore

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
            CompassText(cardTitle, style: .heading, color: isDimTitle ? .ink2 : .ink)
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
            CompassText(label, style: .caption, color: .ink3)
        case .justDone:
            HStack(spacing: Space.xs) {
                CompassText("Done", style: .caption).lineLimit(1).fixedSize()
                LinkButton("Undo", tone: .ink, action: onUndo)
            }
            .accessibilityElement(children: .contain)
        case .open, .done:
            HStack(spacing: Space.xs) {
                if let partIcon { Icon(partIcon, size: typeSize.isAccessibilitySize ? IconSize.m : IconSize.s) }
                if let partTitle { CompassText(partTitle, style: .caption, color: .ink3).lineLimit(2) }
            }
            .foregroundStyle(.ink3)
        }
    }
}

// MARK: - Sheets

/// kit.css `.scrim` + `.sheet` + `.grab` — a Compass sheet: raised (#1C1C1F), radius 24 top / 48 bottom,
/// grab handle at 8. Actions keep the 712 line: the last action (Save) on 684–740, and the escape link
/// (Cancel) always visible on 744–792, 52 above the bottom edge (spec: no hidden gestures).
///
/// `height` is the board's height at Large. The sheet grows to fit its content (large text) up to the
/// safe top, and the content scrolls beyond that; actions and Cancel never leave their lines.
///
///     .compassSheet(isPresented: $editing, height: 392, label: "Edit part") {
///         CompassText("Edit part", style: .heading)        // content, from 32 below the top
///     } actions: {
///         PrimaryButton("Save", action: save)                // on 712
///     }
struct CompassSheet<Content: View, Actions: View>: View {
    var height: CGFloat? = nil
    var label: String = "Sheet"
    /// The escape link under the actions ("Cancel", "Close").
    var dismissTitle: String = "Cancel"
    /// Content top, from the sheet's top edge: 32 for forms (E4, H2), 24 for lists (C6).
    var contentTop: CGFloat = Space.l
    var onDismiss: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    @Environment(\.screenMetrics) private var metrics

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.scrim
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            SheetLayout(preferred: height, contentTop: contentTop,
                        maxHeight: metrics.size.height - metrics.y(ScreenMetrics.safeTop)) {
                ViewThatFits(in: .vertical) {
                    contentColumn
                    ScrollView { contentColumn }
                        .scrollIndicators(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                }
                VStack(spacing: 0) {
                    VStack(spacing: Space.s) { actions }
                        .padding(.bottom, 4)
                    LinkButton(dismissTitle, action: onDismiss)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    Color.clear.frame(height: ScreenMetrics.designHeight - ScreenMetrics.safeBottom)
                }
                .padding(.horizontal, Space.inset)
            }
            .frame(maxWidth: .infinity)
            .background(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: Radius.card, bottomLeadingRadius: Radius.sheetBottom,
                                       bottomTrailingRadius: Radius.sheetBottom, topTrailingRadius: Radius.card, style: .continuous)
                    .fill(Color.raised)
                    .overlay(alignment: .top) {
                        Capsule().fill(Color.line2).frame(width: 40, height: 5).padding(.top, Space.xs)
                    }
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, onDismiss)
        }
        .ignoresSafeArea()
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.inset)
    }
}

/// Content from `contentTop`, actions bottom-anchored; height = max(board height, what fits), capped.
private struct SheetLayout: Layout {
    var preferred: CGFloat?
    var contentTop: CGFloat
    var maxHeight: CGFloat
    /// Least gap between the content and the actions.
    var gap: CGFloat = Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? ScreenMetrics.designWidth
        let content = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let actions = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let natural = contentTop + content + gap + actions
        return CGSize(width: width, height: min(max(preferred ?? 0, natural), maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        let actions = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let room = max(0, bounds.height - contentTop - gap - actions)
        let content = min(subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height, room)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + contentTop), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: content))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                          proposal: ProposedViewSize(width: width, height: actions))
    }
}

extension CompassSheet where Actions == EmptyView {
    init(height: CGFloat? = nil, label: String = "Sheet", dismissTitle: String = "Cancel", contentTop: CGFloat = Space.l,
         onDismiss: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(height: height, label: label, dismissTitle: dismissTitle, contentTop: contentTop, onDismiss: onDismiss,
                  content: content, actions: { EmptyView() })
    }
}

extension View {
    /// Present a Compass sheet over this screen (not a system sheet: it keeps the design's anchors).
    func compassSheet<Content: View, Actions: View>(
        isPresented: Binding<Bool>, height: CGFloat? = nil, label: String = "Sheet", dismissTitle: String = "Cancel",
        contentTop: CGFloat = Space.l, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content, @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        overlay {
            if isPresented.wrappedValue {
                CompassSheet(height: height, label: label, dismissTitle: dismissTitle, contentTop: contentTop,
                             onDismiss: onDismiss ?? { isPresented.wrappedValue = false },
                             content: content, actions: actions)
                    .transition(.opacity)
            }
        }
    }

    func compassSheet<Content: View>(
        isPresented: Binding<Bool>, height: CGFloat? = nil, label: String = "Sheet", dismissTitle: String = "Cancel",
        contentTop: CGFloat = Space.l, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        compassSheet(isPresented: isPresented, height: height, label: label, dismissTitle: dismissTitle, contentTop: contentTop,
                     onDismiss: onDismiss, content: content, actions: { EmptyView() })
    }
}

/// A question asked in a sheet instead of a system alert (H2's language): heading, body in #A1A1A6,
/// the answer on 712 (destructive when it removes something), Cancel under it.
struct ConfirmSheetContent: View {
    let title: String
    let message: String

    var body: some View {
        CompassText(title, style: .heading).accessibilityAddTraits(.isHeader)
        CompassText(message, color: .ink2).padding(.top, Space.xs)
    }
}

extension View {
    /// `confirmSheet(isPresented:title:message:confirm:role:onConfirm:)` — the DS confirmation (E4 delete,
    /// G1 mark as achieved). Height fits the words (min 312).
    func confirmSheet(isPresented: Binding<Bool>, title: String, message: String, confirm: String,
                      role: ButtonRole? = nil, onConfirm: @escaping () -> Void) -> some View {
        compassSheet(isPresented: isPresented, height: 312, label: title) {
            ConfirmSheetContent(title: title, message: message)
        } actions: {
            PrimaryButton(confirm, role: role) {
                isPresented.wrappedValue = false
                onConfirm()
            }
        }
    }
}

/// "Counts toward": one row per part (symbol, title, ✓ on the current one). Content for a sheet, or
/// for a sheet's second level (C6 → Counts toward, E4 → Counts toward). `allowsNone` adds "No part".
struct PartPickerRows: View {
    let parts: [GoalPart]
    let selected: UUID?
    var allowsNone: Bool = false
    let onPick: (UUID?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.element.id) { i, part in
                ListRow(icon: CompassIcon(part.symbol), title: part.title, showsTopLine: i > 0, action: { onPick(part.id) }) {
                    if part.id == selected { Icon(.ok, size: IconSize.s).foregroundStyle(.ink) }
                }
                .accessibilityAddTraits(part.id == selected ? .isSelected : [])
            }
            if allowsNone {
                ListRow(icon: .flag, title: "No part", showsTopLine: !parts.isEmpty, action: { onPick(nil) }) {
                    if selected == nil { Icon(.ok, size: IconSize.s).foregroundStyle(.ink) }
                }
                .accessibilityAddTraits(selected == nil ? .isSelected : [])
            }
        }
    }
}

extension View {
    /// The part picker as a sheet: the chip under a typed step (B5) or a saved evening (D5) opens it.
    func partPickerSheet(isPresented: Binding<Bool>, parts: [GoalPart], selected: UUID?,
                         onPick: @escaping (UUID) -> Void) -> some View {
        compassSheet(isPresented: isPresented, height: 24 + 56 * CGFloat(max(1, parts.count)) + 16 + 104,
                     label: "Counts toward", contentTop: Space.m) {
            PartPickerRows(parts: parts, selected: selected) { id in
                isPresented.wrappedValue = false
                if let id { onPick(id) }
            }
        }
    }
}
