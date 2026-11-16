import Foundation

// MARK: - Goal

/// The symbol drawn next to a goal part. Raw values match the ids in
/// design/compass-v3/source/tools/symbols.html (the app renders `icon-<rawValue>`).
public enum PartSymbol: String, Codable, Hashable, Sendable, CaseIterable {
    case wealth = "we"
    case strength = "sg"
    case friends = "fr"
    case flag
    case sun
    case moon
}

public struct GoalPart: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var symbol: PartSymbol
    /// Removing a part archives it; its past steps stay visible.
    public var isArchived: Bool

    public init(id: UUID = UUID(), title: String, symbol: PartSymbol, isArchived: Bool = false) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.isArchived = isArchived
    }
}

public enum GoalStatus: String, Codable, Hashable, Sendable {
    case active
    case achieved
    case replaced
}

public struct Goal: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// One sentence. It can have parts.
    public var text: String
    public var parts: [GoalPart]
    public var createdAt: Date
    public var status: GoalStatus
    public var endedAt: Date?
    /// Day 3 answer to "Why does this matter to you?" (B7). Played back on hard days.
    public var why: Note?
    /// True once B7 has been shown (asked once, skippable).
    public var whyAsked: Bool
    /// Last edit on the device that made it (sync picks the newer version of the same goal). nil in
    /// data saved before per-item sync stamps; `createdAt` stands in.
    public var updatedAt: Date?
    /// true: a sync merge, not the user, moved this goal to past goals (two goals made on devices that
    /// hadn't seen each other; the earlier one stays current). Such a past goal doesn't count as "this
    /// device knew it and ended it", so it never outvotes a device that still holds it as current. Cleared
    /// when it comes back as current, and when this device sets a new goal (it has then moved on knowingly).
    /// nil otherwise and in older data.
    public var demotedByMerge: Bool?

    public init(
        id: UUID = UUID(),
        text: String,
        parts: [GoalPart] = [],
        createdAt: Date,
        status: GoalStatus = .active,
        endedAt: Date? = nil,
        why: Note? = nil,
        whyAsked: Bool = false,
        updatedAt: Date? = nil,
        demotedByMerge: Bool? = nil
    ) {
        self.id = id
        self.text = text
        self.parts = parts
        self.createdAt = createdAt
        self.status = status
        self.endedAt = endedAt
        self.why = why
        self.whyAsked = whyAsked
        self.updatedAt = updatedAt
        self.demotedByMerge = demotedByMerge
    }

    public var activeParts: [GoalPart] { parts.filter { !$0.isArchived } }

    public func part(_ id: UUID?) -> GoalPart? {
        guard let id else { return nil }
        return parts.first { $0.id == id }
    }
}

// MARK: - Day content

/// A short recording or typed line. `duration == nil` means it was typed.
public struct Note: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var duration: TimeInterval?
    public var createdAt: Date
    /// Model of the device that captured it ("iPhone", "iPad"). Older data and fixtures may hold
    /// "This iPhone"; `DeviceIdentity` decides what to show.
    public var device: String?
    /// Stable id of the install that captured it (`SyncEnvelope.deviceID`). nil in older data.
    public var deviceID: String?
    /// Last edit (sync keeps the newer version of the same note). nil = never edited.
    public var updatedAt: Date?

    public init(id: UUID = UUID(), text: String, duration: TimeInterval? = nil, createdAt: Date, device: String? = nil,
                deviceID: String? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.duration = duration
        self.createdAt = createdAt
        self.device = device
        self.deviceID = deviceID
        self.updatedAt = updatedAt
    }

    public var isSpoken: Bool { duration != nil }
}

/// Morning "Who will you be today?" answer, e.g. "Patient. Ship one thing."
public struct Intention: Codable, Hashable, Sendable {
    public var text: String
    public var duration: TimeInterval?
    public var createdAt: Date
    /// Last edit. nil = never edited.
    public var updatedAt: Date?

    public init(text: String, duration: TimeInterval? = nil, createdAt: Date, updatedAt: Date? = nil) {
        self.text = text
        self.duration = duration
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum StepSize: String, Codable, Hashable, Sendable {
    case regular
    /// After 1–2 quiet days the suggestion is smaller (F1): "Smaller than usual. It still counts."
    case smaller
}

public enum StepSource: String, Codable, Hashable, Sendable {
    /// Named by the user (first week, typed or spoken).
    case user
    /// Proposed by CloudAssist (B3) and accepted with "Use this".
    case suggested
}

public struct Step: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var partID: UUID?
    public var createdAt: Date
    public var completedAt: Date?
    public var size: StepSize
    public var source: StepSource
    /// Last edit of the title, part or size. Completing or undoing doesn't touch it (that is
    /// `completionChangedAt`), so a later completion elsewhere never undoes a title edit. nil in older data,
    /// where completing did set it.
    public var updatedAt: Date?
    /// Last time `completedAt` changed (completed or undone). Sync merges the completion on this stamp
    /// alone, so a title or part edit made later on another device doesn't undo it. nil in older data.
    public var completionChangedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        partID: UUID? = nil,
        createdAt: Date,
        completedAt: Date? = nil,
        size: StepSize = .regular,
        source: StepSource = .user,
        updatedAt: Date? = nil,
        completionChangedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.partID = partID
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.size = size
        self.source = source
        self.updatedAt = updatedAt
        self.completionChangedAt = completionChangedAt
    }

    public var isDone: Bool { completedAt != nil }
}

public enum ReflectionOutcome: String, Codable, Hashable, Sendable {
    /// "Done" / "Yes"
    case moved
    /// "Not today" — the answer becomes that day's reason.
    case notToday
}

public enum SummaryState: String, Codable, Hashable, Sendable {
    /// Summary is available (or cloud help is off and the transcript is shown plainly).
    case ready
    /// Offline: "Saved as audio. Text and summary appear here when you reconnect." (D6)
    case waitingForNetwork
    /// "Couldn't turn this recording into text." (D6b)
    case transcriptionFailed
}

/// The evening entry for a day.
public struct Reflection: Codable, Hashable, Sendable {
    public var outcome: ReflectionOutcome
    public var transcript: String
    public var summary: String?
    public var summaryState: SummaryState
    public var duration: TimeInterval?
    public var partID: UUID?
    public var createdAt: Date
    /// Model of the device that recorded it ("iPhone", "iPad"); shown when two devices changed the same
    /// day (E5). Older data and fixtures may hold "This iPhone"; `DeviceIdentity` decides what to show.
    public var device: String?
    /// The memo's file in the app's audio folder (`Recording.fileName`). nil when typed.
    public var audioFileName: String?
    /// Stable id of the install that recorded it (`SyncEnvelope.deviceID`). nil in older data.
    public var deviceID: String?
    /// Last edit (E4, a summary arriving). nil = never edited.
    public var updatedAt: Date?

    public init(
        outcome: ReflectionOutcome,
        transcript: String,
        summary: String? = nil,
        summaryState: SummaryState = .ready,
        duration: TimeInterval? = nil,
        partID: UUID? = nil,
        createdAt: Date,
        device: String? = nil,
        audioFileName: String? = nil,
        deviceID: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.outcome = outcome
        self.transcript = transcript
        self.summary = summary
        self.summaryState = summaryState
        self.duration = duration
        self.partID = partID
        self.createdAt = createdAt
        self.device = device
        self.audioFileName = audioFileName
        self.deviceID = deviceID
        self.updatedAt = updatedAt
    }

    /// Text shown in History and on the saved screen: summary if any, else transcript.
    public var displayText: String { summary ?? transcript }
}

// MARK: - Day

/// A calendar date independent of time zone ("2026-11-10").
public struct DayKey: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    public func date(in calendar: Calendar, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date(timeIntervalSince1970: 0)
    }

    public func adding(days: Int, calendar: Calendar) -> DayKey {
        DayKey(calendar.date(byAdding: .day, value: days, to: date(in: calendar, hour: 12)) ?? date(in: calendar), calendar: calendar)
    }

    /// Whole days from `self` to `other` (positive if other is later).
    public func days(to other: DayKey, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: date(in: calendar, hour: 12), to: other.date(in: calendar, hour: 12)).day ?? 0
    }

    public static func < (a: DayKey, b: DayKey) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

public struct Day: Identifiable, Codable, Hashable, Sendable {
    public var key: DayKey
    public var goalID: UUID?
    public var intention: Intention?
    public var step: Step?
    public var notes: [Note]
    public var reflection: Reflection?
    /// Close (top-left) on the morning ritual sends you to Today; the morning isn't offered again that day.
    public var morningSkipped: Bool
    /// E5: the same day was changed on another device. Notes and audio merge; only the summary asks.
    public var mergeCandidates: [Reflection]?
    /// Notes and steps deleted from this day (by id), so a merge doesn't bring them back from a device
    /// that still has them. A version edited after the deletion wins. Written by `LocalEdits`.
    public var removedItems: [ItemTombstone]? = nil
    /// When the morning was skipped here (`LocalEdits` stamps it). Lets "Delete everything" tell a skip made
    /// after it from one made before. nil in older data (the day's date stands in).
    public var morningSkippedAt: Date? = nil

    public var id: DayKey { key }

    public init(
        key: DayKey,
        goalID: UUID? = nil,
        intention: Intention? = nil,
        step: Step? = nil,
        notes: [Note] = [],
        reflection: Reflection? = nil,
        morningSkipped: Bool = false,
        mergeCandidates: [Reflection]? = nil
    ) {
        self.key = key
        self.goalID = goalID
        self.intention = intention
        self.step = step
        self.notes = notes
        self.reflection = reflection
        self.morningSkipped = morningSkipped
        self.mergeCandidates = mergeCandidates
    }

    /// Moved toward the goal: the step was completed or the evening answer was "Done"/"Yes".
    public var moved: Bool {
        (step?.isDone ?? false) || reflection?.outcome == .moved
    }

    /// Any trace of the user on this day. Quiet days have none.
    public var hasActivity: Bool {
        intention != nil || step != nil || !notes.isEmpty || reflection != nil || morningSkipped
    }

    /// The morning ritual has been done or dismissed.
    public var morningHandled: Bool {
        intention != nil || step != nil || morningSkipped
    }
}

// MARK: - Settings

public struct TimeOfDay: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int = 0) {
        self.hour = hour
        self.minute = minute
    }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    public var minutesSinceMidnight: Int { hour * 60 + minute }

    public static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { a.minutesSinceMidnight < b.minutesSinceMidnight }

    public static let noon = TimeOfDay(hour: 12)

    /// "07:00" — always 24-hour, shown in IBM Plex Mono.
    public var description: String { String(format: "%02d:%02d", hour, minute) }
}

/// Two moments a day: Center (morning) and Look back (evening).
public struct Rhythm: Codable, Hashable, Sendable {
    public var morning: TimeOfDay
    public var evening: TimeOfDay

    public init(morning: TimeOfDay = TimeOfDay(hour: 7), evening: TimeOfDay = TimeOfDay(hour: 21)) {
        self.morning = morning
        self.evening = evening
    }

    public static let standard = Rhythm()
}

public enum InputPreference: String, Codable, Hashable, Sendable {
    case voice
    case typing
}

public struct Settings: Codable, Hashable, Sendable {
    public var rhythm: Rhythm
    /// The one switch: summaries and step ideas from a private cloud model. Off = plain transcripts, no ideas.
    public var cloudAssist: Bool
    public var notificationsEnabled: Bool
    public var input: InputPreference
    /// Time zone the rhythm follows. nil = device time zone. (I3: the day follows you.)
    public var timeZoneID: String?
    /// Last change to a synced field (`rhythm`, `cloudAssist`) made on some device. nil = defaults / older data.
    public var updatedAt: Date?
    /// When `rhythm` last changed. Sync merges it on this stamp alone. nil in older data (`updatedAt` stands in).
    public var rhythmUpdatedAt: Date?
    /// When `cloudAssist` last changed. Sync merges it on this stamp alone. nil in older data (`updatedAt` stands in).
    public var cloudAssistUpdatedAt: Date?

    public init(
        rhythm: Rhythm = .standard,
        cloudAssist: Bool = true,
        notificationsEnabled: Bool = true,
        input: InputPreference = .voice,
        timeZoneID: String? = nil,
        updatedAt: Date? = nil,
        rhythmUpdatedAt: Date? = nil,
        cloudAssistUpdatedAt: Date? = nil
    ) {
        self.rhythm = rhythm
        self.cloudAssist = cloudAssist
        self.notificationsEnabled = notificationsEnabled
        self.input = input
        self.timeZoneID = timeZoneID
        self.updatedAt = updatedAt
        self.rhythmUpdatedAt = rhythmUpdatedAt
        self.cloudAssistUpdatedAt = cloudAssistUpdatedAt
    }
}

extension Settings {
    /// Settings that belong to one device and never travel through sync: the reminders switch (iOS asks
    /// per device), the input preference, and the I3 time-zone pin (a phone abroad keeps home time while
    /// the iPad at home follows its own zone). They live in the local store with the rest of `Settings`,
    /// so the widget and every screen read them as before, but a merge always keeps this device's values
    /// (`SyncApply`) and editing them never stamps the synced fields.
    public struct DeviceLocal: Hashable, Sendable {
        public var notificationsEnabled: Bool
        public var input: InputPreference
        public var timeZoneID: String?

        public init(notificationsEnabled: Bool = true, input: InputPreference = .voice, timeZoneID: String? = nil) {
            self.notificationsEnabled = notificationsEnabled
            self.input = input
            self.timeZoneID = timeZoneID
        }
    }

    public var deviceLocal: DeviceLocal {
        get { DeviceLocal(notificationsEnabled: notificationsEnabled, input: input, timeZoneID: timeZoneID) }
        set {
            notificationsEnabled = newValue.notificationsEnabled
            input = newValue.input
            timeZoneID = newValue.timeZoneID
        }
    }

    /// These settings with this device's own `DeviceLocal` values.
    public func keepingDeviceLocal(_ local: DeviceLocal) -> Settings {
        var s = self
        s.deviceLocal = local
        return s
    }
}

// MARK: - Snapshot

/// Everything Compass stores. Synced through iCloud in the real app; no account.
///
/// Encoded with a `schemaVersion` (see `currentSchema`). Files without one are schema 1. A file from a
/// newer schema is not decoded by this version: `JSONFileStore` refuses it rather than misreading it.
public struct CompassSnapshot: Codable, Hashable, Sendable {
    /// 1: original layout. 2: per-item `updatedAt` and `deviceID` (all optional, so 1 decodes as 2).
    public static let currentSchema = 2

    public var goal: Goal?
    public var pastGoals: [Goal]
    /// All days, any order. Use `day(_:)` / `sortedDays`.
    public var days: [Day]
    public var settings: Settings

    public init(goal: Goal? = nil, pastGoals: [Goal] = [], days: [Day] = [], settings: Settings = Settings()) {
        self.goal = goal
        self.pastGoals = pastGoals
        self.days = days
        self.settings = settings
    }

    public static let empty = CompassSnapshot()

    enum CodingKeys: String, CodingKey { case schemaVersion, goal, pastGoals, days, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decodeIfPresent(Goal.self, forKey: .goal)
        pastGoals = try c.decodeIfPresent([Goal].self, forKey: .pastGoals) ?? []
        days = try c.decodeIfPresent([Day].self, forKey: .days) ?? []
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentSchema, forKey: .schemaVersion)
        try c.encodeIfPresent(goal, forKey: .goal)
        try c.encode(pastGoals, forKey: .pastGoals)
        try c.encode(days, forKey: .days)
        try c.encode(settings, forKey: .settings)
    }

    /// The schema a stored snapshot was written with, read without decoding the rest. 1 when absent;
    /// nil when the data isn't a JSON object at all.
    public static func schemaVersion(of data: Data) -> Int? {
        struct Header: Decodable { var schemaVersion: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return nil }
        return header.schemaVersion ?? 1
    }

    public func day(_ key: DayKey) -> Day? { days.first { $0.key == key } }

    public var sortedDays: [Day] { days.sorted { $0.key < $1.key } }

    /// Insert or replace a day by key.
    public mutating func upsert(_ day: Day) {
        if let i = days.firstIndex(where: { $0.key == day.key }) {
            days[i] = day
        } else {
            days.append(day)
        }
    }

    /// Mutate (creating if needed) the day for `key`.
    public mutating func updateDay(_ key: DayKey, _ body: (inout Day) -> Void) {
        var d = day(key) ?? Day(key: key, goalID: goal?.id)
        body(&d)
        upsert(d)
    }

    /// Steps completed toward the current goal (shown as totals, never as a streak).
    public var movedCount: Int {
        guard let goal else { return 0 }
        return days.filter { ($0.goalID == nil || $0.goalID == goal.id) && $0.moved }.count
    }
}
