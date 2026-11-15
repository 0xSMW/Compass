import Foundation

// MARK: - Sync envelope

/// A day entry deleted on some device (E4 "Delete this day's entry"). Kept so a merge doesn't bring the
/// day back from a device that still has it. Content newer than `deletedAt` wins over the tombstone.
public struct DayTombstone: Codable, Hashable, Sendable {
    public var key: DayKey
    public var deletedAt: Date

    public init(key: DayKey, deletedAt: Date) {
        self.key = key
        self.deletedAt = deletedAt
    }
}

/// What one device writes to iCloud: its whole snapshot plus the bookkeeping a merge needs.
/// Each device writes only its own envelope (one writer per file), so files never conflict;
/// every device reads all envelopes and merges them with `SnapshotMerger`.
public struct SyncEnvelope: Codable, Hashable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    /// Stable per install. Names the envelope file.
    public var deviceID: String
    /// "iPhone", "iPad" — shown in E5 when two devices changed the same day.
    public var deviceName: String
    public var savedAt: Date
    public var snapshot: CompassSnapshot
    public var tombstones: [DayTombstone]
    /// H2 "Delete everything" on any device. Envelopes saved before this are ignored everywhere.
    public var wipedAt: Date?

    public init(
        format: Int = SyncEnvelope.currentFormat,
        deviceID: String,
        deviceName: String,
        savedAt: Date,
        snapshot: CompassSnapshot,
        tombstones: [DayTombstone] = [],
        wipedAt: Date? = nil
    ) {
        self.format = format
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.savedAt = savedAt
        self.snapshot = snapshot
        self.tombstones = tombstones
        self.wipedAt = wipedAt
    }

    /// Envelopes from a newer app version are left alone (not merged, not overwritten).
    public var isReadable: Bool { format <= Self.currentFormat }
}

// MARK: - Merge

/// Pure merge of two or more devices' snapshots. Deterministic and order-independent, so every
/// device converges on the same result.
///
/// Rules:
/// - **Same thing changed on both** (same note id, same step id, same reflection `createdAt`, same goal id):
///   the newer envelope's version wins (that is how E4 edits travel).
/// - **Different things on the same day**: notes and audio merge (union by id). Two different evening
///   reflections are a conflict (E5): the earliest is shown and the others wait in `mergeCandidates`;
///   only the summary asks. Resolving turns the losing reflections into notes, so both recordings stay.
/// - Goals merge by id; an ended goal stays ended; the most recently created current goal wins.
/// - Settings follow the newer envelope.
/// - Tombstones remove days whose content is older than the deletion; `wipedAt` drops whole envelopes.
public enum SnapshotMerger {
    /// Merge any number of envelopes (local first is not required). nil if there are none readable.
    public static func merge(_ envelopes: [SyncEnvelope]) -> SyncEnvelope? {
        let readable = envelopes.filter(\.isReadable)
        guard !readable.isEmpty else { return nil }
        let wipedAt = readable.compactMap(\.wipedAt).max()
        let live = readable.map { e -> SyncEnvelope in
            guard let wipedAt, e.savedAt < wipedAt else { return e }
            // Saved before the wipe: its data is gone everywhere.
            var empty = e
            empty.snapshot = CompassSnapshot(settings: e.snapshot.settings)
            empty.tombstones = []
            return empty
        }
        let sorted = live.sorted(by: isNewer)
        var result = sorted[0]
        for e in sorted.dropFirst() { result = merge(result, e) }
        result.wipedAt = wipedAt
        return result
    }

    /// Ordering used to pick the newer side: later `savedAt`, then device id (stable tie-break).
    static func isNewer(_ a: SyncEnvelope, _ b: SyncEnvelope) -> Bool {
        if a.savedAt != b.savedAt { return a.savedAt > b.savedAt }
        return a.deviceID > b.deviceID
    }

    /// Merge two envelopes. The result carries the newer side's identity.
    public static func merge(_ a: SyncEnvelope, _ b: SyncEnvelope) -> SyncEnvelope {
        let (newer, older) = isNewer(a, b) ? (a, b) : (b, a)
        let tombstones = mergeTombstones(newer.tombstones + older.tombstones)
        var snap = CompassSnapshot(settings: newer.snapshot.settings)
        (snap.goal, snap.pastGoals) = mergeGoals(newer: newer.snapshot, older: older.snapshot)

        var keys = Set(newer.snapshot.days.map(\.key))
        keys.formUnion(older.snapshot.days.map(\.key))
        let byKey = Dictionary(tombstones.map { ($0.key, $0.deletedAt) }, uniquingKeysWith: max)
        for key in keys.sorted() {
            let day: Day
            switch (newer.snapshot.day(key), older.snapshot.day(key)) {
            case let (n?, o?): day = mergeDay(newer: n, older: o)
            case let (n?, nil): day = n
            case let (nil, o?): day = o
            case (nil, nil): continue
            }
            if let deletedAt = byKey[key], (day.lastModified ?? .distantPast) <= deletedAt { continue }
            snap.days.append(day)
        }

        var result = newer
        result.snapshot = snap
        result.tombstones = tombstones
        result.wipedAt = [newer.wipedAt, older.wipedAt].compactMap { $0 }.max()
        return result
    }

    static func mergeTombstones(_ all: [DayTombstone]) -> [DayTombstone] {
        let latest = Dictionary(all.map { ($0.key, $0.deletedAt) }, uniquingKeysWith: max)
        return latest.map { DayTombstone(key: $0.key, deletedAt: $0.value) }.sorted { $0.key < $1.key }
    }

    /// Goals merge by id. A goal either side has ended (in past goals) stays ended. Of the goals still
    /// current on either side, the most recently created one is current; another one is replaced by it.
    static func mergeGoals(newer: CompassSnapshot, older: CompassSnapshot) -> (Goal?, [Goal]) {
        func pick(_ a: Goal?, _ b: Goal?) -> Goal? {
            guard let a else { return b }
            guard let b else { return a }
            // Ending a goal happens after editing it, so an ended version wins; otherwise newer side.
            if a.status == .active && b.status != .active { return b }
            return a
        }
        var versions: [UUID: Goal] = [:]
        for g in older.pastGoals + [older.goal].compactMap({ $0 }) { versions[g.id] = pick(versions[g.id], g) }
        for g in newer.pastGoals + [newer.goal].compactMap({ $0 }) { versions[g.id] = pick(g, versions[g.id]) }

        var pastIDs = Set(newer.pastGoals.map(\.id)).union(older.pastGoals.map(\.id))
        let candidates = Set([newer.goal?.id, older.goal?.id].compactMap { $0 }).subtracting(pastIDs)
            .compactMap { versions[$0] }
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
        let current = candidates.first
        for replaced in candidates.dropFirst() {
            var ended = replaced
            if ended.status == .active { ended.status = .replaced }
            ended.endedAt = ended.endedAt ?? current?.createdAt
            versions[replaced.id] = ended
            pastIDs.insert(replaced.id)
        }
        let pastList = pastIDs.compactMap { versions[$0] }.sorted {
            ($0.endedAt ?? $0.createdAt, $0.id.uuidString) > ($1.endedAt ?? $1.createdAt, $1.id.uuidString)
        }
        return (current, pastList)
    }

    /// Merge one day changed on two devices.
    public static func mergeDay(newer n: Day, older o: Day) -> Day {
        var d = Day(key: n.key, goalID: n.goalID ?? o.goalID)

        switch (n.intention, o.intention) {
        case let (a?, b?): d.intention = a.createdAt == b.createdAt ? a : (a.createdAt >= b.createdAt ? a : b)
        case let (a, b): d.intention = a ?? b
        }

        switch (n.step, o.step) {
        case let (a?, b?): d.step = a.id == b.id ? a : (a.createdAt >= b.createdAt ? a : b)
        case let (a, b): d.step = a ?? b
        }

        var notes: [UUID: Note] = [:]
        for note in o.notes { notes[note.id] = note }
        for note in n.notes { notes[note.id] = note }
        d.notes = notes.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }

        d.morningSkipped = n.morningSkipped || o.morningSkipped

        // Reflections: identity is the moment it was recorded. Newer side's version of each first.
        var reflections: [Date: Reflection] = [:]
        let olderAll = [o.reflection].compactMap { $0 } + (o.mergeCandidates ?? [])
        let newerAll = [n.reflection].compactMap { $0 } + (n.mergeCandidates ?? [])
        for r in olderAll { reflections[r.createdAt] = r }
        for r in newerAll { reflections[r.createdAt] = r }
        let superseded = Set(d.notes.map(\.id))
        let remaining = reflections.values
            .filter { !superseded.contains(Day.supersededNoteID(for: $0)) }
            .sorted { ($0.createdAt, $0.device ?? "") < ($1.createdAt, $1.device ?? "") }
        d.reflection = remaining.first
        d.mergeCandidates = remaining.count > 1 ? Array(remaining.dropFirst()) : nil
        return d
    }
}

// MARK: - Day conflict helpers (E5)

extension Day {
    /// E5: the same day's evening entry was recorded on two devices and is waiting for a choice.
    public var hasConflict: Bool { !(mergeCandidates ?? []).isEmpty }

    /// Every version of the evening entry, oldest first: the shown one and those waiting.
    public var reflectionVersions: [Reflection] {
        ([reflection].compactMap { $0 } + (mergeCandidates ?? [])).sorted { $0.createdAt < $1.createdAt }
    }

    /// Latest moment anything on this day was written. Used against tombstones.
    public var lastModified: Date? {
        var dates: [Date] = []
        if let i = intention { dates.append(i.createdAt) }
        if let s = step { dates.append(s.completedAt ?? s.createdAt); dates.append(s.createdAt) }
        dates += notes.map(\.createdAt)
        if let r = reflection { dates.append(r.createdAt) }
        dates += (mergeCandidates ?? []).map(\.createdAt)
        return dates.max()
    }

    /// Deterministic id of the note a set-aside reflection becomes. Two devices resolving the same
    /// conflict produce the same note, and merges recognise the reflection as settled.
    public static func supersededNoteID(for r: Reflection) -> UUID {
        let ms = UInt64(max(0, r.createdAt.timeIntervalSince1970 * 1000).rounded())
        return UUID(uuidString: String(format: "5E1EC7ED-0000-4000-8000-%012llX", ms & 0xFFFF_FFFF_FFFF))!
    }

    static func note(from r: Reflection) -> Note {
        Note(id: supersededNoteID(for: r), text: r.displayText, duration: r.duration, createdAt: r.createdAt, device: r.device)
    }

    /// E5 "Use this summary": `chosen` becomes the day's entry; every other version is kept as a note
    /// (its words and recording stay on the day).
    public mutating func resolveConflict(keeping chosen: Reflection) {
        let others = reflectionVersions.filter { $0.createdAt != chosen.createdAt }
        reflection = chosen
        mergeCandidates = nil
        for r in others where !notes.contains(where: { $0.id == Day.supersededNoteID(for: r) }) {
            notes.append(Day.note(from: r))
        }
        notes.sort { $0.createdAt < $1.createdAt }
    }

    /// E5 "Keep both": the shown summary stays; the other versions are kept alongside as notes.
    public mutating func keepBothVersions() {
        guard let shown = reflection ?? reflectionVersions.first else { return }
        resolveConflict(keeping: shown)
    }
}
