import SwiftUI

/// The shared frame for Morning, Evening, Onboarding, History day, Return, Goal, Settings and System
/// screens. Full-screen ground; children place themselves on the spec's fixed lines with `.region(_:)`.
///
///     FlowScreen {
///         NavBar(leading: .close { model.closeRitual() }).region(.nav)
///         SubjectLine(icon: .fr, text: step.title).region(.subject)
///         CompassText("Did you do it?", style: .title).region(.focal)
///         ChoiceCircles(yes: "Done", no: "Not today", onYes: …, onNo: …).region(.dock)
///     }
///
/// The keyboard never moves the layout (planned reflow only): put the lifted action in `.aboveKeyboard`,
/// which follows the real keyboard's top (`KeyboardFrame`), and draw screenshot keyboards in `.keyboard`.
struct FlowScreen<Content: View>: View {
    var background: Color
    @ViewBuilder var content: Content

    init(background: Color = .ground, @ViewBuilder content: () -> Content) {
        self.background = background
        self.content = content()
    }

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            GeometryReader { inner in
                let originY = inner.frame(in: .global).minY
                let metrics = ScreenMetrics(size: inner.size, safeArea: insets,
                                            keyboardTop: KeyboardFrame.shared.top.map { $0 - originY })
                ZStack(alignment: .top) {
                    background
                    content
                }
                .frame(width: inner.size.width, height: inner.size.height, alignment: .top)
                .environment(\.screenMetrics, metrics)
            }
            .ignoresSafeArea()
        }
        .background(background.ignoresSafeArea())
        .foregroundStyle(.ink)
    }
}

/// Today: header grows down from 128 in its own scroll region (104 → 24 above the notes row);
/// the stack (notes row + step card) grows up from 656; the dock (keyboard + Note) is fixed at 680–744.
/// History sits top-left and Settings top-right on every Today state. The nav turns solid only once
/// the header is scrolled (C11b).
struct TodayScaffold<Header: View, Notes: View, Card: View, Dock: View, Overlay: View>: View {
    var onHistory: () -> Void
    var onSettings: () -> Void
    /// Replaces Settings top-right while a transient state needs a visible escape (C10 "Cancel").
    var trailing: NavItem? = nil
    /// Forces the solid nav (screenshots of C11b).
    var forceScrolledToEnd: Bool = false
    @ViewBuilder var header: Header
    @ViewBuilder var notes: Notes
    @ViewBuilder var card: Card
    @ViewBuilder var dock: Dock
    @ViewBuilder var overlay: Overlay

    @State private var scrolled = false
    /// The header overflows its region and isn't scrolled to the end: fade the last 48pt (C11).
    @State private var clipped = false

    init(
        onHistory: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        trailing: NavItem? = nil,
        forceScrolledToEnd: Bool = false,
        @ViewBuilder header: () -> Header,
        @ViewBuilder notes: () -> Notes,
        @ViewBuilder card: () -> Card,
        @ViewBuilder dock: () -> Dock,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.onHistory = onHistory
        self.onSettings = onSettings
        self.trailing = trailing
        self.forceScrolledToEnd = forceScrolledToEnd
        self.header = header()
        self.notes = notes()
        self.card = card()
        self.dock = dock()
        self.overlay = overlay()
    }

    var body: some View {
        FlowScreen {
            VStack(spacing: Space.m) {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 0) {
                            VStack(alignment: .leading, spacing: 0) {
                                header
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.inset)
                            .padding(.vertical, Space.m)
                            // After the bottom padding, so "scrolled to end" clears the notes row by 24 (C11b).
                            Color.clear.frame(height: 0).id("todayHeaderEnd")
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .onScrollGeometryChange(for: Bool.self) { geo in
                        geo.contentOffset.y + geo.contentInsets.top > 1
                    } action: { _, isScrolled in
                        scrolled = isScrolled
                    }
                    .onScrollGeometryChange(for: Bool.self) { geo in
                        // The last 24 is padding: fade only once words are cut off.
                        geo.contentOffset.y + geo.containerSize.height < geo.contentSize.height - Space.m - 1
                    } action: { _, isClipped in
                        clipped = isClipped
                    }
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, clipped && !forceScrolledToEnd ? .clear : .black],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: 48)
                        }
                    }
                    .onAppear {
                        if forceScrolledToEnd {
                            DispatchQueue.main.async { reader.scrollTo("todayHeaderEnd", anchor: .bottom) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Space.m) {
                    notes
                    card
                }
                .padding(.horizontal, Space.inset)
                .fixedSize(horizontal: false, vertical: true)
            }
            .region(.custom(top: 104, bottom: 656, inset: 0))

            NavBar(
                leading: .text("History", action: onHistory),
                trailing: trailing ?? .icon(.set, label: "Settings", action: onSettings),
                solid: scrolled || forceScrolledToEnd,
                scalesText: true
            )
            .region(.nav)

            dock.region(.todayDock)

            overlay
        }
    }
}

extension TodayScaffold where Overlay == EmptyView {
    init(
        onHistory: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        trailing: NavItem? = nil,
        forceScrolledToEnd: Bool = false,
        @ViewBuilder header: () -> Header,
        @ViewBuilder notes: () -> Notes,
        @ViewBuilder card: () -> Card,
        @ViewBuilder dock: () -> Dock
    ) {
        self.init(onHistory: onHistory, onSettings: onSettings, trailing: trailing, forceScrolledToEnd: forceScrolledToEnd,
                  header: header, notes: notes, card: card, dock: dock, overlay: { EmptyView() })
    }
}
