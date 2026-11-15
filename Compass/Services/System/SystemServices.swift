import Foundation
import Observation
import UIKit
import UserNotifications
import CompassCore

/// Keeps the live app in step with the phone: permissions and storage feed `model.conditions`, the
/// device time zone drives the I3 notice and the rhythm's calendar, the 07:00 / 21:00 reminders are
/// re-planned on every change, and changes the widget made to the shared store are picked up when the
/// app becomes active. Started once from `RootView` (`.systemServices()`); never runs with `-screen`.
@MainActor
@Observable
final class SystemServices {
    static let shared = SystemServices()

    /// I2 was dismissed (per device). Shown again once notifications have worked and been lost.
    private(set) var notificationsNoticeDismissed: Bool

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let scheduler = NotificationScheduler()
    @ObservationIgnored private let tapHandler = NotificationTapHandler()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var rescheduleTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Key {
        static let lastSeenZone = "compass.system.lastSeenTimeZone"
        static let noticeDismissed = "compass.system.notificationsNoticeDismissed"
    }

    private init() {
        notificationsNoticeDismissed = UserDefaults.standard.bool(forKey: Key.noticeDismissed)
    }

    var isLive: Bool { started }

    // MARK: Lifecycle

    func start(model: AppModel) {
        guard !started, model.fixture == nil else { return }
        started = true
        self.model = model

        tapHandler.onOpen = { [weak self] in self?.model?.goToEntry() }
        UNUserNotificationCenter.current().delegate = tapHandler

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceClockChanged() }
        })
        observers.append(center.addObserver(forName: UIApplication.significantTimeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deviceClockChanged() }
        })
        Task { await refresh() }
    }

    /// Re-read everything (launch, and each time the app becomes active).
    func refresh() async {
        guard let model else { return }
        reloadFromStore(model)
        NSTimeZone.resetSystemTimeZone()
        observeTimeZone(model)

        var c = model.conditions
        c.microphone = PermissionMonitor.microphone
        c.speech = PermissionMonitor.speech
        c.notifications = await PermissionMonitor.notifications()
        c.storageFull = StorageMonitor.isFull
        if c != model.conditions { model.conditions = c }
        if c.notifications == .granted, notificationsNoticeDismissed { setNoticeDismissed(false) }

        moveToEntryIfStale(model)
        scheduleReminders()
    }

    private func deviceClockChanged() {
        guard let model else { return }
        NSTimeZone.resetSystemTimeZone()
        observeTimeZone(model)
        moveToEntryIfStale(model)
        scheduleReminders()
    }

    /// The widget completes steps in its own process; adopt the shared file when it differs.
    private func reloadFromStore(_ model: AppModel) {
        guard let stored = try? model.store.load(), stored != model.snapshot else { return }
        // A local change (made on this phone), so it syncs and the widget reloads like any other.
        model.commit(stored)
    }

    /// Opened on Today but the day moved on (a new morning, or 21:00 passed): show the right screen.
    private func moveToEntryIfStale(_ model: AppModel) {
        guard model.path.count == 1, model.current.flow == .today else { return }
        if model.entryScreen.flow != .today { model.goToEntry() }
    }

    // MARK: Time zone (I3)

    private func observeTimeZone(_ model: AppModel) {
        let observation = TimeZoneRules.observe(deviceZoneID: TimeZone.current.identifier,
                                                lastSeenID: defaults.string(forKey: Key.lastSeenZone),
                                                pinnedID: model.settings.timeZoneID)
        apply(observation, to: model)
    }

    /// OK (follow the device) or Keep <old> time (pin the rhythm to the old zone).
    func answerTimeZone(keepPrevious: Bool) {
        guard let model, let previous = model.conditions.previousTimeZoneID else { return }
        let change = TimeZoneChange(previousID: previous, currentID: TimeZone.current.identifier)
        apply(keepPrevious ? TimeZoneRules.keepPrevious(change) : TimeZoneRules.acknowledge(change), to: model)
        moveToEntryIfStale(model)
        scheduleReminders()
    }

    private func apply(_ observation: TimeZoneObservation, to model: AppModel) {
        defaults.set(observation.lastSeenID, forKey: Key.lastSeenZone)
        if model.settings.timeZoneID != observation.pinnedID {
            model.updateSettings { $0.timeZoneID = observation.pinnedID }
        }
        if model.conditions.previousTimeZoneID != observation.change?.previousID {
            model.conditions.previousTimeZoneID = observation.change?.previousID
        }
        let calendar = SharedStorage.calendar(for: model.settings)
        if calendar.timeZone != model.calendar.timeZone { model.calendar = calendar }
    }

    // MARK: Notifications (I2, I5)

    func scheduleReminders() {
        guard let model else { return }
        let snapshot = model.snapshot, calendar = model.calendar, now = model.now
        rescheduleTask?.cancel()
        rescheduleTask = Task { [scheduler] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await scheduler.reschedule(snapshot: snapshot, calendar: calendar, now: now)
        }
    }

    /// Ask for notification permission (A6, I2 "Turn on" before iOS has asked). Returns the new state.
    func requestNotifications() async -> PermissionState {
        let state = await scheduler.requestAuthorization()
        model?.conditions.notifications = state
        scheduleReminders()
        return state
    }

    /// I2 "Turn on": switch reminders on and ask iOS, or open Compass's notification settings once denied.
    func turnOnNotifications() async {
        guard let model else { return }
        if !model.settings.notificationsEnabled { model.updateSettings { $0.notificationsEnabled = true } }
        switch await PermissionMonitor.notifications() {
        case .notDetermined:
            _ = await requestNotifications()
        case .denied:
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { _ = await UIApplication.shared.open(url) }
        case .granted:
            model.conditions.notifications = .granted
            scheduleReminders()
        }
    }

    func setNoticeDismissed(_ dismissed: Bool) {
        notificationsNoticeDismissed = dismissed
        if started { defaults.set(dismissed, forKey: Key.noticeDismissed) }
    }

    // MARK: Recording checks (I1, I4)

    /// Before a recording: ask for the microphone if iOS hasn't yet, then report what blocks it.
    func prepareToRecord() async -> RecordingBlock? {
        guard let model else { return nil }
        if PermissionMonitor.microphone == .notDetermined { _ = await model.recorder.requestPermission() }
        if PermissionMonitor.microphone == .notDetermined { _ = await PermissionMonitor.requestMicrophone() }
        if PermissionMonitor.speech == .notDetermined { _ = await model.transcriber.requestPermission() }
        model.conditions.microphone = PermissionMonitor.microphone
        model.conditions.speech = PermissionMonitor.speech
        model.conditions.storageFull = StorageMonitor.isFull
        return RecordingBlock(model.conditions)
    }
}

/// Why a recording can't start.
enum RecordingBlock: Equatable {
    /// I1: "The microphone is off for Compass."
    case microphoneOff
    /// I4: "Your iPhone is full, so audio can’t be saved."
    case storageFull

    init?(_ conditions: SystemConditions) {
        if conditions.microphone == .denied { self = .microphoneOff; return }
        if conditions.storageFull { self = .storageFull; return }
        return nil
    }
}
