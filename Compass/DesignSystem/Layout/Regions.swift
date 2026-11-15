import SwiftUI

/// Maps design coordinates (390 × 844 frame) to the current screen.
///
/// Lines in the top half (y ≤ 422) are measured from the top of the screen; lines in the bottom
/// half from the bottom, so the 712 dock line keeps its distance from the home indicator on
/// taller phones. On a 390 × 844 screen (iPhone 16e/14/13) every value is exact.
struct ScreenMetrics: Equatable {
    var size: CGSize = CGSize(width: 390, height: 844)
    var safeArea: EdgeInsets = EdgeInsets(top: 47, leading: 0, bottom: 34, trailing: 0)

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
    /// Action above the keyboard 436–492 (16 above keys at 508).
    case aboveKeyboard
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
        case .custom(_, let bottom, _): bottom
        case .growsUp(let bottom): bottom
        }
    }

    var inset: CGFloat {
        switch self {
        case .nav: 14
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

    func body(content: Content) -> some View {
        let top = region.top.map(metrics.y)
        let bottom = region.bottom.map(metrics.y)
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
