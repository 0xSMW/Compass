import SwiftUI
import UIKit
import CompassCore

// System services wired into the live app (owned by the System flow). Screenshots (`-screen`) keep
// using fixtures: every action here also works on fixture state without touching the phone.

extension View {
    /// Start the system services (permissions, storage, time zone, reminders, widget sync) for the live app.
    func systemServices() -> some View { modifier(SystemServicesModifier()) }
}

private struct SystemServicesModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task { model.system.start(model: model) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await model.system.refresh() } }
                if phase == .background, model.fixture == nil { ReminderRefresh.schedule() }
            }
            .onChange(of: model.snapshot) { old, new in
                model.system.scheduleReminders()
                if old.settings.rhythm != new.settings.rhythm { model.system.scheduleEntryTimer() }
            }
    }
}

extension AppModel {
    var isLiveSystem: Bool { fixture == nil && system.isLive }

    // MARK: I2 · Notifications off

    /// "07:00 and 21:00 can't reach you." sits in the notes row until dismissed.
    /// Also after "Not now" on A6 (reminders off while iOS has never asked): H1 has no notifications
    /// row, so this notice is the way to turn them back on.
    var showsNotificationsNotice: Bool {
        NotificationRules.showsOffNotice(enabled: settings.notificationsEnabled,
                                         status: conditions.notifications,
                                         dismissed: system.notificationsNoticeDismissed)
    }

    func dismissNotificationsNotice() { system.setNoticeDismissed(true) }

    func turnOnNotifications() {
        if isLiveSystem {
            Task { await system.turnOnNotifications() }
        } else {
            updateSettings { $0.notificationsEnabled = true }
            conditions.notifications = .granted
        }
    }

    /// Ask iOS for notification permission (onboarding A6, Settings). Returns the resulting state.
    func requestNotificationPermission() async -> PermissionState {
        guard isLiveSystem else { conditions.notifications = .granted; return .granted }
        return await system.requestNotifications()
    }

    // MARK: I3 · New time zone

    /// The I3 notice for the current calendar, if the device moved and the user hasn't answered.
    var timeZoneChange: TimeZoneChange? {
        guard let previous = conditions.previousTimeZoneID, previous != calendar.timeZone.identifier else { return nil }
        return TimeZoneChange(previousID: previous, currentID: calendar.timeZone.identifier)
    }

    /// OK / Keep <previous> time.
    func answerTimeZoneNotice(keepPrevious: Bool) {
        if isLiveSystem {
            system.answerTimeZone(keepPrevious: keepPrevious)
        } else {
            let previous = conditions.previousTimeZoneID
            conditions.previousTimeZoneID = nil
            if keepPrevious, let previous {
                updateSettings { $0.timeZoneID = previous }
                calendar.timeZone = TimeZone(identifier: previous) ?? calendar.timeZone
            }
        }
    }

    // MARK: I1 / I4 · Microphone and storage

    /// Check (and ask for) what a recording needs. nil = go ahead.
    func prepareToRecord() async -> RecordingBlock? {
        if isLiveSystem { return await system.prepareToRecord() }
        return RecordingBlock(conditions)
    }

    /// "Turn on the microphone": ask iOS if it hasn't asked yet, else open Compass in Settings.
    func turnOnMicrophone() {
        guard isLiveSystem else { conditions.microphone = .granted; return }
        Task {
            if PermissionMonitor.microphone == .notDetermined {
                conditions.microphone = await PermissionMonitor.requestMicrophone()
            } else {
                openSystemSettings()
            }
        }
    }

    /// "Manage storage" / permission links: Compass's page in the Settings app.
    func openSystemSettings() {
        guard fixture == nil, let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
