import SwiftUI
import UIKit
import CompassCore

/// Settings (settings.html): H1 one flat list; H2 delete everything (export first, destructive on 712).
enum SettingsScreens {
    /// H1 H2
    static let ids: [ScreenID] = Flow.settings.screens

    @MainActor @ViewBuilder
    static func view(for id: ScreenID) -> some View {
        switch id {
        case .h1: SettingsListView()
        case .h2: DeleteEverythingView()
        // ScreenRegistry routes only this flow's IDs here; every one has a case above.
        default: EmptyView()
        }
    }
}

// MARK: - H1 · Settings

struct SettingsListView: View {
    @Environment(AppModel.self) private var model
    @State private var timeSheet: TimeSheet?
    @State private var export: ExportItems?
    @State private var soundOn = SoundSetting.isOn
    @State private var rhythmDraft = Rhythm()

    enum TimeSheet: String, Identifiable {
        case morning, evening
        var id: String { rawValue }
    }

    var body: some View {
        let s = model.settings
        FlowScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    CompassText("Settings", style: .title).accessibilityAddTraits(.isHeader)

                    VStack(spacing: 0) {
                        ListRow(title: "Your goal", action: { model.go(.g1) }) { chevron }
                        ListRow(title: "Morning", value: s.rhythm.morning.description, valueStyle: .bodyMono,
                                action: { timeSheet = .morning })
                        ListRow(title: "Evening", value: s.rhythm.evening.description, valueStyle: .bodyMono,
                                action: { timeSheet = .evening })
                        if model.showsRemindersRow {
                            // Only while reminders can't arrive (off after "Not now", or not allowed by
                            // iOS): the way back once I2 is dismissed. Same action as I2's "Turn on".
                            ListRow(title: "Reminders", value: "Off", action: { model.turnOnNotifications() })
                                .accessibilityHint("Turns on the morning and evening reminders")
                                .accessibilityIdentifier("settings-reminders")
                        }
                        ListRow(title: "Sound and haptics", value: soundOn ? "On" : "Off", action: {
                            soundOn.toggle()
                            SoundSetting.set(soundOn)
                        })
                        ListRow(title: "Start with", value: s.input == .voice ? "Voice" : "Typing", action: {
                            model.updateSettings { $0.input = $0.input == .voice ? .typing : .voice }
                        })
                        if model.cloudHelpConfigured {
                            ListRow(title: "Cloud help") {
                                CompassSwitch(label: "Cloud help", isOn: Binding(
                                    get: { model.settings.cloudAssist },
                                    set: { model.setCloudHelp($0) }
                                ))
                            }
                        } else {
                            // No endpoint in this build: say so instead of a switch that does nothing.
                            ListRow(title: "Cloud help", value: CloudHelpCopy.notSetUpValue)
                                .accessibilityHint(CloudHelpCopy.notSetUpFootnote)
                        }
                        ListRow(title: "Export everything", action: { startExport() }) { chevron }
                        ListRow(title: "Delete everything", tint: .destructive, action: { model.replace(with: .h2) })
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
                    }
                    .padding(.top, Space.m)

                    if !model.cloudHelpConfigured {
                        CompassText(CloudHelpCopy.notSetUpFootnote, style: .caption, color: .ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Space.s)
                            .accessibilityHidden(true) // read as the Cloud help row's hint
                    }
                }
                .padding(.horizontal, Space.inset)
                .padding(.bottom, Space.xl)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .region(.custom(top: 128, bottom: 844, inset: 0))

            NavBar(leading: .quietBack("Today") { leave() })
                .region(.nav)
        }
        .compassSheet(isPresented: Binding(get: { timeSheet != nil }, set: { if !$0 { timeSheet = nil } }), height: 392,
                      label: timeSheet == .morning ? "Morning time" : "Evening time") {
            if let sheet = timeSheet {
                TimeEditor(morning: sheet == .morning, rhythm: $rhythmDraft)
            }
        } actions: {
            PrimaryButton("Save") {
                // A6's limits (CompassCore): morning 04:00–11:45, evening 17:00–23:45.
                model.setRhythmFromSettings(rhythmDraft)
                timeSheet = nil
            }
        }
        .onChange(of: timeSheet) { _, sheet in
            if sheet != nil { rhythmDraft = model.settings.rhythm }
        }
        .exportSheet($export)
    }

    private var chevron: some View { RowChevron() }

    private func startExport() {
        let snapshot = model.snapshot
        Task { export = ExportItems(urls: await DataExport.prepare(snapshot)) }
    }

    private func leave() {
        if model.canGoBack { model.back() } else { model.goToEntry() }
    }
}

/// Morning / Evening time in a Compass sheet: the A6 row (− 07:00 +, 15-minute steps, the same ranges
/// as onboarding), Save on the 712 line.
private struct TimeEditor: View {
    let morning: Bool
    @Binding var rhythm: Rhythm

    var body: some View {
        CompassText(morning ? "Morning" : "Evening", style: .heading).accessibilityAddTraits(.isHeader)
        CompassText(morning ? "When Compass asks who you’ll be today." : "When Compass asks what you did today.", color: .ink2)
            .padding(.top, Space.xs)
        TimeStepperRow(icon: morning ? .sun : .moon, title: morning ? "Center" : "Look back",
                       time: morning ? rhythm.morning : rhythm.evening,
                       earlier: { rhythm = morning ? rhythm.movingMorning(by: -1) : rhythm.movingEvening(by: -1) },
                       later: { rhythm = morning ? rhythm.movingMorning(by: 1) : rhythm.movingEvening(by: 1) })
            .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
            .padding(.top, Space.m)
    }
}

// MARK: - H2 · Delete everything

struct DeleteEverythingView: View {
    @Environment(AppModel.self) private var model
    @State private var export: ExportItems?
    @State private var deleting = false

    var body: some View {
        let s = model.snapshot
        FlowScreen {
            CompassText("Settings", style: .title)
                .region(.focalTop)
                .accessibilityHidden(true)
            NavBar(leading: .quietBack("Today") {})
                .region(.nav)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .compassSheet(isPresented: Binding(get: { true }, set: { if !$0 { model.replace(with: .h1) } }), height: 392, label: "Delete everything") {
            ConfirmSheetContent(title: "Delete everything?", message: message(s))
        } actions: {
            SecondaryButton("Export first") { startExport() }
            PrimaryButton("Delete everything", role: .destructive) {
                guard !deleting else { return }
                deleting = true
                model.eraseEverything()
            }
        }
        .exportSheet($export)
    }

    private func startExport() {
        let snapshot = model.snapshot
        Task { export = ExportItems(urls: await DataExport.prepare(snapshot)) }
    }

    /// "212 steps, 186 memos and 2 past goals, on this iPhone and in iCloud. This can’t be undone."
    private func message(_ s: CompassSnapshot) -> String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        let parts = [plural(s.totalSteps, "step", "steps"), plural(s.memoCount, "memo", "memos"),
                     plural(s.pastGoals.count, "past goal", "past goals")]
        let list = parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        let place = (model.fixture != nil || LiveSync.iCloudInUse) ? "on this iPhone and in iCloud" : "on this iPhone"
        return "\(list), \(place). This can’t be undone."
    }
}

// MARK: - Export

struct ExportItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// The system share sheet for the export. The temporary files go when it finishes or is dismissed.
struct ExportShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in DataExport.cleanUp() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: UIActivityViewController, coordinator: ()) {
        DataExport.cleanUp()
    }
}

extension View {
    /// Share sheet for "Export everything" / "Export first", removing its temporary files afterwards.
    func exportSheet(_ export: Binding<ExportItems?>) -> some View {
        sheet(item: export, onDismiss: { DataExport.cleanUp() }) { items in
            ExportShareSheet(items: items.urls).ignoresSafeArea()
        }
    }
}

/// "Sound and haptics": per device, so it lives in UserDefaults and drives `Feedback.enabled`.
enum SoundSetting {
    static let key = "compass.soundAndHaptics"

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    @MainActor static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        Feedback.enabled = on
    }

    @MainActor static func apply() { Feedback.enabled = isOn }
}
