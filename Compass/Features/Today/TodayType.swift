import SwiftUI
import UIKit

/// Text set on the board's line boxes even when they are tighter than the font's natural line.
///
/// `compassFont` can only add leading (SwiftUI ignores negative `lineSpacing`), and title (34/40,
/// 48/52 at AX5) and display (44/48) are tighter than Inter Tight's natural line, so a three-line goal
/// would grow 3pt (18pt at AX5) and push Today's header and I1's question off the boards. A UILabel
/// with a fixed paragraph line height keeps CSS's line boxes, with glyphs centred in each box.
struct TodayLineBoxText: UIViewRepresentable {
    let text: String
    let style: CompassType
    var color: Color = .ink

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.backgroundColor = .clear
        label.adjustsFontForContentSizeCategory = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.attributedText = attributed(context.environment.dynamicTypeSize)
        label.accessibilityLabel = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? 342
        label.attributedText = attributed(context.environment.dynamicTypeSize)
        label.preferredMaxLayoutWidth = width
        let fitted = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    private func attributed(_ dts: DynamicTypeSize) -> NSAttributedString {
        let font = style.uiFont(for: dts)
        let lineHeight = style.lineHeight(for: dts)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        // UIKit keeps the descender at the bottom of a short line box; CSS splits the leading evenly.
        let baselineOffset = (lineHeight - font.lineHeight) / 2
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(color),
            .kern: style.spec.tracking * style.size(for: dts),
            .paragraphStyle: paragraph,
            .baselineOffset: baselineOffset,
        ])
    }
}
