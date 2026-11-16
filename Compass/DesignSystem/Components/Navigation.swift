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
    /// Glyph size at Large: 24 for icon items (`svg.i`), 16 beside text (`.navb.quiet svg.xs`).
    /// Scaled navs grow it with the text (28 / 20 at AX5).
    var iconSize: CGFloat? = nil
    var action: () -> Void

    /// Close (×) — top-left on every morning and evening screen. Pass the board's label
    /// ("Not now" on Morning, "Close and keep what was said" while reflecting).
    static func close(_ label: String = "Close", action: @escaping () -> Void) -> NavItem {
        NavItem(content: .icon(.x), label: label, quiet: false, action: action)
    }

    /// Back (‹) — top-left everywhere else.
    static func back(action: @escaping () -> Void) -> NavItem {
        NavItem(content: .icon(.back), label: "Back", quiet: false, action: action)
    }

    /// Quiet "‹ Title" back item (`.navb.quiet` with the 16pt chevron): "‹ Today", "‹ This week".
    static func quietBack(_ title: String, action: @escaping () -> Void) -> NavItem {
        NavItem(content: .iconText(.back, title), label: title, quiet: true, iconSize: IconSize.xs, action: action)
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
    /// The AX boards scale the nav with Dynamic Type (C11: "History" 17 → 22, Settings 24 → 28; E6
    /// "‹ This week" 22 with a 20 chevron; A8/B8/D7/D8 × and ‹ 28). Otherwise it stays at Large.
    /// The row itself keeps its 48pt height and place.
    var scalesText: Bool = false

    @Environment(\.dynamicTypeSize) private var outerTypeSize

    private var progressAX: CGFloat { scalesText ? CompassType.progress(outerTypeSize) : 0 }
    private var textSize: DynamicTypeSize { scalesText ? outerTypeSize : .large }

    private func glyph(_ item: NavItem, beside text: Bool) -> CGFloat {
        let base = item.iconSize ?? (text ? IconSize.xs : IconSize.i)
        return base + 4 * progressAX
    }

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
        // Controls keep their size at every text size (spec: Dynamic Type to AX5).
        .dynamicTypeSize(.large)
        .background(alignment: .bottom) {
            if solid {
                // Solid backdrop from the top of the screen to 104, with a hairline (C11b).
                VStack(spacing: 0) {
                    Color.ground
                    Rectangle().fill(Color.line).frame(height: 1)
                }
                .frame(height: 105)
                .offset(y: 1)
                .padding(.horizontal, -14)
            }
        }
    }

    @ViewBuilder
    private func item(_ item: NavItem?) -> some View {
        if let item {
            let color: Color = item.quiet ? .ink2 : .ink
            Button(action: item.action) {
                Group {
                    switch item.content {
                    case .icon(let icon):
                        Icon(icon, size: glyph(item, beside: false)).frame(width: 44, height: 44)
                    case .text(let t):
                        CompassText(t, style: .nav, color: color)
                            .lineLimit(1)
                            .dynamicTypeSize(textSize)
                            .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44)
                    case .iconText(let icon, let t):
                        HStack(spacing: 4) {
                            Icon(icon, size: glyph(item, beside: true))
                            CompassText(t, style: .nav, color: color).lineLimit(1).dynamicTypeSize(textSize)
                        }
                        .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44)
                    }
                }
                .foregroundStyle(color)
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

/// kit.css `.ctx` — the subject line at 128: optional part symbol + body text in #A1A1A6, up to three
/// lines (grows down), with an optional bare redo button on the right ("Say your intention again",
/// B3/B4/F1). Symbol 20 (`svg.s`, 2pt down), 28 at AX. Place with `.region(.subject)`.
struct SubjectLine: View {
    var icon: CompassIcon? = nil
    let text: String
    var redoLabel: String? = nil
    var onRedo: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dts

    init(icon: CompassIcon? = nil, text: String, redoLabel: String? = nil, onRedo: (() -> Void)? = nil) {
        self.icon = icon
        self.text = text
        self.redoLabel = redoLabel
        self.onRedo = onRedo
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            if let icon {
                Icon(icon, size: dts.isAccessibilitySize ? IconSize.m : IconSize.s).padding(.top, 2)
            }
            CompassText(text, color: .ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRedo {
                IconButton(.redo, label: redoLabel ?? "Say it again", bare: true, iconSize: IconSize.s, action: onRedo)
                    .padding(.top, -10)
                    .padding(.trailing, -10)
            }
        }
        .foregroundStyle(.ink2)
        .accessibilityElement(children: .contain)
    }
}
