import SwiftUI
import UIKit

/// Typed text on the same line boxes as `CompassText`: typed words land where spoken words would appear,
/// in the same type style (kit.css `.field`). A UITextView with a fixed paragraph line height, so a
/// three-line title field is 120pt tall like the boards, not 126. The placeholder is drawn in tertiary
/// ink (5.7:1; the spec's minimum for text).
///
/// `lines` sets the visible lines (`1...1` = one line; Return submits). Beyond the upper bound the field
/// scrolls inside. Return never inserts a newline: it calls `onSubmit`, or ends editing.
struct CompassTextEditor: View {
    @Binding var text: String
    var prompt: String
    var style: CompassType = .body
    var lines: ClosedRange<Int> = 1...6
    var focused: FocusState<Bool>.Binding?
    var label: String
    var returnKey: UIReturnKeyType = .done
    var onSubmit: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                CompassText(prompt, style: style, color: .ink3)
                    .lineLimit(lines.upperBound)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            EditorView(text: $text, style: style, lines: lines, focus: focused, label: label,
                       returnKey: returnKey, onSubmit: onSubmit)
        }
    }
}

private struct EditorView: UIViewRepresentable {
    @Binding var text: String
    let style: CompassType
    let lines: ClosedRange<Int>
    let focus: FocusState<Bool>.Binding?
    let label: String
    let returnKey: UIReturnKeyType
    let onSubmit: (() -> Void)?

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: EditorView
        /// The focus binding as `updateUIView` last saw it (only a change to false resigns).
        var lastSeenFocus = false
        private var beganEditingAt: Date?
        init(_ parent: EditorView) { self.parent = parent }

        /// Editing began under a second ago: a `false` read back now is SwiftUI's, not the screen's.
        var justBeganEditing: Bool {
            beganEditingAt.map { Date().timeIntervalSince($0) < 1 } ?? false
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            beganEditingAt = Date()
            if let focus = parent.focus, !focus.wrappedValue { focus.wrappedValue = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            beganEditingAt = nil
            if let focus = parent.focus, focus.wrappedValue { focus.wrappedValue = false }
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText string: String) -> Bool {
            guard string.contains("\n") else { return true }
            if let onSubmit = parent.onSubmit { onSubmit() } else { textView.resignFirstResponder() }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.keyboardAppearance = .dark
        view.autocapitalizationType = .sentences
        view.adjustsFontForContentSizeCategory = false
        view.tintColor = UIColor(Color.ink)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let attrs = attributes(context.environment.dynamicTypeSize)
        view.typingAttributes = attrs
        if view.text != text || view.attributedText.length == 0 && !text.isEmpty {
            let selection = view.selectedRange
            view.attributedText = NSAttributedString(string: text, attributes: attrs)
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        }
        view.returnKeyType = returnKey
        view.textContainer.maximumNumberOfLines = lines.upperBound == 1 ? 1 : 0
        view.textContainer.lineBreakMode = lines.upperBound == 1 ? .byTruncatingTail : .byWordWrapping
        view.accessibilityLabel = label
        // `true` brings the keyboard up; a change to `false` takes it away. Only a change counts, and not
        // in the moment after editing began: the FocusState isn't attached to a SwiftUI-focusable view
        // (this is a UITextView), so SwiftUI can read it back as false right after the user taps in, and
        // resigning on any `false` dropped the keyboard under the first keystroke (found by the
        // tap-through UI test).
        if let focus {
            let wants = focus.wrappedValue
            let coordinator = context.coordinator
            let was = coordinator.lastSeenFocus
            coordinator.lastSeenFocus = wants
            if wants, !view.isFirstResponder {
                DispatchQueue.main.async { if view.window != nil { view.becomeFirstResponder() } }
            } else if !wants, was, view.isFirstResponder, !coordinator.justBeganEditing {
                DispatchQueue.main.async { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? ScreenMetrics.designWidth - 2 * Space.inset
        let lineHeight = style.lineHeight(for: context.environment.dynamicTypeSize)
        let measured = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let count = text.isEmpty ? 1 : max(1, Int((measured / lineHeight).rounded()))
        let shown = min(max(count, lines.lowerBound), lines.upperBound)
        let scrolls = count > lines.upperBound && lines.upperBound > 1
        if view.isScrollEnabled != scrolls {
            DispatchQueue.main.async { view.isScrollEnabled = scrolls }
        }
        return CGSize(width: width, height: CGFloat(shown) * lineHeight)
    }

    private func attributes(_ dts: DynamicTypeSize) -> [NSAttributedString.Key: Any] {
        let font = style.uiFont(for: dts)
        let lineHeight = style.lineHeight(for: dts)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakStrategy = []
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(Color.ink),
            .paragraphStyle: paragraph,
            .baselineOffset: (lineHeight - font.lineHeight) / 2,
        ]
        return attributes.merging(style.trackingAttributes(for: dts)) { $1 }
    }
}
