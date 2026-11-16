import SwiftUI

/// Maps design coordinates (390 × 844 frame) to the current screen.
///
/// Lines in the top half (y ≤ 422) are measured from the top of the screen; lines in the bottom
/// half from the bottom, so the 712 dock line keeps its distance from the home indicator on
/// taller phones. On a 390 × 844 screen (iPhone 16e/14/13) every value is exact.
struct ScreenMetrics: Equatable {
    var size: CGSize = CGSize(width: 390, height: 844)
    var safeArea: EdgeInsets = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)
    /// Top of the real software keyboard in this frame's coordinates, when it is up.
    var keyboardTop: CGFloat? = nil

    static let designHeight: CGFloat = 844
    static let designWidth: CGFloat = 390
    static let safeTop: CGFloat = 56
    static let safeBottom: CGFloat = 792

    /// Extra push-down when a device's real safe area is deeper than the design's 56.
    var topShift: CGFloat { max(0, safeArea.top - Self.safeTop) }

    /// Screen y for a design y.
    func y(_ designY: CGFloat) -> CGFloat {
        if designY <= Self.designHeight / 2 {
            return designY + topShift
        }
        return size.height - (Self.designHeight - designY)
    }

    /// Distance from the bottom of the screen for a design y.
    func bottomInset(_ designY: CGFloat) -> CGFloat { size.height - y(designY) }

    // MARK: Keyboard

    /// The system keyboard's height (with the predictive bar) on this kind of phone: 336 on Face ID
    /// phones (the boards' 508 on 844), 260 on Home-button phones (iPhone SE).
    var estimatedKeyboardHeight: CGFloat { safeArea.bottom > 0 ? Self.designHeight - 508 : 260 }

    /// Where the keyboard starts: the real one when up, else where it will be (drawn placeholders).
    var keyboardY: CGFloat { keyboardTop ?? (size.height - estimatedKeyboardHeight) }

    /// The lifted action: 56 tall, 16 above the keys (436–492 on 844).
    var aboveKeyboardSpan: (top: CGFloat, bottom: CGFloat) {
        let bottom = keyboardY - 16
        return (bottom - 56, bottom)
    }
}

private struct ScreenMetricsKey: EnvironmentKey {
    static let defaultValue = ScreenMetrics()
}

extension EnvironmentValues {
    var screenMetrics: ScreenMetrics {
        get { self[ScreenMetricsKey.self] }
        set { self[ScreenMetricsKey.self] = newValue }
    }
}

/// Fixed regions from the system sheet ("2 · Flow regions", "3 · Today regions", "4 · Sheets and keyboard").
/// Design y values on the 390 × 844 frame.
enum Region: Equatable {
    /// 56–104. Close/back left, quiet right. Inset 14 so 44pt buttons put text on the 24 line.
    case nav
    /// Subject at 128, up to 3 lines (grows down).
    case subject
    /// Focal text at 224, grows down; content clipped at the end of the transcript region (592).
    case focal
    /// Focal/title at 128 (onboarding titles, Today goal, History day subject), down to 592.
    case focalTop
    /// Middle / transcript band: from `top` to 592; scrolls inside.
    case middle(top: CGFloat)
    /// Waveform 616–656.
    case wave
    /// Dock 664–760, centred on the primary line 712 (mic, answers, Note, player).
    case dock
    /// Button dock: primary button 684–740 (centred on 712).
    case buttonDock
    /// Second button row above the primary: 612–668.
    case buttonDockHigh
    /// Link row 744–792 under the primary.
    case linkDock
    /// Labels row 768–792 (under choice circles).
    case labels
    /// Player 672–752 (80 tall, centred on 712).
    case player
    /// Today dock: keyboard + Note 680–744.
    case todayDock
    /// Action above the keyboard: 56 tall, 16 above the keys (436–492 on 844). Keyboard-relative: it
    /// follows the real keyboard, or the estimated one on screens the boards don't draw.
    case aboveKeyboard
    /// The keyboard itself (drawn placeholder in screenshots): from the keyboard's top to the bottom.
    case keyboard
    /// Anything else, in design coordinates. `bottom == nil` = natural height from `top`.
    case custom(top: CGFloat, bottom: CGFloat?, inset: CGFloat = 24)
    /// Bottom-anchored content that grows up from `bottom` (Today step card: 656).
    case growsUp(bottom: CGFloat)

    var top: CGFloat? {
        switch self {
        case .nav: 56
        case .subject: 128
        case .focal: 224
        case .focalTop: 128
        case .middle(let top): top
        case .wave: 616
        case .dock: 664
        case .buttonDock: 684
        case .buttonDockHigh: 612
        case .linkDock: 744
        case .labels: 768
        case .player: 672
        case .todayDock: 680
        case .aboveKeyboard: 436
        case .keyboard: 508
        case .custom(let top, _, _): top
        case .growsUp: nil
        }
    }

    var bottom: CGFloat? {
        switch self {
        case .nav: 104
        case .subject: nil
        case .focal, .focalTop, .middle: 592
        case .wave: 656
        case .dock: 760
        case .buttonDock: 740
        case .buttonDockHigh: 668
        case .linkDock: 792
        case .labels: 792
        case .player: 752
        case .todayDock: 744
        case .aboveKeyboard: 492
        case .keyboard: 844
        case .custom(_, let bottom, _): bottom
        case .growsUp(let bottom): bottom
        }
    }

    var inset: CGFloat {
        switch self {
        case .nav: 14
        case .keyboard: 0
        case .custom(_, _, let inset): inset
        default: Space.inset
        }
    }

    /// Vertical alignment of content inside the region.
    var alignment: Alignment {
        switch self {
        case .nav, .wave, .dock, .buttonDock, .buttonDockHigh, .linkDock, .labels, .player, .todayDock, .aboveKeyboard: .center
        case .growsUp: .bottom
        default: .top
        }
    }
}

private struct RegionModifier: ViewModifier {
    @Environment(\.screenMetrics) private var metrics
    let region: Region

    /// Screen y of the region's top and bottom. The keyboard regions follow the keyboard.
    private var span: (top: CGFloat?, bottom: CGFloat?) {
        switch region {
        case .aboveKeyboard:
            let s = metrics.aboveKeyboardSpan
            return (s.top, s.bottom)
        case .keyboard:
            return (metrics.keyboardY, metrics.size.height)
        default:
            return (region.top.map(metrics.y), region.bottom.map(metrics.y))
        }
    }

    func body(content: Content) -> some View {
        let (top, bottom) = span
        let height: CGFloat? = {
            if let top, let bottom { return max(0, bottom - top) }
            return nil
        }()
        let placed = content
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: .leading, vertical: region.alignment.vertical))
            .frame(height: height, alignment: Alignment(horizontal: .leading, vertical: region.alignment.vertical))
            .padding(.horizontal, region.inset)
        if let top {
            placed
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, top)
        } else {
            placed
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, metrics.size.height - (bottom ?? metrics.size.height))
        }
    }
}

extension View {
    /// Place this view on one of the spec's fixed regions. Use inside `FlowScreen` / `TodayScaffold`
    /// (or any view under `.screenMetricsFromGeometry()`).
    func region(_ region: Region) -> some View {
        modifier(RegionModifier(region: region))
    }
}

extension View {
    /// Place text that may outgrow its region at large sizes (spec, planned reflow: text reflows, controls
    /// keep their size and line). It sits on the region's lines as usual; when it no longer fits, it
    /// scrolls inside the region instead of running into the dock, starting fully visible at the top.
    func scrollingRegion(_ region: Region) -> some View {
        ViewThatFits(in: .vertical) {
            self
            ScrollView { self.frame(maxWidth: .infinity, alignment: .leading) }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
        }
        .region(region)
    }
}

/// Reads the screen's metrics inside a `FlowScreen` (keyboard-relative lines, real size), for layouts
/// that reflow on small phones: `ScreenMetricsReader { m in … }`.
struct ScreenMetricsReader<Content: View>: View {
    @Environment(\.screenMetrics) private var metrics
    @ViewBuilder var content: (ScreenMetrics) -> Content

    var body: some View { content(metrics) }
}
