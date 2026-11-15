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
/// Lives on the 712 line (`.region(.buttonDock)`). Fills the available width.
struct PrimaryButton: View {
    let title: String
    var icon: CompassIcon? = nil
    var role: ButtonRole? = nil
    var height: CGFloat = ControlSize.button
    let action: () -> Void

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
                if let icon { Icon(icon) }
                Text(title).compassFont(.body, weight: .semibold).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.ground)
            .padding(.horizontal, Space.m)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .background(role == .destructive ? Color.destructive : Color.ink, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

/// kit.css `.btn2` — secondary, 1.5pt #3A3A3E outline, 56 tall, pill.
struct SecondaryButton: View {
    let title: String
    var icon: CompassIcon? = nil
    var height: CGFloat = ControlSize.button
    let action: () -> Void

    init(_ title: String, icon: CompassIcon? = nil, height: CGFloat = ControlSize.button, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.height = height
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                if let icon { Icon(icon) }
                Text(title).compassFont(.body, weight: .medium).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(.ink)
            .padding(.horizontal, Space.m)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .overlay(Capsule().strokeBorder(Color.line2, lineWidth: 1.5))
        }
        .buttonStyle(PressableStyle())
    }
}

/// kit.css `.lnk` (quiet, #A1A1A6) and `.lnk.ink` (ink, 500). 48 tall. Skip, Cancel, Not now, Undo.
struct LinkButton: View {
    enum Tone { case quiet, ink }

    let title: String
    var tone: Tone = .quiet
    let action: () -> Void

    init(_ title: String, tone: Tone = .quiet, action: @escaping () -> Void) {
        self.title = title
        self.tone = tone
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .compassFont(.body, weight: tone == .ink ? .medium : .regular)
                .foregroundStyle(tone == .ink ? Color.ink : Color.ink2)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
        }
        .buttonStyle(PressableStyle())
    }
}

/// kit.css `.c56` — 56pt circle. `.outline`: 1pt line border, secondary icon (keyboard).
/// `.ink`: 1.5pt ink border, ink icon (+ Plan a step).
struct CircleButton: View {
    enum Style { case outline, ink }

    let icon: CompassIcon
    let label: String
    var style: Style = .outline
    var size: CGFloat = ControlSize.secondary
    let action: () -> Void

    init(_ icon: CompassIcon, label: String, style: Style = .outline, size: CGFloat = ControlSize.secondary, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.style = style
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(icon)
                .foregroundStyle(style == .ink ? Color.ink : Color.ink2)
                .frame(width: size, height: size)
                .overlay(
                    Circle().strokeBorder(style == .ink ? Color.ink : Color.line, lineWidth: style == .ink ? 1.5 : 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/// kit.css `.ic44` — 44pt icon button, outlined or `.bare` (••• Step options, redo, pen).
struct IconButton: View {
    let icon: CompassIcon
    let label: String
    var bare: Bool = false
    var tint: Color = .ink2
    let action: () -> Void

    init(_ icon: CompassIcon, label: String, bare: Bool = false, tint: Color = .ink2, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.bare = bare
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Icon(icon)
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
