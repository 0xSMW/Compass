import Foundation

// Rules the live app's flows share: where an ended goal lands, when the clock moves the entry screen,
// the rhythm's limits, when reminders need the I2 notice, and how notes and past days are edited.
// Pure and deterministic, so CompassCore tests cover them.

// MARK: - History

extension CompassSnapshot {
    /// Anything to keep: a goal (in any state), a past goal or a day with content (`isBlank`). Without it
    /// the app is new (A1).
    public var hasHistory: Bool { !isBlank }

    /// The current goal is still being worked toward.
    public var hasActiveGoal: Bool { goal?.status == .active }
}

// MARK: - Rhythm limits (A6 and Settings)

extension TimeOfDay {
    /// The nearest time inside `range`.
    public func clamped(to range: ClosedRange<TimeOfDay>) -> TimeOfDay {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Rhythm {
    /// Morning between 04:00 and 11:45, evening between 17:00 and 23:45 (A6's limits, also used by
    /// Settings). Keeps the evening after the morning and both on the right side of noon, so the day
    /// always runs Center → Today → Look back.
    public var clamped: Rhythm {
        Rhythm(morning: morning.clamped(to: Self.morningRange), evening: evening.clamped(to: Self.eveningRange))
    }

    /// Settings' Morning wheel: the chosen time inside A6's limits.
    public func settingMorning(_ time: TimeOfDay) -> Rhythm {
        var r = self
        r.morning = time.clamped(to: Self.morningRange)
        return r.clamped
    }

    /// Settings' Evening wheel: the chosen time inside A6's limits.
    public func settingEvening(_ time: TimeOfDay) -> Rhythm {
        var r = self
        r.evening = time.clamped(to: Self.eveningRange)
        return r.clamped
    }
}

// MARK: - Clock (entry screen follows the day)

/// The clock-driven part of a phase. Two moments with the same day and kind open the same flow; a
/// change means the screen on display may belong to another part of the day.
public enum PhaseKind: Hashable, Sendable {
    case onboarding
    case goalEnded
    /// Morning before noon (B1, B7).
    case center
    /// Morning from noon to the evening time (B6).
    case afternoon
    case today
    case evening
    case returning
    case checkGoal
}

extension DayPhase {
    public var kind: PhaseKind {
        switch self {
        case .onboarding: .onboarding
        case .goalEnded: .goalEnded
        case .morning(let plan): plan.startsWithCenter ? .center : .afternoon
        case .today: .today
        case .evening: .evening
        case .returning: .returning
        case .checkGoal: .checkGoal
        }
    }
}

extension DayEngine {
    /// True when the clock alone moved the day on between `then` and `now`: a new day, or a new part
    /// of it (noon, the evening time). Both moments are judged on the same data, so saving an
    /// intention or a step (which changes the phase by itself) never counts as the clock moving.
    public func clockMoved(from then: Date, to now: Date, snapshot: CompassSnapshot) -> Bool {
        if DayKey(then, calendar: calendar) != DayKey(now, calendar: calendar) { return true }
        return phase(at: then, snapshot: snapshot).kind != phase(at: now, snapshot: snapshot).kind
    }

    /// The next moment the phase can change on its own: noon, the evening time, or midnight.
    public func nextBoundary(after now: Date, rhythm: Rhythm) -> Date {
        let today = DayKey(now, calendar: calendar)
        let evening = rhythm.clamped.evening
        let candidates = [
            today.date(in: calendar, hour: TimeOfDay.noon.hour, minute: TimeOfDay.noon.minute),
            today.date(in: calendar, hour: evening.hour, minute: evening.minute),
            today.adding(days: 1, calendar: calendar).date(in: calendar),
        ]
        return candidates.filter { $0 > now }.min() ?? now.addingTimeInterval(3600)
    }
}

// MARK: - Notifications (I2)

public enum NotificationRules {
    /// "07:00 and 21:00 can't reach you." shows whenever reminders can't arrive: switched off in
    /// Compass ("Not now" on A6) or not allowed by iOS (not asked yet, or denied), until dismissed.
    /// Dismissing it is undone when a reminder time is changed in Settings (`remindersBlocked` then
    /// still holds), and H1 shows a "Reminders" row while they are blocked, so there is always a way back.
    public static func showsOffNotice(enabled: Bool, status: PermissionState, dismissed: Bool) -> Bool {
        guard !dismissed else { return false }
        return remindersBlocked(enabled: enabled, status: status)
    }

    /// Reminders can't arrive: switched off in Compass or not allowed by iOS. H1 shows its "Reminders"
    /// row only then (the board's list, which has no such row, is the state where they work).
    public static func remindersBlocked(enabled: Bool, status: PermissionState) -> Bool {
        !enabled || status != .granted
    }

    /// Changing a reminder time in Settings brings back a dismissed I2 (the user is thinking about
    /// reminders); it stays dismissed when the times didn't change.
    public static func noticeDismissed(_ dismissed: Bool, afterRhythmChange old: Rhythm, to new: Rhythm) -> Bool {
        dismissed && old == new
    }
}

// MARK: - Notes

public enum NoteRules {
    /// A finished note recording. The note takes the recording's id, so its audio stays at
    /// `<note id>.m4a` and plays from Today and History. nil when nothing was recorded or said.
    /// A note with audio but no words (speech off, nothing recognised) keeps its audio; the caller
    /// offers typing (`needsWords`).
    public static func note(transcript: String, recording: Recording?, now: Date, device: String?) -> Note? {
        let text = MorningRules.collapse(transcript)
        if let recording {
            return Note(id: recording.id, text: text, duration: recording.duration, createdAt: recording.createdAt, device: device)
        }
        guard !text.isEmpty else { return nil }
        return Note(text: text, createdAt: now, device: device)
    }

    /// A voice note with no words yet: typing is offered to add them; the audio stays either way.
    public static func needsWords(_ note: Note) -> Bool { note.isSpoken && note.text.isEmpty }
}

extension Day {
    /// Edit a note's words. A typed note emptied out is removed; a voice note keeps its audio.
    /// Returns false when the note isn't on this day.
    @discardableResult
    public mutating func editNote(_ id: UUID, text: String) -> Bool {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return false }
        let tidy = MorningRules.collapse(text)
        if tidy.isEmpty && !notes[i].isSpoken {
            notes.remove(at: i)
        } else {
            notes[i].text = tidy
        }
        return true
    }

    /// Remove a note; returns it so the caller can delete its audio.
    @discardableResult
    public mutating func removeNote(_ id: UUID) -> Note? {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return nil }
        return notes.remove(at: i)
    }
}

// MARK: - Editing a past day (E4)

public enum HistoryEdit {
    /// Save on E4.
    /// - Text left as shown (the summary, or the transcript when there was none) changes nothing, so an
    ///   unchanged save never turns a transcript into a "summary" (which would add a Transcript row).
    /// - Other text becomes the summary; emptied text drops the summary and the transcript shows.
    /// - "Moved" / "Not that day" sets the outcome and the step's completion.
    /// - "None" clears the part on both the evening entry and the step.
    public static func apply(to day: inout Day, summary: String, moved: Bool, partID: UUID?,
                             now: Date, calendar: Calendar, device: String?) {
        let text = MorningRules.collapse(summary)
        // E4 opens with the summary (or transcript), else the step's title.
        let shown = MorningRules.collapse(day.reflection?.displayText ?? day.step?.title ?? "")
        let changed = text != shown
        if var r = day.reflection {
            if changed {
                r.summary = text.isEmpty ? nil : text
                if !text.isEmpty { r.summaryState = .ready }
            }
            r.outcome = moved ? .moved : .notToday
            r.partID = partID
            day.reflection = r
        } else if (changed && !text.isEmpty) || (moved && day.step == nil) {
            // Typed on E4, so it is the summary; there is no recording or transcript behind it.
            day.reflection = Reflection(outcome: moved ? .moved : .notToday, transcript: "", summary: changed && !text.isEmpty ? text : nil,
                                        partID: partID, createdAt: now, device: device)
        }
        if var step = day.step {
            if !moved { step.completedAt = nil }
            if moved, !step.isDone { step.completedAt = day.key.date(in: calendar, hour: 21) }
            step.partID = partID
            day.step = step
        }
    }
}
