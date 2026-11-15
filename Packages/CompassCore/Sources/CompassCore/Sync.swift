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

/// A note or step deleted from a day on some device (kept on the day, see `Day.removedItems`).
public struct ItemTombstone: Codable, Hashable, Sendable {
    public var id: UUID
    public var deletedAt: Date

    public init(id: UUID, deletedAt: Date) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// A recording deleted on some device (E4 delete, evening redo, a discarded take). Every device removes
/// the file locally and from iCloud, and never copies it back.
public struct AudioTombstone: Codable, Hashable, Sendable {
    public var name: String
    public var deletedAt: Date

    public init(name: String, deletedAt: Date) {
        self.name = name
        self.deletedAt = deletedAt
    }
}

/// What one device writes to iCloud: its whole snapshot plus the bookkeeping a merge needs.
/// Each device writes only its own envelope (one writer per file), so files never conflict;
/// every device reads all envelopes and merges them with `SnapshotMerger`.
public struct SyncEnvelope: Codable, Hashable, Sendable {
    /// 1: whole-envelope last writer wins. 2: per-item `updatedAt`, wipe generations, audio tombstones,
    /// device ids on items. Format 1 envelopes still merge (their items fall back to `createdAt`);
    /// a format 1 app ignores format 2 envelopes instead of dropping their new fields on its next save.
    public static let currentFormat = 2

    public var format: Int
    /// Stable per install. Names the envelope file and is stored on the items this device records.
    public var deviceID: String
    /// "iPhone", "iPad".
    public var deviceName: String
    /// Last local change on this device.
    public var savedAt: Date
    public var snapshot: CompassSnapshot
    public var tombstones: [DayTombstone]
    /// H2 "Delete everything" on any device: a generation boundary. Everything created before it is
    /// dropped from every envelope, however late that envelope was saved.
    public var wipedAt: Date?
    /// Recordings deleted on any device.
    public var audioTombstones: [AudioTombstone]

    public init(
        format: Int = SyncEnvelope.currentFormat,
        deviceID: String,
        deviceName: String,
        savedAt: Date,
        snapshot: CompassSnapshot,
        tombstones: [DayTombstone] = [],
        wipedAt: Date? = nil,
        audioTombstones: [AudioTombstone] = []
    ) {
        self.format = format
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.savedAt = savedAt
        self.snapshot = snapshot
        self.tombstones = tombstones
        self.wipedAt = wipedAt
        self.audioTombstones = audioTombstones
    }

    enum CodingKeys: String, CodingKey {
        case format, deviceID, deviceName, savedAt, snapshot, tombstones, wipedAt, audioTombstones
    }

    /// Fields added after format 1 decode as empty when absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? 1
        deviceID = try c.decode(String.self, forKey: .deviceID)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        snapshot = try c.decode(CompassSnapshot.self, forKey: .snapshot)
        tombstones = try c.decodeIfPresent([DayTombstone].self, forKey: .tombstones) ?? []
        wipedAt = try c.decodeIfPresent(Date.self, forKey: .wipedAt)
        audioTombstones = try c.decodeIfPresent([AudioTombstone].self, forKey: .audioTombstones) ?? []
    }

    /// Envelopes from a newer app version are left alone (not merged, not overwritten).
    public var isReadable: Bool { format <= Self.currentFormat }
}

// MARK: - Version times

/// When an item last changed, for picking between two versions of the same item. Older data has no
/// `updatedAt`; its creation (or completion / ending) stands in.
extension Step {
    public var versionTime: Date { updatedAt ?? max(createdAt, completedAt ?? createdAt) }
}

extension Note {
    public var versionTime: Date { updatedAt ?? createdAt }
}

extension Intention {
    public var versionTime: Date { updatedAt ?? createdAt }
}

extension Reflection {
    public var versionTime: Date { updatedAt ?? createdAt }
}

extension Goal {
    public var versionTime: Date { updatedAt ?? max(createdAt, endedAt ?? createdAt) }
}

extension Settings {
    public var versionTime: Date { updatedAt ?? .distantPast }
}

// MARK: - Merge

/// Pure merge of two or more devices' snapshots. Deterministic and order-independent, so every
/// device converges on the same result.
///
/// Rules:
/// - **Same item changed on both** (same note id, same step id, same reflection `createdAt`, same goal id,
///   the settings): the version with the later `versionTime` wins, whichever envelope was saved later.
///   Equal times fall back to the newer envelope. So a step completed on one device stays completed when
///   another device that hadn't seen it saves something unrelated.
/// - **Different things on the same day**: notes and audio merge (union by id). Two different evening
///   reflections from two devices are a conflict (E5): the earliest is shown and the others wait in
///   `mergeCandidates`; only the summary asks. Two from the same device are a redo: the later one stands.
///   Resolving turns the losing reflections into notes, so both recordings stay.
/// - **Goals** merge by id; an ended goal stays ended. A goal is replaced only by a device that knew it
///   (it is in that device's past goals). A goal created on a device that never saw the current one
///   (onboarding on a second device, two offline replacements) never replaces it: the earlier goal stays
///   current and the newcomer is kept as a replaced past goal. That device's settings don't win either.
/// - **Tombstones** remove days whose content is older than the deletion.
/// - **`wipedAt`** is a generation boundary: everything created before the newest wipe is dropped from
///   every envelope, however late that envelope was saved. Things created after it are kept.
public enum SnapshotMerger {
    /// Merge any number of envelopes (local first is not required). nil if there are none readable.
    public static func merge(_ envelopes: [SyncEnvelope]) -> SyncEnvelope? {
        let readable = envelopes.filter(\.isReadable)
        guard !readable.isEmpty else { return nil }
        let wipedAt = readable.compactMap(\.wipedAt).max()
        let live = readable.map { applyingWipe(wipedAt, to: $0) }
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

    /// Drop everything from before the wipe (see `CompassSnapshot.keepingOnly(createdSince:)`).
    static func applyingWipe(_ wipedAt: Date?, to e: SyncEnvelope) -> SyncEnvelope {
        guard let wipedAt else { return e }
        var out = e
        out.snapshot = e.snapshot.keepingOnly(createdSince: wipedAt)
        out.tombstones = e.tombstones.filter { $0.deletedAt >= wipedAt }
        out.audioTombstones = e.audioTombstones.filter { $0.deletedAt >= wipedAt }
        out.wipedAt = max(wipedAt, e.wipedAt ?? wipedAt)
        return out
    }

    /// Merge two envelopes. The result carries the newer side's identity.
    public static func merge(_ a: SyncEnvelope, _ b: SyncEnvelope) -> SyncEnvelope {
        let wipedAt = [a.wipedAt, b.wipedAt].compactMap { $0 }.max()
        let (newer, older) = isNewer(a, b)
            ? (applyingWipe(wipedAt, to: a), applyingWipe(wipedAt, to: b))
            : (applyingWipe(wipedAt, to: b), applyingWipe(wipedAt, to: a))
        let tombstones = mergeTombstones(newer.tombstones + older.tombstones)
        let goals = mergeGoals(newer: newer.snapshot, older: older.snapshot)
        var snap = CompassSnapshot()
        snap.goal = goals.current
        snap.pastGoals = goals.past
        switch goals.demoted {
        case .newer?: snap.settings = older.snapshot.settings
        case .older?: snap.settings = newer.snapshot.settings
        case nil: snap.settings = latest(newer.snapshot.settings, older.snapshot.settings, by: \.versionTime)
        }

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
        result.audioTombstones = mergeAudioTombstones(newer.audioTombstones + older.audioTombstones)
        result.wipedAt = wipedAt
        return result
    }

    /// `a` comes from the newer envelope and wins ties.
    static func latest<T>(_ a: T, _ b: T, by time: KeyPath<T, Date>) -> T {
        b[keyPath: time] > a[keyPath: time] ? b : a
    }

    static func mergeTombstones(_ all: [DayTombstone]) -> [DayTombstone] {
        let latest = Dictionary(all.map { ($0.key, $0.deletedAt) }, uniquingKeysWith: max)
        return latest.map { DayTombstone(key: $0.key, deletedAt: $0.value) }.sorted { $0.key < $1.key }
    }

    public static func mergeAudioTombstones(_ all: [AudioTombstone]) -> [AudioTombstone] {
        let latest = Dictionary(all.map { ($0.name, $0.deletedAt) }, uniquingKeysWith: max)
        return latest.map { AudioTombstone(name: $0.key, deletedAt: $0.value) }.sorted { $0.name < $1.name }
    }

    enum Side { case newer, older }

    /// Two versions of one goal (`a` from the newer envelope): an ended version wins over an active one
    /// (ending happens after editing); otherwise the later `versionTime`. Parts and the B7 answer merge
    /// field-wise so neither device's addition is lost.
    static func pickGoal(_ a: Goal, _ b: Goal) -> Goal {
        let aEnded = a.status != .active, bEnded = b.status != .active
        let winner: Goal, loser: Goal
        if aEnded != bEnded {
            (winner, loser) = aEnded ? (a, b) : (b, a)
        } else {
            (winner, loser) = b.versionTime > a.versionTime ? (b, a) : (a, b)
        }
        var g = winner
        g.why = winner.why ?? loser.why
        g.whyAsked = winner.whyAsked || loser.whyAsked
        let known = Set(winner.parts.map(\.id))
        g.parts += loser.parts.filter { !known.contains($0.id) }
        return g
    }

    /// Goals merge by id. A goal either side has ended (in past goals) stays ended. A current goal is
    /// replaced only through past goals (the replacing device knew it). Two current goals where neither
    /// device knew the other's: the earlier-created one stays current; the newcomer is kept as a replaced
    /// past goal and its side is reported as `demoted`.
    static func mergeGoals(newer: CompassSnapshot, older: CompassSnapshot) -> (current: Goal?, past: [Goal], demoted: Side?) {
        var versions: [UUID: Goal] = [:]
        for g in older.pastGoals + [older.goal].compactMap({ $0 }) {
            versions[g.id] = versions[g.id].map { pickGoal($0, g) } ?? g
        }
        for g in newer.pastGoals + [newer.goal].compactMap({ $0 }) {
            versions[g.id] = versions[g.id].map { pickGoal(g, $0) } ?? g
        }

        var pastIDs = Set(newer.pastGoals.map(\.id)).union(older.pastGoals.map(\.id))
        let candidates = Set([newer.goal?.id, older.goal?.id].compactMap { $0 }).subtracting(pastIDs)
            .compactMap { versions[$0] }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        let current = candidates.first
        var demoted: Side?
        for loser in candidates.dropFirst() {
            var ended = loser
            if ended.status == .active { ended.status = .replaced }
            ended.endedAt = ended.endedAt ?? loser.versionTime
            versions[loser.id] = ended
            pastIDs.insert(loser.id)
            demoted = newer.goal?.id == loser.id ? .newer : .older
        }
        let pastList = pastIDs.compactMap { versions[$0] }.sorted {
            ($0.endedAt ?? $0.createdAt, $0.id.uuidString) > ($1.endedAt ?? $1.createdAt, $1.id.uuidString)
        }
        return (current, pastList, demoted)
    }

    /// Merge one day changed on two devices.
    public static func mergeDay(newer n: Day, older o: Day) -> Day {
        var d = Day(key: n.key, goalID: n.goalID ?? o.goalID)

        switch (n.intention, o.intention) {
        case let (a?, b?):
            d.intention = a.createdAt == b.createdAt ? latest(a, b, by: \.versionTime) : latest(a, b, by: \.createdAt)
        case let (a, b): d.intention = a ?? b
        }

        switch (n.step, o.step) {
        case let (a?, b?): d.step = a.id == b.id ? latest(a, b, by: \.versionTime) : latest(a, b, by: \.createdAt)
        case let (a, b): d.step = a ?? b
        }

        var notes: [UUID: Note] = [:]
        for note in n.notes { notes[note.id] = note }
        for note in o.notes { notes[note.id] = notes[note.id].map { latest($0, note, by: \.versionTime) } ?? note }
        d.notes = notes.values.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }

        // Deleted notes and steps stay deleted unless edited after the deletion.
        let removed = Dictionary(((n.removedItems ?? []) + (o.removedItems ?? [])).map { ($0.id, $0.deletedAt) }, uniquingKeysWith: max)
        if !removed.isEmpty {
            d.removedItems = removed.map { ItemTombstone(id: $0.key, deletedAt: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
            d.notes.removeAll { note in removed[note.id].map { note.versionTime <= $0 } ?? false }
            if let s = d.step, let gone = removed[s.id], s.versionTime <= gone { d.step = nil }
        }

        d.morningSkipped = n.morningSkipped || o.morningSkipped

        // Reflections: identity is the moment it was recorded; the later version of each wins.
        var reflections: [Date: Reflection] = [:]
        for r in [n.reflection].compactMap({ $0 }) + (n.mergeCandidates ?? []) { reflections[r.createdAt] = r }
        for r in [o.reflection].compactMap({ $0 }) + (o.mergeCandidates ?? []) {
            reflections[r.createdAt] = reflections[r.createdAt].map { latest($0, r, by: \.versionTime) } ?? r
        }
        let superseded = Set(d.notes.map(\.id))
        var remaining = reflections.values.filter { !superseded.contains(Day.supersededNoteID(for: $0)) }
        // One install keeps one evening entry per day: an older one from the same device was redone.
        var latestByDevice: [String: Date] = [:]
        for r in remaining {
            guard let id = r.deviceID else { continue }
            latestByDevice[id] = max(latestByDevice[id] ?? r.createdAt, r.createdAt)
        }
        remaining.removeAll { r in r.deviceID.map { latestByDevice[$0] != r.createdAt } ?? false }
        remaining.sort { ($0.createdAt, $0.deviceID ?? $0.device ?? "") < ($1.createdAt, $1.deviceID ?? $1.device ?? "") }
        d.reflection = remaining.first
        d.mergeCandidates = remaining.count > 1 ? Array(remaining.dropFirst()) : nil
        return d
    }
}

// MARK: - Wipe generations

extension CompassSnapshot {
    /// What survives a "Delete everything" made at `wipe`: only things created at or after it. Settings
    /// last changed before it go back to defaults. Days left with nothing are dropped.
    public func keepingOnly(createdSince wipe: Date) -> CompassSnapshot {
        var s = CompassSnapshot()
        s.goal = goal.flatMap { $0.createdAt >= wipe ? $0 : nil }
        s.pastGoals = pastGoals.filter { $0.createdAt >= wipe }
        s.settings = settings.versionTime >= wipe ? settings : Settings()
        for day in days {
            var d = Day(key: day.key, goalID: day.goalID)
            d.intention = day.intention.flatMap { $0.createdAt >= wipe ? $0 : nil }
            d.step = day.step.flatMap { $0.createdAt >= wipe ? $0 : nil }
            d.notes = day.notes.filter { $0.createdAt >= wipe }
            let versions = day.reflectionVersions.filter { $0.createdAt >= wipe }
            d.reflection = day.reflection.flatMap { $0.createdAt >= wipe ? $0 : nil } ?? versions.first
            let others = versions.filter { $0.createdAt != d.reflection?.createdAt }
            d.mergeCandidates = others.isEmpty ? nil : others
            guard d.intention != nil || d.step != nil || !d.notes.isEmpty || d.reflection != nil else { continue }
            let removed = (day.removedItems ?? []).filter { $0.deletedAt >= wipe }
            d.removedItems = removed.isEmpty ? nil : removed
            d.morningSkipped = day.morningSkipped
            s.days.append(d)
        }
        return s
    }

    /// Nothing the user made: no goal, no days.
    public var isBlank: Bool { goal == nil && pastGoals.isEmpty && days.isEmpty }
}

// MARK: - Day conflict helpers (E5)

extension Day {
    /// E5: the same day's evening entry was recorded on two devices and is waiting for a choice.
    public var hasConflict: Bool { !(mergeCandidates ?? []).isEmpty }

    /// Every version of the evening entry, oldest first: the shown one and those waiting.
    public var reflectionVersions: [Reflection] {
        ([reflection].compactMap { $0 } + (mergeCandidates ?? [])).sorted { $0.createdAt < $1.createdAt }
    }

    /// Latest moment anything on this day was written or edited. Used against tombstones.
    public var lastModified: Date? {
        var dates: [Date] = []
        if let i = intention { dates.append(i.versionTime) }
        if let s = step { dates.append(s.versionTime) }
        dates += notes.map(\.versionTime)
        dates += reflectionVersions.map(\.versionTime)
        return dates.max()
    }

    /// Deterministic id of the note a set-aside reflection becomes. Two devices resolving the same
    /// conflict produce the same note, and merges recognise the reflection as settled.
    public static func supersededNoteID(for r: Reflection) -> UUID {
        let ms = UInt64(max(0, r.createdAt.timeIntervalSince1970 * 1000).rounded())
        return UUID(uuidString: String(format: "5E1EC7ED-0000-4000-8000-%012llX", ms & 0xFFFF_FFFF_FFFF))!
    }

    static func note(from r: Reflection) -> Note {
        Note(id: supersededNoteID(for: r), text: r.displayText, duration: r.duration, createdAt: r.createdAt,
             device: r.device, deviceID: r.deviceID)
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
