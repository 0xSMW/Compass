import SwiftUI
import CompassCore

/// The v3 icon set (design/compass-v3/source/tools/symbols.html), ported 1:1 as template
/// SVG assets in Icons.xcassets ("icon-<id>"). Regenerate with `python3 scripts/gen_icons.py`.
enum CompassIcon: String, CaseIterable {
    case mic, micoff, kb, ok, x, back, right, down, up, redo, pen, play, wave
    /// Part symbols: wealth (stairs), strength (runner), friends (two people).
    case we, sg, fr
    case set, plus, minus, sun, moon, lock, cloud, sync, bell, globe, disk, trash, flag, swap, arch, phone, tablet, more

    var assetName: String { "icon-\(rawValue)" }

    /// Nearest SF Symbol, for places that need one (e.g. system notifications, AppIntents).
    var sfSymbol: String {
        switch self {
        case .mic: "mic"
        case .micoff: "mic.slash"
        case .kb: "keyboard"
        case .ok: "checkmark"
        case .x: "xmark"
        case .back: "chevron.left"
        case .right: "chevron.right"
        case .down: "chevron.down"
        case .up: "chevron.up"
        case .redo: "arrow.counterclockwise"
        case .pen: "pencil"
        case .play: "play.fill"
        case .wave: "waveform"
        case .we: "chart.bar.fill"
        case .sg: "figure.run"
        case .fr: "person.2.fill"
        case .set: "slider.horizontal.3"
        case .plus: "plus"
        case .minus: "minus"
        case .sun: "sun.max.fill"
        case .moon: "moon.fill"
        case .lock: "lock.fill"
        case .cloud: "cloud.fill"
        case .sync: "arrow.triangle.2.circlepath"
        case .bell: "bell.fill"
        case .globe: "globe"
        case .disk: "internaldrive"
        case .trash: "trash"
        case .flag: "flag.fill"
        case .swap: "arrow.left.arrow.right"
        case .arch: "archivebox"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .more: "ellipsis"
        }
    }

    init(_ symbol: PartSymbol) {
        switch symbol {
        case .wealth: self = .we
        case .strength: self = .sg
        case .friends: self = .fr
        case .flag: self = .flag
        case .sun: self = .sun
        case .moon: self = .moon
        }
    }
}

/// `Icon(.mic, size: IconSize.l)` — template image tinted by `.foregroundStyle`. Decorative by default
/// (the enclosing control carries the accessibility label).
struct Icon: View {
    let icon: CompassIcon
    var size: CGFloat = IconSize.i

    init(_ icon: CompassIcon, size: CGFloat = IconSize.i) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(icon.assetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
