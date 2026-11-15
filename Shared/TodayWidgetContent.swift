import SwiftUI
import CompassCore

/// What a Today widget shows. Built from the shared snapshot by the widget's timeline provider, and from
/// `AppModel` by the I6 board in the app.
struct TodayWidgetData: Hashable {
    var goal: String?
    var step: String?
    var partSymbol: PartSymbol?
    var done: Bool

    static let placeholder = TodayWidgetData(goal: Fixtures.goalText, step: Fixtures.stepTitle, partSymbol: .friends, done: false)

    init(goal: String?, step: String?, partSymbol: PartSymbol?, done: Bool) {
        self.goal = goal
        self.step = step
        self.partSymbol = partSymbol
        self.done = done
    }

    init(snapshot: CompassSnapshot, day: DayKey) {
        let step = snapshot.day(day)?.step
        self.init(goal: snapshot.goal?.text, step: step?.title, partSymbol: snapshot.goal?.part(step?.partID)?.symbol,
                  done: step?.isDone ?? false)
    }

    /// Text when there is no step: set a goal first, or plan one in the app.
    var emptyText: String { goal == nil ? "Open Compass to set your goal" : "No step today" }
}

enum TodayWidgetLayout {
    /// 2×2: step title on top, completion circle bottom-left (I6).
    case small
    /// 4×2: goal (caption) on top; part symbol · step · circle along the bottom (I6).
    case medium
    /// Lock screen: step and a circle.
    case rectangular
    /// Lock screen, one line of text.
    case inline
}

/// The widget's 44pt completion circle (kit.css `.c56.done` at 44): 2pt ink ring, filled with a check when done.
struct TodayWidgetCircle: View {
    var done: Bool
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.ink, lineWidth: 2)
            if done {
                Circle().fill(Color.ink)
                Icon(.ok, size: IconSize.s).foregroundStyle(.ground)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

/// Widget content per I6: raised card (#1C1C1F, radius 24, padding 16). The circle is supplied by the
/// host so the widget can wrap it in an App Intent button and the app in a plain button.
struct TodayWidgetContent<Toggle: View>: View {
    var data: TodayWidgetData
    var layout: TodayWidgetLayout
    @ViewBuilder var toggle: (Bool) -> Toggle

    var body: some View {
        switch layout {
        case .small: small
        case .medium: medium
        case .rectangular: rectangular
        case .inline: Text(data.step ?? data.emptyText)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            stepTitle(lines: 3)
            Spacer(minLength: 0)
            if data.step != nil { toggle(data.done) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Space.s)
        .foregroundStyle(.ink)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let goal = data.goal {
                Text(goal).compassFont(.caption).foregroundStyle(.ink2).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.xs) {
                if let symbol = data.partSymbol { Icon(CompassIcon(symbol), size: IconSize.s).foregroundStyle(.ink) }
                stepTitle(lines: 2).frame(maxWidth: .infinity, alignment: .leading)
                if data.step != nil { toggle(data.done) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Space.s)
        .foregroundStyle(.ink)
    }

    private var rectangular: some View {
        HStack(spacing: Space.xs) {
            Text(data.step ?? data.emptyText)
                .font(.custom(CompassType.Weight.medium.interTight, size: 15))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if data.step != nil { toggle(data.done) }
        }
    }

    private func stepTitle(lines: Int) -> some View {
        Text(data.step ?? data.emptyText)
            .compassFont(.body, weight: .medium)
            .foregroundStyle(data.step == nil ? Color.ink2 : Color.ink)
            .lineLimit(lines)
    }
}
