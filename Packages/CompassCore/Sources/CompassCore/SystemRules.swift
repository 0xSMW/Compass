import Foundation

// MARK: - Time zone (I3: the day follows you)

/// The device moved to a new time zone while the rhythm was following the device.
public struct TimeZoneChange: Hashable, Sendable {
    /// Zone the rhythm followed before ("Asia/Bangkok").
    public var previousID: String
    /// Zone the device is in now ("Asia/Tokyo").
    public var currentID: String

    public init(previousID: String, currentID: String) {
        self.previousID = previousID
        self.currentID = currentID
    }

    public var previousCity: String { TimeZoneRules.city(for: previousID) }
    public var currentCity: String { TimeZoneRules.city(for: currentID) }
}

/// What to do after looking at the device's time zone.
public struct TimeZoneObservation: Hashable, Sendable {
    /// Show the I3 notice for this change (nil = nothing to say).
    public var change: TimeZoneChange?
    /// The zone to remember as "last seen on this device".
    public var lastSeenID: String
    /// The zone the rhythm should be pinned to (`Settings.timeZoneID`); nil follows the device.
    public var pinnedID: String?

    public init(change: TimeZoneChange?, lastSeenID: String, pinnedID: String?) {
        self.change = change
        self.lastSeenID = lastSeenID
        self.pinnedID = pinnedID
    }
}

/// Pure rules for following the device's time zone.
///
/// - By default (`Settings.timeZoneID == nil`) today and the 07:00 / 21:00 rhythm follow the device.
/// - When the device zone differs from the last one seen, the I3 notice appears in the notes row until
///   the user answers it: **OK** (`acknowledge`) keeps following the device; **Keep Bangkok time**
///   (`keepPrevious`) pins the rhythm to the old zone.
/// - A pinned zone is released automatically once the device is back in that zone.
public enum TimeZoneRules {
    /// "Asia/Tokyo" → "Tokyo", "America/New_York" → "New York".
    public static func city(for identifier: String) -> String {
        let last = identifier.split(separator: "/").last.map(String.init) ?? identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    public static func observe(deviceZoneID: String, lastSeenID: String?, pinnedID: String?) -> TimeZoneObservation {
        if let pinnedID {
            // Back in the pinned zone: follow the device again, nothing to say.
            if pinnedID == deviceZoneID { return TimeZoneObservation(change: nil, lastSeenID: deviceZoneID, pinnedID: nil) }
            // The user chose to keep another zone's times; don't nag on every move.
            return TimeZoneObservation(change: nil, lastSeenID: deviceZoneID, pinnedID: pinnedID)
        }
        guard let lastSeenID, lastSeenID != deviceZoneID else {
            return TimeZoneObservation(change: nil, lastSeenID: deviceZoneID, pinnedID: nil)
        }
        // Keep `lastSeenID` until the user answers, so the notice survives relaunches.
        return TimeZoneObservation(change: TimeZoneChange(previousID: lastSeenID, currentID: deviceZoneID),
                                   lastSeenID: lastSeenID, pinnedID: nil)
    }

    /// OK: follow the new zone.
    public static func acknowledge(_ change: TimeZoneChange) -> TimeZoneObservation {
        TimeZoneObservation(change: nil, lastSeenID: change.currentID, pinnedID: nil)
    }

    /// Keep <previous> time: pin the rhythm to the old zone.
    public static func keepPrevious(_ change: TimeZoneChange) -> TimeZoneObservation {
        TimeZoneObservation(change: nil, lastSeenID: change.currentID, pinnedID: change.previousID)
    }
}

// MARK: - Notifications (I5: morning shows the goal, evening shows the step)

public enum ReminderKind: String, Hashable, Sendable, Codable {
    case morning
    case evening
}

public struct PlannedReminder: Hashable, Sendable {
    public var kind: ReminderKind
    public var day: DayKey
    public var time: TimeOfDay
    /// Fire date in the rhythm's calendar.
    public var date: Date
    /// Notification body. The title is the app name ("Compass"), added by the system.
    public var body: String
    /// Repeats every week on `weekday` at `time` (a repeating calendar trigger), so reminders keep
    /// coming while the app isn't opened. `date` is then the first fire date.
    public var repeatsWeekly: Bool
    /// Gregorian weekday (1 = Sunday … 7 = Saturday) of `day`.
    public var weekday: Int

    /// Stable identifier: "compass.morning.2026-11-10" for a one-off, "compass.morning.weekly.3" for a
    /// weekly repeat (one per weekday, so re-planning replaces it in place).
    public var identifier: String {
        repeatsWeekly
            ? "\(NotificationPlanner.identifierPrefix)\(kind.rawValue).weekly.\(weekday)"
            : "\(NotificationPlanner.identifierPrefix)\(kind.rawValue).\(day)"
    }

    public init(kind: ReminderKind, day: DayKey, time: TimeOfDay, date: Date, body: String,
                repeatsWeekly: Bool = false, weekday: Int = 0) {
        self.kind = kind
        self.day = day
        self.time = time
        self.date = date
        self.body = body
        self.repeatsWeekly = repeatsWeekly
        self.weekday = weekday
    }
}

/// Plans the 07:00 and 21:00 reminders for the next few days. Pure; the app hands the result to
/// UNUserNotificationCenter and re-plans whenever the data, the rhythm or the time zone changes.
public struct NotificationPlanner: Sendable {
    public static let identifierPrefix = "compass."
    /// Evening fallback when the day has no step (same question as D2).
    public static let noStepEveningBody = "Did you move toward it today?"

    public var calendar: Calendar
    public var daysAhead: Int

    public init(calendar: Calendar, daysAhead: Int = 7) {
        self.calendar = calendar
        self.daysAhead = daysAhead
    }

    /// Morning: the goal. Evening: the day's step (or the D2 question when there is none).
    public static func body(for kind: ReminderKind, goal: Goal?, day: Day?) -> String? {
        guard let goal else { return nil }
        switch kind {
        case .morning: return goal.text
        case .evening: return day?.step?.title ?? noStepEveningBody
        }
    }

    public func plan(snapshot: CompassSnapshot, now: Date) -> [PlannedReminder] {
        guard snapshot.settings.notificationsEnabled, let goal = snapshot.goal, goal.status == .active else { return [] }
        let rhythm = snapshot.settings.rhythm.clamped
        let today = DayKey(now, calendar: calendar)
        var result: [PlannedReminder] = []
        for offset in 0..<max(0, daysAhead) {
            let key = today.adding(days: offset, calendar: calendar)
            let day = snapshot.day(key)
            let morning = key.date(in: calendar, hour: rhythm.morning.hour, minute: rhythm.morning.minute)
            if morning > now, !(day?.morningHandled ?? false), let body = Self.body(for: .morning, goal: goal, day: day) {
                result.append(PlannedReminder(kind: .morning, day: key, time: rhythm.morning, date: morning, body: body))
            }
            let evening = key.date(in: calendar, hour: rhythm.evening.hour, minute: rhythm.evening.minute)
            if evening > now, day?.reflection == nil, let body = Self.body(for: .evening, goal: goal, day: day) {
                result.append(PlannedReminder(kind: .evening, day: key, time: rhythm.evening, date: evening, body: body))
            }
        }
        return result
    }

    /// What the app hands to UNUserNotificationCenter: reminders that keep firing while the app is
    /// closed. One weekly repeating reminder per weekday and kind (14 requests, well under iOS's 64):
    /// - Morning: the goal, every day. Only today's is left out, when the morning was already handled
    ///   before its time (it returns when the app next re-plans).
    /// - Evening: today, a one-off with today's step (the text changes daily, so it can't repeat) and no
    ///   reminder once reflected; every other weekday repeats the D2 question.
    /// The app re-plans on every change, on each foreground and from a background refresh, so the step
    /// text and handled days stay current; when it can't, the weekly repeats still arrive.
    public func schedule(snapshot: CompassSnapshot, now: Date) -> [PlannedReminder] {
        guard snapshot.settings.notificationsEnabled, let goal = snapshot.goal, goal.status == .active else { return [] }
        let rhythm = snapshot.settings.rhythm
        let today = DayKey(now, calendar: calendar)
        var result: [PlannedReminder] = []
        for offset in 0..<7 {
            let key = today.adding(days: offset, calendar: calendar)
            let day = snapshot.day(key)
            let weekday = calendar.component(.weekday, from: key.date(in: calendar, hour: 12, minute: 0))

            func firstFire(_ time: TimeOfDay) -> Date {
                let date = key.date(in: calendar, hour: time.hour, minute: time.minute)
                return date > now ? date : key.adding(days: 7, calendar: calendar).date(in: calendar, hour: time.hour, minute: time.minute)
            }

            let morning = key.date(in: calendar, hour: rhythm.morning.hour, minute: rhythm.morning.minute)
            let handledEarly = offset == 0 && morning > now && (day?.morningHandled ?? false)
            if !handledEarly {
                result.append(PlannedReminder(kind: .morning, day: key, time: rhythm.morning, date: firstFire(rhythm.morning),
                                              body: goal.text, repeatsWeekly: true, weekday: weekday))
            }

            let evening = key.date(in: calendar, hour: rhythm.evening.hour, minute: rhythm.evening.minute)
            if offset == 0, evening > now {
                if day?.reflection != nil { continue }
                if let title = day?.step?.title {
                    result.append(PlannedReminder(kind: .evening, day: key, time: rhythm.evening, date: evening,
                                                  body: title, weekday: weekday))
                    continue
                }
            }
            result.append(PlannedReminder(kind: .evening, day: key, time: rhythm.evening, date: firstFire(rhythm.evening),
                                          body: Self.noStepEveningBody, repeatsWeekly: true, weekday: weekday))
        }
        return result
    }
}

// MARK: - Storage (I4)

public enum StorageRules {
    /// Below this many free bytes a recording can't start ("Your iPhone is full").
    public static let minimumFreeBytesForRecording: Int64 = 50 * 1024 * 1024

    public static func isFull(availableBytes: Int64?) -> Bool {
        guard let availableBytes else { return false }
        return availableBytes < minimumFreeBytesForRecording
    }
}
