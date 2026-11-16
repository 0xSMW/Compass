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
    /// The title, part and size version. Completing doesn't count once it has its own stamp
    /// (`completionChangedAt`); in older data, where completing set `updatedAt`, the completion stands in.
    public var versionTime: Date {
        if let updatedAt { return updatedAt }
        return completionChangedAt == nil ? max(createdAt, completedAt ?? createdAt) : createdAt
    }

    /// The last time anything about the step changed, its completion included: what a deletion
    /// (a day or item tombstone) is weighed against.
    public var lastTouched: Date { max(versionTime, completionTime) }
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

extension Goal {
    /// The user ended it (achieved, or replaced by a goal set on that device). A copy a merge demoted
    /// (`demotedByMerge`) is not ended by anyone.
    public var isEndedByUser: Bool { status != .active && demotedByMerge != true }
}

extension Settings {
    public var versionTime: Date { updatedAt ?? .distantPast }
    /// When the rhythm last changed (older data, with no field stamps: when any setting did).
    public var rhythmVersion: Date { rhythmUpdatedAt ?? legacyVersion ?? .distantPast }
    /// When the cloud-help switch last changed (older data, with no field stamps: when any setting did).
    public var cloudAssistVersion: Date { cloudAssistUpdatedAt ?? legacyVersion ?? .distantPast }
    /// Settings saved before field stamps had one stamp for everything.
    private var legacyVersion: Date? { rhythmUpdatedAt == nil && cloudAssistUpdatedAt == nil ? updatedAt : nil }
}

extension Step {
    /// When the completion last changed: its own stamp, else the completion itself, else creation.
    public var completionTime: Date { completionChangedAt ?? completedAt ?? createdAt }
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
///   (that device ended it itself: it is in its past goals, not merely demoted there by a merge). A goal
///   created on a device that never saw the current one (onboarding on a second device, two offline
///   replacements) never replaces it: the earlier goal stays current and the newcomer is kept as a replaced
///   past goal marked `demotedByMerge`. That device's settings don't win either. If every current goal was
///   ended elsewhere, the newest goal a merge demoted and nobody ended comes back as current.
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
        case nil: snap.settings = mergeSettings(newer.snapshot.settings, older.snapshot.settings)
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

    /// Synced settings field by field (`a` from the newer envelope wins ties): the rhythm and the cloud-help
    /// switch each on their own stamp, so changing one on one device never undoes the other changed
    /// elsewhere. Device-local fields (`Settings.DeviceLocal`) come along from `a`, and every device puts
    /// its own back after the merge (`SyncApply`).
    public static func mergeSettings(_ a: Settings, _ b: Settings) -> Settings {
        var s = a
        let rhythm = b.rhythmVersion > a.rhythmVersion ? b : a
        let cloud = b.cloudAssistVersion > a.cloudAssistVersion ? b : a
        s.rhythm = rhythm.rhythm
        s.cloudAssist = cloud.cloudAssist
        // Written out per field, so a side with one legacy stamp doesn't lend it to the other field.
        s.rhythmUpdatedAt = rhythm.rhythmVersion == .distantPast ? nil : rhythm.rhythmVersion
        s.cloudAssistUpdatedAt = cloud.cloudAssistVersion == .distantPast ? nil : cloud.cloudAssistVersion
        s.updatedAt = [a.updatedAt, b.updatedAt].compactMap { $0 }.max()
        return s
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

    /// Two versions of one goal (`a` from the newer envelope): a version the user ended wins over an active
    /// one (ending happens after editing); otherwise the later `versionTime`. A copy a merge demoted counts
    /// as active here (nobody ended it; `mergeGoals` decides its status again). Parts and the B7 answer
    /// merge field-wise so neither device's addition is lost.
    static func pickGoal(_ a: Goal, _ b: Goal) -> Goal {
        let aEnded = a.isEndedByUser, bEnded = b.isEndedByUser
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

    /// Goals merge by id; the picked version (`pickGoal`) carries the content.
    /// - **Retired:** a goal either side ended itself (in its past goals, not marked `demotedByMerge`) stays
    ///   ended: that device knew it and moved on.
    /// - **Candidates** for current: every side's current goal that no side retired. A copy some merge
    ///   demoted doesn't disqualify it, so a device that put a fresh goal back on top (`SyncApply`) isn't
    ///   outvoted by an old device that merged the fresh goal first and demoted it.
    /// - Two or more candidates (neither device knew the other's): the earliest-created stays current; each
    ///   newcomer becomes a replaced past goal marked `demotedByMerge`, and its side is reported as `demoted`.
    ///   The winner comes back as current even if the picked copy was a demoted one.
    /// - **No candidate** (every side's current goal was retired elsewhere): the newest goal a merge demoted
    ///   and nobody retired comes back as current (`orphan`). Without it every device could settle on no
    ///   current goal while a goal nobody ended sits in past goals.
    static func mergeGoals(newer: CompassSnapshot, older: CompassSnapshot) -> (current: Goal?, past: [Goal], demoted: Side?) {
        var versions: [UUID: Goal] = [:]
        // A past goal holding `.active` (never written by this app) is read as replaced, so status alone
        // tells an ended copy from a live one.
        func normalizedPast(_ g: Goal) -> Goal {
            var g = g
            if g.status == .active, g.demotedByMerge != true { g.status = .replaced; g.endedAt = g.endedAt ?? g.versionTime }
            return g
        }
        for g in older.pastGoals.map(normalizedPast) + [older.goal].compactMap({ $0 }) {
            versions[g.id] = versions[g.id].map { pickGoal($0, g) } ?? g
        }
        for g in newer.pastGoals.map(normalizedPast) + [newer.goal].compactMap({ $0 }) {
            versions[g.id] = versions[g.id].map { pickGoal(g, $0) } ?? g
        }

        let retired = Set((newer.pastGoals + older.pastGoals).filter { $0.demotedByMerge != true }.map(\.id))
        var pastIDs = Set(newer.pastGoals.map(\.id)).union(older.pastGoals.map(\.id))
        let candidates = Set([newer.goal?.id, older.goal?.id].compactMap { $0 }).subtracting(retired)
            .compactMap { versions[$0] }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        var current = candidates.first ?? orphan(in: versions, retired: retired)
        if var winner = current, winner.demotedByMerge == true {
            // The picked copy was one a merge had demoted; it is current again.
            winner.demotedByMerge = nil
            if winner.status == .replaced { winner.status = .active; winner.endedAt = nil }
            current = winner
        }
        if let current {
            versions[current.id] = current
            pastIDs.remove(current.id)
        }
        var demoted: Side?
        for loser in candidates.dropFirst() {
            var ended = loser
            if ended.status == .active { ended.status = .replaced }
            ended.endedAt = ended.endedAt ?? loser.versionTime
            ended.demotedByMerge = true
            versions[loser.id] = ended
            pastIDs.insert(loser.id)
            demoted = newer.goal?.id == loser.id ? .newer : .older
        }
        for id in retired {
            // Ended by a user somewhere: no merge marker survives on it.
            guard var g = versions[id], g.demotedByMerge == true else { continue }
            g.demotedByMerge = nil
            if g.status == .active { g.status = .replaced; g.endedAt = g.endedAt ?? g.versionTime }
            versions[id] = g
        }
        let pastList = pastIDs.compactMap { versions[$0] }.sorted {
            ($0.endedAt ?? $0.createdAt, $0.id.uuidString) > ($1.endedAt ?? $1.createdAt, $1.id.uuidString)
        }
        return (current, pastList, demoted)
    }

    /// No side holds a current goal anyone may keep (each was ended by another device), but a merge demoted
    /// a goal that no user ended: the newest such goal comes back as current, so a goal nobody ended always
    /// has a holder. The newest, because every goal it was demoted below has since been ended; it is the
    /// last goal a user chose. Never a retired goal (one some device ended itself).
    static func orphan(in versions: [UUID: Goal], retired: Set<UUID>) -> Goal? {
        versions.values
            .filter { $0.demotedByMerge == true && !retired.contains($0.id) }
            .max { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
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
        case let (a?, b?) where a.id == b.id:
            // Title, part and size from the later edit; the completion on its own stamp.
            var step = latest(a, b, by: \.versionTime)
            let completion = latest(a, b, by: \.completionTime)
            step.completedAt = completion.completedAt
            step.completionChangedAt = completion.completionChangedAt
            d.step = step
        case let (a?, b?): d.step = latest(a, b, by: \.createdAt)
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
            if let s = d.step, let gone = removed[s.id], s.lastTouched <= gone { d.step = nil }
        }

        d.morningSkipped = n.morningSkipped || o.morningSkipped
        d.morningSkippedAt = [n.morningSkippedAt, o.morningSkippedAt].compactMap { $0 }.min()

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
    /// What survives a "Delete everything" made at `wipe`: only things created at or after it. Synced
    /// settings last changed before it go back to defaults (field by field); this device's own settings
    /// stay. Days left with nothing are dropped, but a day that only says the morning was skipped after
    /// the wipe, or only remembers notes and steps deleted after it, is kept: dropping it would bring the
    /// morning back, or let another device revive the deleted note.
    public func keepingOnly(createdSince wipe: Date) -> CompassSnapshot {
        var s = CompassSnapshot()
        s.goal = goal.flatMap { $0.createdAt >= wipe ? $0 : nil }
        s.pastGoals = pastGoals.filter { $0.createdAt >= wipe }
        s.settings = settings.keepingOnly(changedSince: wipe)
        for day in days {
            var d = Day(key: day.key, goalID: day.goalID)
            d.intention = day.intention.flatMap { $0.createdAt >= wipe ? $0 : nil }
            d.step = day.step.flatMap { $0.createdAt >= wipe ? $0 : nil }
            d.notes = day.notes.filter { $0.createdAt >= wipe }
            let versions = day.reflectionVersions.filter { $0.createdAt >= wipe }
            d.reflection = day.reflection.flatMap { $0.createdAt >= wipe ? $0 : nil } ?? versions.first
            let others = versions.filter { $0.createdAt != d.reflection?.createdAt }
            d.mergeCandidates = others.isEmpty ? nil : others
            let removed = (day.removedItems ?? []).filter { $0.deletedAt >= wipe }
            d.removedItems = removed.isEmpty ? nil : removed
            let hasContent = d.intention != nil || d.step != nil || !d.notes.isEmpty || d.reflection != nil
            // A skip stays with a day that kept content, and on its own when it was made after the wipe.
            if day.morningSkipped, hasContent || day.skippedSince(wipe) {
                d.morningSkipped = true
                d.morningSkippedAt = day.morningSkippedAt
            }
            guard hasContent || d.morningSkipped || d.removedItems != nil else { continue }
            s.days.append(d)
        }
        return s
    }

    /// Nothing the user made: no goal, and no day with content. Days that only remember a morning skip
    /// or deletions (kept after a wipe, `keepingOnly`) don't count: there is nothing to show or restore.
    public var isBlank: Bool { !hasGoals && !days.contains(where: \.hasContent) }

    /// A current goal or any past goal.
    public var hasGoals: Bool { goal != nil || !pastGoals.isEmpty }
}

extension Settings {
    /// After a wipe at `wipe`: each synced field changed before it goes back to its default. This
    /// device's own settings (`DeviceLocal`) are not part of any generation and stay.
    func keepingOnly(changedSince wipe: Date) -> Settings {
        let defaults = Settings()
        var s = self
        if rhythmVersion < wipe {
            s.rhythm = defaults.rhythm
            s.rhythmUpdatedAt = nil
        }
        if cloudAssistVersion < wipe {
            s.cloudAssist = defaults.cloudAssist
            s.cloudAssistUpdatedAt = nil
        }
        if versionTime < wipe { s.updatedAt = nil }
        return s
    }
}

extension Day {
    /// The morning skip was made at or after `wipe`: its stamp says so, or (older data) the day itself
    /// is not before the wipe's day anywhere on Earth (UTC, with a day of slack for time zones).
    func skippedSince(_ wipe: Date) -> Bool {
        if let at = morningSkippedAt { return at >= wipe }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return key >= DayKey(wipe, calendar: utc).adding(days: -1, calendar: utc)
    }
}

// MARK: - Day conflict helpers (E5)

extension Day {
    /// Something the user wrote or recorded: an intention, a step, a note or an evening entry.
    public var hasContent: Bool { intention != nil || step != nil || !notes.isEmpty || !reflectionVersions.isEmpty }

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
        if let s = step { dates.append(s.lastTouched) }
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
