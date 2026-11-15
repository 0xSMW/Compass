import SwiftUI

/// One item in the nav row (kit.css `.navb`, 44 tall, min 44 wide, 17pt).
struct NavItem {
    enum Content {
        case icon(CompassIcon)
        case text(String)
        case iconText(CompassIcon, String)
    }

    var content: Content
    var label: String
    var quiet: Bool
    var action: () -> Void

    /// Close (×) — top-left on every morning and evening screen.
    static func close(_ action: @escaping () -> Void) -> NavItem {
        NavItem(content: .icon(.x), label: "Close", quiet: false, action: action)
    }

    /// Back (‹) — top-left everywhere else. Pass a title for "‹ Back" / "‹ This week".
    static func back(_ title: String? = nil, action: @escaping () -> Void) -> NavItem {
        NavItem(content: title.map { .iconText(.back, $0) } ?? .icon(.back), label: title ?? "Back", quiet: false, action: action)
    }

    /// Text item, quiet (#A1A1A6) by default: "History", "Skip", "Edit".
    static func text(_ title: String, quiet: Bool = true, action: @escaping () -> Void) -> NavItem {
        NavItem(content: .text(title), label: title, quiet: quiet, action: action)
    }

    /// Icon item, quiet by default: Settings (sliders).
    static func icon(_ icon: CompassIcon, label: String, quiet: Bool = true, action: @escaping () -> Void) -> NavItem {
        NavItem(content: .icon(icon), label: label, quiet: quiet, action: action)
    }
}

/// kit.css `.nav` — 56–104, close/back left, quiet right, optional 4-segment progress between.
/// Place with `.region(.nav)`. `solid` paints the ground behind it (Today once scrolled).
struct NavBar: View {
    var leading: NavItem? = nil
    var trailing: NavItem? = nil
    /// Onboarding progress: 1...4 segments lit.
    var progress: Int? = nil
    var solid: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            item(leading)
            if let progress {
                ProgressDots(current: progress).padding(.horizontal, Space.s)
            } else {
                Spacer(minLength: 0)
            }
            item(trailing)
        }
        .frame(height: 48)
        .background(alignment: .bottom) {
            if solid {
                Color.ground
                    .frame(height: 104)
                    .padding(.horizontal, -14)
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private func item(_ item: NavItem?) -> some View {
        if let item {
            Button(action: item.action) {
                Group {
                    switch item.content {
                    case .icon(let icon):
                        Icon(icon).frame(width: 44, height: 44)
                    case .text(let t):
                        Text(t).compassFont(.body).padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44)
                    case .iconText(let icon, let t):
                        HStack(spacing: 4) { Icon(icon); Text(t).compassFont(.body) }
                            .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44)
                    }
                }
                .foregroundStyle(item.quiet ? Color.ink2 : Color.ink)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(item.label)
        } else {
            // Keep the row balanced like `.navb[disabled]{visibility:hidden}`.
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
    }
}

/// kit.css `.prog` — four 4pt segments, gap 8; lit segments ink, the rest #2A2A2D.
struct ProgressDots: View {
    var total: Int = 4
    var current: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(0..<total, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < current ? Color.ink : Color.line)
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(total)")
    }
}

/// kit.css `.ctx` — the subject line at 128: optional part symbol (24, 2pt down) + body text in #A1A1A6.
/// Grows down to three lines. Place with `.region(.subject)`.
struct SubjectLine: View {
    var icon: CompassIcon? = nil
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            if let icon { Icon(icon).padding(.top, 2) }
            Text(text).compassFont(.body).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.ink2)
        .accessibilityElement(children: .combine)
    }
}
