import SwiftUI
import UIKit

/// `compassFont` keeps the spec's line height only when it is taller than the font's natural line
/// (leading ≥ 0). Title and display are tighter than Inter Tight's natural line (34/40, 48/52 at AX5;
/// display 44/48), so the goal would grow 1–6pt per line and push Today's header and I1's question
/// down. This variant also applies negative leading, keeping the board's line boxes.
private struct CompassTightFontModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dts
    let style: CompassType

    func body(content: Content) -> some View {
        let size = style.size(for: dts)
        let leading = style.lineHeight(for: dts) - style.uiFont(for: dts).lineHeight
        content
            .font(style.font(for: dts))
            .tracking(style.spec.tracking * size)
            .lineSpacing(leading)
            .padding(.vertical, leading / 2)
    }
}

extension View {
    /// `compassFont` with the spec's line height even when it is tighter than the font's own.
    func compassTightFont(_ style: CompassType) -> some View {
        modifier(CompassTightFontModifier(style: style))
    }
}
