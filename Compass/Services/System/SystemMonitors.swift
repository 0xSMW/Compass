import Foundation
import AVFAudio
import Speech
import UserNotifications
import CompassCore

/// Live permission status for the three things Compass asks for. Feeds `SystemConditions`.
enum PermissionMonitor {
    static var microphone: PermissionState {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        default: .notDetermined
        }
    }

    static func requestMicrophone() async -> PermissionState {
        await AVAudioApplication.requestRecordPermission() ? .granted : .denied
    }

    static var speech: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    static func notifications() async -> PermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        default: return .notDetermined
        }
    }
}

/// I4: free space on the phone's volume, checked before a recording starts.
enum StorageMonitor {
    static var availableBytes: Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    static var isFull: Bool { StorageRules.isFull(availableBytes: availableBytes) }
}

/// Schedules the two daily reminders (I5) with UNUserNotificationCenter: 07:00 shows the goal, 21:00
/// shows the day's step. One-off requests for the next 7 days, re-planned whenever the data, rhythm or
/// time zone changes, so the evening text is always today's step. Silent: the completion click is the
/// app's only sound.
@MainActor
final class NotificationScheduler {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async -> PermissionState {
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge])) ?? false
        return granted ? .granted : await PermissionMonitor.notifications()
    }

    func reschedule(snapshot: CompassSnapshot, calendar: Calendar, now: Date) async {
        let status = await PermissionMonitor.notifications()
        let plan = status == .granted ? NotificationPlanner(calendar: calendar).plan(snapshot: snapshot, now: now) : []
        let wanted = Set(plan.map(\.identifier))
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix(NotificationPlanner.identifierPrefix) && !wanted.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        for reminder in plan {
            let content = UNMutableNotificationContent()
            content.body = reminder.body
            content.sound = nil
            content.threadIdentifier = NotificationPlanner.identifierPrefix + reminder.kind.rawValue
            content.userInfo = ["kind": reminder.kind.rawValue, "day": reminder.day.description]
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
            components.timeZone = calendar.timeZone
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            // Same identifier replaces the pending request, so the text follows today's step.
            try? await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
        }
    }

    func removeAll() {
        center.getPendingNotificationRequests { requests in
            let ours = requests.map(\.identifier).filter { $0.hasPrefix(NotificationPlanner.identifierPrefix) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ours)
        }
    }
}

/// Opening a reminder opens the app on the screen for the moment (Center at 07:00, the evening
/// question at 21:00). Reminders that arrive while Compass is open stay quiet.
final class NotificationTapHandler: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (@MainActor () -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let open = onOpen
        Task { @MainActor in
            open?()
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.list])
    }
}
