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
        default: ScreenStub(id: id)
        }
    }
}

// MARK: - H1 · Settings

struct SettingsListView: View {
    @Environment(AppModel.self) private var model
    @State private var timeSheet: TimeSheet?
    @State private var export: ExportItems?
    @State private var soundOn = SoundSetting.isOn

    enum TimeSheet: String, Identifiable {
        case morning, evening
        var id: String { rawValue }
    }

    var body: some View {
        let s = model.settings
        FlowScreen {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings").compassFont(.title).accessibilityAddTraits(.isHeader)

                    VStack(spacing: 0) {
                        ListRow(title: "Your goal", action: { model.go(.g1) }) { chevron }
                        ListRow(title: "Morning", action: { timeSheet = .morning }) {
                            MonoValue(text: s.rhythm.morning.description)
                        }
                        .accessibilityValue(s.rhythm.morning.description)
                        ListRow(title: "Evening", action: { timeSheet = .evening }) {
                            MonoValue(text: s.rhythm.evening.description)
                        }
                        .accessibilityValue(s.rhythm.evening.description)
                        ListRow(title: "Sound and haptics", value: soundOn ? "On" : "Off", action: {
                            soundOn.toggle()
                            SoundSetting.set(soundOn)
                        })
                        ListRow(title: "Start with", value: s.input == .voice ? "Voice" : "Typing", action: {
                            model.updateSettings { $0.input = $0.input == .voice ? .typing : .voice }
                        })
                        ListRow(title: "Cloud help") {
                            CompassSwitch(label: "Cloud help", isOn: Binding(
                                get: { model.settings.cloudAssist },
                                set: { model.setCloudHelp($0) }
                            ))
                        }
                        ListRow(title: "Export everything", action: { export = ExportItems(urls: DataExport.makeExport(model.snapshot)) }) { chevron }
                        ListRow(title: "Delete everything", tint: .destructive, action: { model.replace(with: .h2) })
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
                    }
                    .padding(.top, Space.m)
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
        .compassSheet(isPresented: Binding(get: { timeSheet != nil }, set: { if !$0 { timeSheet = nil } }), height: 456,
                      label: timeSheet == .morning ? "Morning time" : "Evening time") {
            if let sheet = timeSheet {
                TimeEditor(title: sheet == .morning ? "Morning" : "Evening",
                           caption: sheet == .morning ? "When Compass asks who you’ll be today." : "When Compass asks what you did today.",
                           time: sheet == .morning ? s.rhythm.morning : s.rhythm.evening,
                           calendar: model.calendar,
                           onSave: { t in
                               model.updateSettings { if sheet == .morning { $0.rhythm.morning = t } else { $0.rhythm.evening = t } }
                               timeSheet = nil
                           },
                           onCancel: { timeSheet = nil })
            }
        }
        .sheet(item: $export) { items in
            ExportShareSheet(items: items.urls).ignoresSafeArea()
        }
    }

    private var chevron: some View { Icon(.right, size: IconSize.s).foregroundStyle(.ink3) }

    private func leave() {
        if model.canGoBack { model.back() } else { model.goToEntry() }
    }
}

/// Morning / Evening time: a wheel in a Compass sheet, Save on the 712 line.
private struct TimeEditor: View {
    let title: String
    let caption: String
    let time: TimeOfDay
    let calendar: Calendar
    let onSave: (TimeOfDay) -> Void
    let onCancel: () -> Void
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).compassFont(.heading).accessibilityAddTraits(.isHeader).padding(.top, Space.xs)
            Text(caption).compassFont(.body).foregroundStyle(.ink2).padding(.top, Space.xs)
            DatePicker(title, selection: $date, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .environment(\.locale, Locale(identifier: "en_GB"))
                .environment(\.timeZone, calendar.timeZone)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipped()
            Spacer(minLength: 0)
            PrimaryButton("Save") { onSave(TimeOfDay(date, calendar: calendar)) }
            LinkButton("Cancel", action: onCancel)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 52)
        }
        .onAppear {
            date = DayKey(Date(), calendar: calendar).date(in: calendar, hour: time.hour, minute: time.minute)
        }
    }
}

/// settings.html `.v.mono`: times in IBM Plex Mono at body size, #A1A1A6.
private struct MonoValue: View {
    @Environment(\.dynamicTypeSize) private var dts
    let text: String

    var body: some View {
        Text(text)
            .font(.custom("IBMPlexMono-Regular", fixedSize: CompassType.body.size(for: dts)))
            .foregroundStyle(.ink2)
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
            Text("Settings").compassFont(.title)
                .region(.focalTop)
                .accessibilityHidden(true)
            NavBar(leading: .quietBack("Today") {})
                .region(.nav)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .compassSheet(isPresented: Binding(get: { true }, set: { if !$0 { model.replace(with: .h1) } }), height: 392, label: "Delete everything") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Delete everything?").compassFont(.heading).accessibilityAddTraits(.isHeader)
                    Text(message(s))
                        .compassFont(.body)
                        .foregroundStyle(.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Space.xs)
                Spacer(minLength: Space.s)
                SecondaryButton("Export first") { export = ExportItems(urls: DataExport.makeExport(model.snapshot)) }
                PrimaryButton("Delete everything", role: .destructive) {
                    guard !deleting else { return }
                    deleting = true
                    model.eraseEverything()
                }
                .padding(.top, Space.s)
                LinkButton("Cancel") { model.replace(with: .h1) }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                    .padding(.bottom, 52)
            }
        }
        .sheet(item: $export) { items in
            ExportShareSheet(items: items.urls).ignoresSafeArea()
        }
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

/// The system share sheet for the export files.
struct ExportShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
