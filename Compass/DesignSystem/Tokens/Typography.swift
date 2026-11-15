import SwiftUI
import UIKit

/// The type scale from the system sheet. Inter Tight for everything, IBM Plex Mono for times and durations only.
///
/// | Style   | Size/Line | Weight | AX5   |
/// |---------|-----------|--------|-------|
/// | display | 44/48     | 600    | 56/60 |
/// | title   | 34/40     | 600    | 48/52 |
/// | live    | 24/32     | 500    | 34/40 |
/// | heading | 22/28     | 500    | 30/36 |
/// | body    | 17/24     | 400    | 26/32 |
/// | caption | 15/20     | 400    | 22/28 |
/// | micro   | 13/16     | 500 mono | 17/20 |
///
/// Sizes scale with Dynamic Type along the spec's own curve (not Apple's), reaching the AX column at AX5.
enum CompassType: CaseIterable {
    case display, title, live, heading, body, caption, micro

    enum Weight {
        case regular, medium, semibold

        var interTight: String {
            switch self {
            case .regular: "InterTight-Regular"
            case .medium: "InterTight-Medium"
            case .semibold: "InterTight-SemiBold"
            }
        }

        var plexMono: String {
            switch self {
            case .regular: "IBMPlexMono-Regular"
            case .medium, .semibold: "IBMPlexMono-Medium"
            }
        }
    }

    struct Spec {
        var size: CGFloat
        var lineHeight: CGFloat
        var weight: Weight
        /// Letter spacing in em.
        var tracking: CGFloat
        var axSize: CGFloat
        var axLineHeight: CGFloat
        var mono: Bool = false
    }

    var spec: Spec {
        switch self {
        case .display: Spec(size: 44, lineHeight: 48, weight: .semibold, tracking: -0.03, axSize: 56, axLineHeight: 60)
        case .title: Spec(size: 34, lineHeight: 40, weight: .semibold, tracking: -0.025, axSize: 48, axLineHeight: 52)
        case .live: Spec(size: 24, lineHeight: 32, weight: .medium, tracking: -0.01, axSize: 34, axLineHeight: 40)
        case .heading: Spec(size: 22, lineHeight: 28, weight: .medium, tracking: -0.005, axSize: 30, axLineHeight: 36)
        case .body: Spec(size: 17, lineHeight: 24, weight: .regular, tracking: 0, axSize: 26, axLineHeight: 32)
        case .caption: Spec(size: 15, lineHeight: 20, weight: .regular, tracking: 0, axSize: 22, axLineHeight: 28)
        case .micro: Spec(size: 13, lineHeight: 16, weight: .medium, tracking: 0, axSize: 17, axLineHeight: 20, mono: true)
        }
    }

    /// 0 at Large (default) → 1 at AX5. Below Large sizes shrink multiplicatively.
    static func progress(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall, .small, .medium, .large: 0
        case .xLarge: 0.1
        case .xxLarge: 0.2
        case .xxxLarge: 0.3
        case .accessibility1: 0.45
        case .accessibility2: 0.6
        case .accessibility3: 0.75
        case .accessibility4: 0.88
        case .accessibility5: 1
        @unknown default: 0
        }
    }

    static func shrink(_ size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.88
        case .small: 0.94
        case .medium: 0.97
        default: 1
        }
    }

    func size(for dts: DynamicTypeSize) -> CGFloat {
        let s = spec
        return (s.size + (s.axSize - s.size) * Self.progress(dts)) * Self.shrink(dts)
    }

    func lineHeight(for dts: DynamicTypeSize) -> CGFloat {
        let s = spec
        return (s.lineHeight + (s.axLineHeight - s.lineHeight) * Self.progress(dts)) * Self.shrink(dts)
    }

    func fontName(_ weight: Weight?) -> String {
        let w = weight ?? spec.weight
        return spec.mono ? w.plexMono : w.interTight
    }

    func font(for dts: DynamicTypeSize, weight: Weight? = nil) -> Font {
        .custom(fontName(weight), fixedSize: size(for: dts))
    }

    func uiFont(for dts: DynamicTypeSize, weight: Weight? = nil) -> UIFont {
        UIFont(name: fontName(weight), size: size(for: dts)) ?? .systemFont(ofSize: size(for: dts))
    }

    /// True when Inter Tight is registered (UIAppFonts). Stubs show a warning if not.
    static var fontsLoaded: Bool { UIFont(name: "InterTight-Regular", size: 12) != nil }
}

private struct CompassFontModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dts
    let style: CompassType
    let weight: CompassType.Weight?

    func body(content: Content) -> some View {
        let size = style.size(for: dts)
        let target = style.lineHeight(for: dts)
        let natural = style.uiFont(for: dts, weight: weight).lineHeight
        let leading = target - natural
        content
            .font(style.font(for: dts, weight: weight))
            .tracking(style.spec.tracking * size)
            .lineSpacing(max(0, leading))
            // CSS puts half the leading above and below each line box; keep the same anchors.
            .padding(.vertical, max(0, leading) / 2)
    }
}

extension View {
    /// Apply a Compass type style: `Text("Did you do it?").compassFont(.title)`.
    /// Pass `weight` for controls (btn = .semibold, btn2/pill/choice = .medium).
    func compassFont(_ style: CompassType, weight: CompassType.Weight? = nil) -> some View {
        modifier(CompassFontModifier(style: style, weight: weight))
    }
}
