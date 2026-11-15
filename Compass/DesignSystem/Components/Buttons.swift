import SwiftUI

/// Press feedback for every Compass control: a slight dim, no scale (no hidden motion).
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// kit.css `.btn` — primary, ink fill, 56 tall, pill. `.btn.danger` with `role: .destructive`.
/// Lives on the 712 line (`.region(.buttonDock)`). Fills the available width. Icon `svg.s` 20 (28 at AX).
struct PrimaryButton: View {
    let title: String
    var icon: CompassIcon? = nil
    var role: ButtonRole? = nil
    var height: CGFloat = ControlSize.button
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dts

    init(_ title: String, icon: CompassIcon? = nil, role: ButtonRole? = nil, height: CGFloat = ControlSize.button, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.role = role
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let icon { Icon(icon, size: dts.isAccessibilitySize ? IconSize.m : IconSize.s) }
                CompassText(title, weight: .semibold, color: .ground).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.ground)
            .padding(.horizontal, Space.m)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(role == .destructive ? Color.destructive : Color.ink, in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
    }
}

/// kit.css `.btn2` — secondary, 1.5pt #3A3A3E outline, 56 tall, pill.
struct SecondaryButton: View {
    let title: String
    var icon: CompassIcon? = nil
    var height: CGFloat = ControlSize.button
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var dts

    init(_ title: String, icon: CompassIcon? = nil, height: CGFloat = ControlSize.button, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let icon { Icon(icon, size: dts.isAccessibilitySize ? IconSize.m : IconSize.s) }
                CompassText(title, weight: .medium).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.ink)
            .padding(.horizontal, Space.m)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .overlay(Capsule().strokeBorder(Color.line2, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
    }
}

/// kit.css `.lnk` (quiet, #A1A1A6) and `.lnk.ink` (ink, 500). 48 tall. Skip, Cancel, Not now, Undo.
/// `style`/`weight` set the type (Notice actions are caption 500, D6 "Try now" body 500);
/// `.destructive` paints it #FF8A7A ("Delete this day’s entry", "Remove part"). Never under 44 × 44.
struct LinkButton: View {
    enum Tone { case quiet, ink, destructive }

    let title: String
    var tone: Tone = .quiet
    var style: CompassType = .body
    var padding: CGFloat = 12
    var minHeight: CGFloat = 48
    let action: () -> Void

    init(_ title: String, tone: Tone = .quiet, style: CompassType = .body, padding: CGFloat = 12, minHeight: CGFloat = 48,
         action: @escaping () -> Void) {
        self.title = title
        self.tone = tone
        self.style = style
        self.padding = padding
        self.minHeight = minHeight
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            CompassText(title, style: style, weight: tone == .ink ? .medium : .regular, color: color)
                .lineLimit(1)
                .padding(.horizontal, padding)
                .frame(minWidth: ControlSize.minTarget, minHeight: max(ControlSize.minTarget, minHeight))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
    }

    private var color: Color {
        switch tone {
        case .quiet: .ink2
        case .ink: .ink
        case .destructive: .destructive
        }
    }
}

/// kit.css `.c56` — 56pt circle. `.outline`: 1pt line border, secondary icon (keyboard).
/// `.ink`: 1.5pt ink border, ink icon (+ Plan a step, Say my own step). `.fill`: ink disc, ground icon
/// (C10 save). `iconSize` follows the board (the keyboard glyph is 28 at AX; the circle keeps its size).
struct CircleButton: View {
    enum Style { case outline, ink, fill }

    let icon: CompassIcon
    let label: String
    var style: Style = .outline
    var size: CGFloat = ControlSize.secondary
    var iconSize: CGFloat = IconSize.i
    let action: () -> Void

    init(_ icon: CompassIcon, label: String, style: Style = .outline, size: CGFloat = ControlSize.secondary,
         iconSize: CGFloat = IconSize.i, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.style = style
        self.size = size
        self.iconSize = iconSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(icon, size: iconSize)
                .foregroundStyle(style == .fill ? Color.ground : style == .ink ? Color.ink : Color.ink2)
                .frame(width: size, height: size)
                .background { if style == .fill { Circle().fill(Color.ink) } }
                .overlay {
                    switch style {
                    case .outline: Circle().strokeBorder(Color.line, lineWidth: 1)
                    case .ink: Circle().strokeBorder(Color.ink, lineWidth: 1.5)
                    case .fill: EmptyView()
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// kit.css `.ic44` — 44pt icon button, outlined or `.bare` (••• Step options, redo, pen, − / +).
/// `iconSize` follows the board's svg class: `.xs` 16 (A6 − / +, pen), `.s` 20 (redo), `.i` 24 (•••).
struct IconButton: View {
    let icon: CompassIcon
    let label: String
    var bare: Bool = false
    var tint: Color = .ink2
    var iconSize: CGFloat = IconSize.i
    let action: () -> Void

    init(_ icon: CompassIcon, label: String, bare: Bool = false, tint: Color = .ink2, iconSize: CGFloat = IconSize.i,
         action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.bare = bare
        self.tint = tint
        self.iconSize = iconSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(icon, size: iconSize)
                .foregroundStyle(tint)
                .frame(width: ControlSize.minTarget, height: ControlSize.minTarget)
                .overlay {
                    if !bare { Circle().strokeBorder(Color.line, lineWidth: 1) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// Primary button on the 712 line with an optional link below (kit.css `.dockb` + `.dockl`).
/// Place the whole thing with `.region(.custom(top: 684, bottom: 792))` or use `ButtonDock` directly
/// in a FlowScreen (it positions itself).
struct ButtonDock: View {
    let primary: String
    var primaryIcon: CompassIcon? = nil
    var role: ButtonRole? = nil
    var link: String? = nil
    let onPrimary: () -> Void
    var onLink: () -> Void = {}

    var body: some View {
        PrimaryButton(primary, icon: primaryIcon, role: role, action: onPrimary)
            .region(.buttonDock)
        if let link {
            LinkButton(link, action: onLink)
                .frame(maxWidth: .infinity)
                .region(.linkDock)
        }
    }
}
