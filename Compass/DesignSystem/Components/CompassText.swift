import SwiftUI
import UIKit

/// A run of text in one colour (live words: settled in ink, the word still being recognised dim).
struct TextRun: Equatable {
    var text: String
    var color: Color
}

/// The one way to set Compass text: every type style on the spec's exact line boxes, wrapped like the
/// boards, scaled to AX5 along the spec's curve.
///
///     CompassText("Did you do it?", style: .title)
///     CompassText(note.text, style: .caption, color: .ink2).lineLimit(2)
///
/// Why not `Text`: SwiftUI can only add leading, and display (44/48, 56/60 at AX5), title (34/40, 48/52)
/// and live/heading at AX are tighter than Inter Tight's natural line, so every line would grow a few
/// points. SwiftUI also moves a word down to avoid a one-word last line, which the boards (CSS) don't do.
/// This sets a UILabel with a fixed paragraph line height and no line-break strategy; the glyphs sit
/// centred in each line box, as CSS puts half the leading above and half below.
///
/// Reads the SwiftUI environment like `Text`: Dynamic Type (pin with `.dynamicTypeSize(.large)`),
/// `.lineLimit`, `.multilineTextAlignment`, `.truncationMode` (`.head` keeps the newest words) and
/// `.minimumScaleFactor` (one-line labels). Colour is a parameter: `foregroundStyle` can't reach UIKit.
/// It is one accessibility element (static text) labelled with its words; parents may combine it.
struct CompassText: View {
    var runs: [TextRun]
    var style: CompassType
    var weight: CompassType.Weight?

    init(_ text: String, style: CompassType = .body, weight: CompassType.Weight? = nil, color: Color = .ink) {
        self.runs = [TextRun(text: text, color: color)]
        self.style = style
        self.weight = weight
    }

    init(runs: [TextRun], style: CompassType = .body, weight: CompassType.Weight? = nil) {
        self.runs = runs
        self.style = style
        self.weight = weight
    }

    private var plain: String { runs.map(\.text).joined() }

    var body: some View {
        CompassLabel(runs: runs, style: style, weight: weight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(plain))
            .accessibilityAddTraits(.isStaticText)
    }
}

/// UILabel subclass that keeps the newest words visible when truncating at the head (live transcript in
/// the Today notes row), which UILabel can't do across several lines.
final class CompassUILabel: UILabel {
    var full: NSAttributedString = NSAttributedString()
    var headLines: Int? = nil
    private var resolvedWidth: CGFloat = -1

    func apply(_ text: NSAttributedString, headLines: Int?) {
        self.headLines = headLines
        if text != full || attributedText == nil {
            full = text
            resolvedWidth = -1
            attributedText = text
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let lines = headLines, bounds.width > 0, bounds.width != resolvedWidth else { return }
        resolvedWidth = bounds.width
        attributedText = Self.headTrimmed(full, lines: lines, width: bounds.width)
    }

    /// Drops leading words until the text fits `lines` lines at `width`, prefixed with "…".
    static func headTrimmed(_ text: NSAttributedString, lines: Int, width: CGFloat) -> NSAttributedString {
        let probe = UILabel()
        probe.numberOfLines = 0
        func height(_ s: NSAttributedString) -> CGFloat {
            probe.attributedText = s
            return probe.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        let style = text.length > 0 ? text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
        let lineHeight = style?.maximumLineHeight ?? 0
        guard lineHeight > 0, height(text) > lineHeight * CGFloat(lines) + 0.5 else { return text }
        let ns = text.string as NSString
        var starts: [Int] = []
        guard ns.length > 1 else { return text }
        for i in 1..<ns.length where ns.character(at: i - 1) == 32 && ns.character(at: i) != 32 { starts.append(i) }
        let attrs = text.attributes(at: 0, effectiveRange: nil)
        var lo = 0, hi = starts.count - 1, best: NSAttributedString?
        while lo <= hi {
            let mid = (lo + hi) / 2
            let candidate = NSMutableAttributedString(string: "…", attributes: attrs)
            candidate.append(text.attributedSubstring(from: NSRange(location: starts[mid], length: ns.length - starts[mid])))
            if height(candidate) <= lineHeight * CGFloat(lines) + 0.5 {
                best = candidate
                hi = mid - 1
            } else {
                lo = mid + 1
            }
        }
        return best ?? text
    }
}

private struct CompassLabel: UIViewRepresentable {
    let runs: [TextRun]
    let style: CompassType
    let weight: CompassType.Weight?

    func makeUIView(context: Context) -> CompassUILabel {
        let label = CompassUILabel()
        label.backgroundColor = .clear
        label.adjustsFontForContentSizeCategory = false
        label.isAccessibilityElement = false
        label.lineBreakStrategy = []
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .vertical)
        return label
    }

    func updateUIView(_ label: CompassUILabel, context: Context) {
        configure(label, context.environment)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView label: CompassUILabel, context: Context) -> CGSize? {
        let env = context.environment
        configure(label, env)
        let lineHeight = style.lineHeight(for: env.dynamicTypeSize)
        let proposed = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let measureWidth = proposed ?? .greatestFiniteMagnitude
        let text = label.full
        let probe = UILabel()
        probe.numberOfLines = env.lineLimit ?? 0
        probe.lineBreakStrategy = []
        probe.attributedText = text
        let fitted = probe.sizeThatFits(CGSize(width: measureWidth, height: .greatestFiniteMagnitude))
        let lines = max(1, Int((fitted.height / lineHeight).rounded()))
        var width = ceil(fitted.width)
        if let proposed {
            // Wrapped text fills the offered width (so the breaks never change when SwiftUI re-offers the
            // reported width); one line hugs its words.
            width = lines > 1 ? max(proposed, width) : min(width, proposed)
        }
        let height = text.length == 0 ? lineHeight : CGFloat(lines) * lineHeight
        return CGSize(width: width, height: height)
    }

    private func configure(_ label: CompassUILabel, _ env: EnvironmentValues) {
        let limit = env.lineLimit
        let head = env.truncationMode == .head && limit != nil
        label.numberOfLines = head ? 0 : (limit ?? 0)
        label.lineBreakMode = limit == nil || head ? .byWordWrapping : (env.truncationMode == .middle ? .byTruncatingMiddle : .byTruncatingTail)
        let scale = env.minimumScaleFactor
        label.adjustsFontSizeToFitWidth = scale < 1 && limit == 1
        label.minimumScaleFactor = scale
        label.apply(attributed(env), headLines: head ? limit : nil)
    }

    private func attributed(_ env: EnvironmentValues) -> NSAttributedString {
        let dts = env.dynamicTypeSize
        let font = style.uiFont(for: dts, weight: weight)
        let lineHeight = style.lineHeight(for: dts)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakStrategy = []
        paragraph.hyphenationFactor = 0
        if let limit = env.lineLimit, env.truncationMode != .head, limit > 0 {
            paragraph.lineBreakMode = env.truncationMode == .middle ? .byTruncatingMiddle : .byTruncatingTail
        } else {
            paragraph.lineBreakMode = .byWordWrapping
        }
        switch env.multilineTextAlignment {
        case .center: paragraph.alignment = .center
        case .trailing: paragraph.alignment = env.layoutDirection == .rightToLeft ? .left : .right
        default: paragraph.alignment = env.layoutDirection == .rightToLeft ? .right : .left
        }
        // UIKit puts a line box's slack above the glyphs; CSS splits it evenly.
        let baselineOffset = (lineHeight - font.lineHeight) / 2
        let result = NSMutableAttributedString()
        for run in runs {
            result.append(NSAttributedString(string: run.text, attributes: [
                .font: font,
                .foregroundColor: UIColor(run.color),
                .kern: style.kern(for: dts),
                .paragraphStyle: paragraph,
                .baselineOffset: baselineOffset,
            ]))
        }
        return result
    }
}
