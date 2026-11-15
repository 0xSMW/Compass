import AppIntents
import SwiftUI
import WidgetKit
import CompassCore

@main
struct CompassWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayStepWidget()
    }
}

// MARK: - Intent

/// "Complete today's step without opening the app" (I6). Runs in the widget process, writes the
/// shared JSON store, and WidgetKit reloads the timeline afterwards.
struct CompleteStepIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete today’s step"
    static var description = IntentDescription("Marks today’s Compass step done. Tap again to reopen it.")

    @Parameter(title: "Done")
    var done: Bool

    init() { done = true }

    init(done: Bool) { self.done = done }

    func perform() async throws -> some IntentResult {
        let store = SharedStorage.makeStore()
        let snapshot = try store.load()
        let calendar = SharedStorage.calendar(for: snapshot.settings)
        let now = Date()
        try store.setStepDone(done, on: DayKey(now, calendar: calendar), at: now)
        return .result()
    }
}

// MARK: - Timeline

struct TodayStepEntry: TimelineEntry {
    var date: Date
    var goal: String?
    var step: String?
    var partSymbol: PartSymbol?
    var done: Bool

    static let placeholder = TodayStepEntry(date: .now, goal: Fixtures.goalText, step: Fixtures.stepTitle, partSymbol: .friends, done: false)
}

struct TodayStepProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayStepEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (TodayStepEntry) -> Void) {
        completion(context.isPreview ? .placeholder : entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayStepEntry>) -> Void) {
        let now = Date()
        let entry = entry(at: now)
        // Refresh at the next midnight so a new day starts empty.
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: now) ?? now)
        completion(Timeline(entries: [entry], policy: .after(tomorrow)))
    }

    private func entry(at date: Date) -> TodayStepEntry {
        let snapshot = (try? SharedStorage.makeStore().load()) ?? .empty
        let calendar = SharedStorage.calendar(for: snapshot.settings)
        let day = snapshot.day(DayKey(date, calendar: calendar))
        let step = day?.step
        return TodayStepEntry(
            date: date,
            goal: snapshot.goal?.text,
            step: step?.title,
            partSymbol: snapshot.goal?.part(step?.partID)?.symbol,
            done: step?.isDone ?? false
        )
    }
}

// MARK: - Views

struct TodayStepWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStorage.widgetKind, provider: TodayStepProvider()) { entry in
            TodayStepWidgetView(entry: entry)
                .containerBackground(Color.surface, for: .widget)
        }
        .configurationDisplayName("Today’s step")
        .description("Complete today’s step without opening the app.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct TodayStepWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayStepEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if family == .systemMedium, let goal = entry.goal {
                Text(goal).compassFont(.caption).foregroundStyle(.ink2).lineLimit(2)
            }
            if family == .systemSmall {
                stepTitle
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.xs) {
                if family == .systemMedium {
                    if let symbol = entry.partSymbol { Icon(CompassIcon(symbol)).foregroundStyle(.ink2) }
                    stepTitle.frame(maxWidth: .infinity, alignment: .leading)
                }
                if entry.step != nil {
                    Button(intent: CompleteStepIntent(done: !entry.done)) {
                        ZStack {
                            Circle().strokeBorder(Color.ink, lineWidth: 2)
                            if entry.done {
                                Circle().fill(Color.ink)
                                Icon(.ok, size: IconSize.s).foregroundStyle(.ground)
                            }
                        }
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.done ? "Done. Tap to reopen" : "Mark step done")
                }
            }
        }
        .foregroundStyle(.ink)
    }

    private var stepTitle: some View {
        Text(entry.step ?? (entry.goal == nil ? "Open Compass to set your goal" : "No step today"))
            .compassFont(.body, weight: .medium)
            .foregroundStyle(entry.step == nil ? Color.ink2 : Color.ink)
            .lineLimit(3)
    }
}
