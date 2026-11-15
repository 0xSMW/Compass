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
/// shared JSON store, and WidgetKit reloads the timeline afterwards. The app picks the change up from
/// the store when it becomes active. Tap for completion, never voice: the intent is not offered to Siri.
struct CompleteStepIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete today’s step"
    static var description = IntentDescription("Marks today’s Compass step done. Tap again to reopen it.")
    static var isDiscoverable: Bool = false

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
    var data: TodayWidgetData

    static let placeholder = TodayStepEntry(date: .now, data: .placeholder)
}

struct TodayStepProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayStepEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (TodayStepEntry) -> Void) {
        completion(context.isPreview ? .placeholder : entry(at: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayStepEntry>) -> Void) {
        let now = Date()
        let snapshot = (try? SharedStorage.makeStore().load()) ?? .empty
        let calendar = SharedStorage.calendar(for: snapshot.settings)
        // The app reloads the timeline whenever it changes today's step; otherwise refresh at the
        // rhythm's next midnight so a new day starts empty.
        let today = DayKey(now, calendar: calendar)
        let midnight = today.adding(days: 1, calendar: calendar).date(in: calendar)
        let entries = [entry(at: now, snapshot: snapshot, calendar: calendar),
                       entry(at: midnight, snapshot: snapshot, calendar: calendar)]
        completion(Timeline(entries: entries, policy: .after(midnight)))
    }

    private func entry(at date: Date) -> TodayStepEntry {
        let snapshot = (try? SharedStorage.makeStore().load()) ?? .empty
        return entry(at: date, snapshot: snapshot, calendar: SharedStorage.calendar(for: snapshot.settings))
    }

    private func entry(at date: Date, snapshot: CompassSnapshot, calendar: Calendar) -> TodayStepEntry {
        TodayStepEntry(date: date, data: TodayWidgetData(snapshot: snapshot, day: DayKey(date, calendar: calendar)))
    }
}

// MARK: - Views

struct TodayStepWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedStorage.widgetKind, provider: TodayStepProvider()) { entry in
            TodayStepWidgetView(entry: entry)
        }
        .configurationDisplayName("Today’s step")
        .description("Complete today’s step without opening the app.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct TodayStepWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayStepEntry

    var body: some View {
        switch family {
        case .accessoryRectangular, .accessoryInline:
            content
                .containerBackground(for: .widget) { Color.clear }
        default:
            content
                .containerBackground(Color.raised, for: .widget)
        }
    }

    private var layout: TodayWidgetLayout {
        switch family {
        case .systemMedium: .medium
        case .accessoryRectangular: .rectangular
        case .accessoryInline: .inline
        default: .small
        }
    }

    private var content: some View {
        TodayWidgetContent(data: entry.data, layout: layout) { done in
            Button(intent: CompleteStepIntent(done: !done)) {
                if family == .accessoryRectangular {
                    ZStack {
                        Circle().strokeBorder(lineWidth: 2)
                        if done { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
                    }
                    .frame(width: 28, height: 28)
                } else {
                    TodayWidgetCircle(done: done)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Done. Tap to reopen" : "Mark step done")
        }
    }
}
