import SwiftUI
import UIKit
import CoreText

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
/// | micro   | 13/16     | 500 mono | 22/28 (400) |
///
/// Board-only styles, drawn on one screen each but still tokens (no one-off fonts in features):
///
/// | Style    | Size/Line | Weight     | AX5   | Where |
/// |----------|-----------|------------|-------|-------|
/// | label    | 13/16     | 500        | 17/20 | History day labels ("Today", "Monday") |
/// | nav      | 17/24     | 400        | 22/28 | Nav row text ("History", "‹ This week") |
/// | bodyMono | 17/24     | 400 mono   | 26/32 | Settings times (`.lr .v.mono`) |
/// | time     | 28/32     | 500 mono   | 34/40 | A6 rhythm times |
/// | numeral  | 96/96     | 600, −0.05em | 96/96 | F2 step total |
/// | clock    | 96/96     | 600, −0.04em | 96/96 | I5 lock-screen clock |
///
/// Sizes scale with Dynamic Type along the spec's own curve (not Apple's), reaching the AX column at AX5.
/// Set text with `CompassText` (exact line boxes, board line breaks); `compassFont` is only for
/// fields and widget text (see CompassText.swift).
enum CompassType: CaseIterable {
    case display, title, live, heading, body, caption, micro
    case label, nav, bodyMono, time, numeral, clock

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
        /// Weight at accessibility sizes, when the boards change it (durations: `mono axC` is 400).
        var axWeight: Weight? = nil
        /// Points the glyphs sit above the centred line box. Chrome snaps the boards' baselines to whole
        /// pixels; for live (24/32 in Inter Tight Medium) that lands 1pt higher than centring does, on
        /// every line of A3, B2, C5, D3, D3L and D4.
        var raise: CGFloat = 0
    }

    var spec: Spec {
        switch self {
        case .display: Spec(size: 44, lineHeight: 48, weight: .semibold, tracking: -0.03, axSize: 56, axLineHeight: 60)
        case .title: Spec(size: 34, lineHeight: 40, weight: .semibold, tracking: -0.025, axSize: 48, axLineHeight: 52)
        case .live: Spec(size: 24, lineHeight: 32, weight: .medium, tracking: -0.01, axSize: 34, axLineHeight: 40, raise: 1)
        case .heading: Spec(size: 22, lineHeight: 28, weight: .medium, tracking: -0.005, axSize: 30, axLineHeight: 36)
        case .body: Spec(size: 17, lineHeight: 24, weight: .regular, tracking: 0, axSize: 26, axLineHeight: 32)
        case .caption: Spec(size: 15, lineHeight: 20, weight: .regular, tracking: 0, axSize: 22, axLineHeight: 28)
        // Boards draw durations at AX as `mono axC` (22/28, 400): D8, E6.
        case .micro: Spec(size: 13, lineHeight: 16, weight: .medium, tracking: 0, axSize: 22, axLineHeight: 28, mono: true, axWeight: .regular)
        // kit.css `.navb` 17/24; Today and the AX boards scale it to `axC` 22/28 (C11, E6).
        case .nav: Spec(size: 17, lineHeight: 24, weight: .regular, tracking: 0, axSize: 22, axLineHeight: 28)
        case .label: Spec(size: 13, lineHeight: 16, weight: .medium, tracking: 0, axSize: 17, axLineHeight: 20)
        case .bodyMono: Spec(size: 17, lineHeight: 24, weight: .regular, tracking: 0, axSize: 26, axLineHeight: 32, mono: true)
        case .time: Spec(size: 28, lineHeight: 32, weight: .medium, tracking: 0, axSize: 34, axLineHeight: 40, mono: true)
        case .numeral: Spec(size: 96, lineHeight: 96, weight: .semibold, tracking: -0.05, axSize: 96, axLineHeight: 96)
        case .clock: Spec(size: 96, lineHeight: 96, weight: .semibold, tracking: -0.04, axSize: 96, axLineHeight: 96)
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

    func fontName(_ weight: Weight?, dts: DynamicTypeSize = .large) -> String {
        let w = weight ?? (dts.isAccessibilitySize ? spec.axWeight : nil) ?? spec.weight
        return spec.mono ? w.plexMono : w.interTight
    }

    /// `.baselineOffset` for a UIKit line box of `lineHeight` set in `font`: UIKit puts a line box's slack
    /// above the glyphs; CSS splits it evenly (plus the style's `raise`).
    func baselineOffset(font: UIFont, lineHeight: CGFloat) -> CGFloat {
        (lineHeight - font.lineHeight) / 2 + spec.raise
    }

    /// Letter spacing in points at this size.
    func kern(for dts: DynamicTypeSize) -> CGFloat { spec.tracking * size(for: dts) }

    func font(for dts: DynamicTypeSize, weight: Weight? = nil) -> Font {
        .custom(fontName(weight, dts: dts), fixedSize: size(for: dts))
    }

    func uiFont(for dts: DynamicTypeSize, weight: Weight? = nil) -> UIFont {
        let font = UIFont(name: fontName(weight, dts: dts), size: size(for: dts)) ?? .systemFont(ofSize: size(for: dts))
        guard self == .clock else { return font }
        // Inter's contextual alternates raise a colon between digits; the I5 board draws it on the baseline.
        let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kContextualAlternatesType,
            UIFontDescriptor.FeatureKey.selector: kContextualAlternatesOffSelector,
        ]]])
        return UIFont(descriptor: descriptor, size: font.pointSize)
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
    /// A Compass type style on a SwiftUI `Text`/`TextField`. SwiftUI can only add leading, so this is
    /// exact for one-line text in styles whose line is taller than the font's (everything but display and
    /// title, and live/heading at AX). Use it for the widget (no UIKit there) and system-drawn fields;
    /// everything else uses `CompassText` / `CompassTextEditor`.
    func compassFont(_ style: CompassType, weight: CompassType.Weight? = nil) -> some View {
        modifier(CompassFontModifier(style: style, weight: weight))
    }
}
