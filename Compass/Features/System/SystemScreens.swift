import SwiftUI
import CompassCore

/// System flow entry point. Every state is the live screen in that condition: I1 is Center (B1) with the
/// microphone off and I4 is the evening reflection (D3) with storage full, so the notice and "Type
/// instead" come from the same `TypeInsteadDock` the live rituals use. I2 and I3 are Today with a notice in
/// the notes row. I5 and I6 draw the lock screen and home screen as the reminders and widgets appear.
enum SystemScreens {
    /// I1 I2 I3 I4 I5 I6
    static let ids: [ScreenID] = Flow.system.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        switch id {
        case .i1: MorningCenterView()
        case .i4: EveningReflectView(id: id)
        case .i5: SystemLockScreenView()
        case .i6: SystemWidgetsView()
        default: TodayView(id: id)
        }
    }
}

/// Lock and home screen backdrop on I5/I6 (#0E0E10).
extension Color {
    static let systemBackdrop = Color(hex: 0x0E0E10)
}

// MARK: - I5 · Notifications

/// The lock screen at 07:00: the morning reminder shows the goal; last night's shows the step.
/// Same text the scheduler sends (`NotificationPlanner.body`).
struct SystemLockScreenView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rhythm = model.settings.rhythm
        let yesterday = model.snapshot.day(model.todayKey.adding(days: -1, calendar: model.calendar))
        FlowScreen(background: .systemBackdrop) {
            VStack(spacing: 0) {
                CompassText(dateText, style: .heading, color: .noticeInk)
                CompassText("\(rhythm.morning.hour):" + String(format: "%02d", rhythm.morning.minute), style: .clock)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .dynamicTypeSize(.large)
            .accessibilityElement(children: .combine)
            .region(.focalTop)

            VStack(spacing: Space.xs) {
                if let morning = NotificationPlanner.body(for: .morning, goal: model.goal, day: model.today) {
                    SystemNotificationBanner(time: "now", message: morning)
                }
                if let evening = NotificationPlanner.body(for: .evening, goal: model.goal, day: yesterday) {
                    SystemNotificationBanner(time: "yesterday \(rhythm.evening.description)", message: evening)
                        .opacity(0.8)
                }
            }
            .region(.growsUp(bottom: 656))
        }
    }

    private var dateText: String {
        // The user's locale; the fixture calendar's en_GB keeps the board's "Tuesday 10 November".
        let f = DateFormatter()
        f.calendar = model.calendar
        f.locale = model.calendar.locale ?? .autoupdatingCurrent
        f.timeZone = model.calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f.string(from: model.now)
    }
}

/// A notification as iOS draws it on the lock screen (system.html `.ntf`).
struct SystemNotificationBanner: View {
    var time: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            SystemAppIcon()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    CompassText("Compass", style: .caption, weight: .semibold).lineLimit(1)
                    Spacer(minLength: Space.xs)
                    CompassText(time, style: .caption, color: .ink2).lineLimit(1).fixedSize()
                }
                CompassText(message, style: .caption, color: Color(hex: 0xE6E6E8))
            }
        }
        .padding(Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0x2C2C30, opacity: 0.94), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The app icon mark: ground tile, hairline border, ink ring.
struct SystemAppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.ground)
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.line2, lineWidth: 1)
            Circle().strokeBorder(Color.ink, lineWidth: 3).frame(width: 16, height: 16)
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

// MARK: - I6 · Widgets

/// The home screen with the medium and small widgets, drawn with the widget's own views
/// (`TodayWidgetContent`). The circle completes today's step here too. In the app the widget's text is set
/// with `CompassText` (the board's line breaks); the widget extension itself can only use `Text`.
struct SystemWidgetsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let data = TodayWidgetData(snapshot: model.snapshot, day: model.todayKey)
        FlowScreen(background: .systemBackdrop) {
            VStack(spacing: Space.m) {
                widget(data, .medium)
                    .frame(height: 160)
                HStack(alignment: .top, spacing: Space.m) {
                    widget(data, .small)
                        .frame(width: 160, height: 160)
                    appGrid(columns: 2, count: 4, rowSpacing: 28)
                }
                appGrid(columns: 4, count: 8)
            }
            .dynamicTypeSize(.large)
            .region(.custom(top: 72, bottom: nil))
        }
    }

    private func widget(_ data: TodayWidgetData, _ layout: TodayWidgetLayout) -> some View {
        TodayWidgetContent(data: data, layout: layout, text: { text, style, weight, color, lines in
            CompassText(text, style: style, weight: weight, color: color).lineLimit(lines)
        }) { done in
            Button {
                model.setStepDone(!done)
                if !done {
                    Feedback.complete()
                    Feedback.announce("Done, undo available")
                }
            } label: {
                TodayWidgetCircle(done: done)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "Done. Tap to reopen" : "Mark step done")
        }
        .background(Color.raised, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func appGrid(columns: Int, count: Int, rowSpacing: CGFloat = Space.m) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.m), count: columns), spacing: rowSpacing) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.raised).frame(height: 64)
            }
        }
        .accessibilityHidden(true)
    }
}
