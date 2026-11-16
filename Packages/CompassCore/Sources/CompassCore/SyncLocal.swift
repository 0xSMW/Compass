import Foundation

// MARK: - Device identity (E5)

/// This install, as items and envelopes name it. E5 labels compare an item's `deviceID` with `id`, so
/// "This iPhone" is only ever shown for things recorded here, and another iPhone reads "iPhone".
public struct DeviceIdentity: Hashable, Sendable {
    /// `SyncEnvelope.deviceID` of this install.
    public var id: String
    /// "iPhone", "iPad".
    public var model: String
    /// Fixtures (and data saved before device ids) name the recording device "This iPhone" without an id.
    /// Screenshot runs take that at its word; the live app can't, because a merge used to copy another
    /// device's "This iPhone" in, so such items show their model name only.
    public var trustsLegacyLabels: Bool

    public init(id: String, model: String, trustsLegacyLabels: Bool = false) {
        self.id = id
        self.model = model
        self.trustsLegacyLabels = trustsLegacyLabels
    }

    /// "This iPhone" → "iPhone"; "iPad" stays.
    public static func modelName(_ name: String?) -> String? {
        guard var name, !name.isEmpty else { return nil }
        if name.hasPrefix("This ") { name.removeFirst("This ".count) }
        return name.isEmpty ? nil : name
    }

    public func isLocal(deviceID: String?, name: String?) -> Bool {
        if let deviceID { return deviceID == id }
        return trustsLegacyLabels && (name?.hasPrefix("This ") ?? false)
    }

    /// "This iPhone" for this install; otherwise the recording device's model, or "Another device".
    public func label(deviceID: String?, name: String?) -> String {
        if isLocal(deviceID: deviceID, name: name) { return "This \(model)" }
        return Self.modelName(name) ?? "Another device"
    }

    public func isTablet(deviceID: String?, name: String?) -> Bool {
        label(deviceID: deviceID, name: name).lowercased().contains("ipad")
    }

    public func isLocal(_ r: Reflection) -> Bool { isLocal(deviceID: r.deviceID, name: r.device) }
    public func label(for r: Reflection) -> String { label(deviceID: r.deviceID, name: r.device) }
    public func isTablet(_ r: Reflection) -> Bool { isTablet(deviceID: r.deviceID, name: r.device) }

    /// E5's preselected version: the one recorded here, else the earliest.
    public func defaultChoice(_ versions: [Reflection]) -> Reflection? {
        versions.first(where: isLocal) ?? versions.min { $0.createdAt < $1.createdAt }
    }
}

// MARK: - Stamping local edits

/// Gives local edits what the merge needs, without every feature remembering to: compares the snapshot
/// after a local change with the one before it and
/// - sets `updatedAt = now` on every existing item whose content changed (unless the edit set it itself),
/// - puts this install's `deviceID` and model on new notes and reflections recorded here,
/// - records notes and steps that disappeared from a day (`Day.removedItems`), so merges don't revive them.
/// Items new to this snapshot keep `updatedAt == nil` (their `createdAt` is their version time).
public enum LocalEdits {
    public static func stamp(_ new: CompassSnapshot, since old: CompassSnapshot, at now: Date, device: DeviceIdentity) -> CompassSnapshot {
        guard new != old else { return new }
        var s = new
        s.settings = stampSettings(new.settings, since: old.settings, at: now)

        let oldGoals = Dictionary((old.pastGoals + [old.goal].compactMap { $0 }).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func stampGoal(_ g: Goal) -> Goal {
            var g = g
            if let before = oldGoals[g.id], changed(g, before, \.updatedAt) { g.updatedAt = now }
            if let why = g.why, oldGoals[g.id]?.why?.id != why.id { g.why = claim(why, device) }
            return g
        }
        s.goal = s.goal.map(stampGoal)
        // Setting a new goal here moves on from every past goal knowingly, including ones a merge demoted:
        // from now on they count as ended by this device (`Goal.demotedByMerge`), at the new goal's
        // `createdAt`. The merge dated a demoted goal's end with another device's clock; restamping it with
        // this one keeps `SyncApply.replacedKnowingly` comparing two times from the same clock. Only a
        // replaced goal is restamped: an achieved one keeps its achievement time, and a goal a user ended
        // never carries the marker.
        let newGoal = new.goal?.id == old.goal?.id ? nil : new.goal
        s.pastGoals = s.pastGoals.map { g in
            var g = g
            if let newGoal, g.demotedByMerge == true {
                g.demotedByMerge = nil
                if g.status == .replaced { g.endedAt = newGoal.createdAt }
            }
            return stampGoal(g)
        }

        let oldDays = Dictionary(old.days.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        s.days = s.days.map { day in
            guard let before = oldDays[day.key] else {
                var d = claimNew(in: day, device)
                if d.morningSkipped, d.morningSkippedAt == nil { d.morningSkippedAt = now }
                return d
            }
            if day == before { return day }
            var d = day
            if let i = d.intention, let b = before.intention, i.createdAt == b.createdAt, changed(i, b, \.updatedAt) {
                d.intention?.updatedAt = now
            }
            if let st = d.step, let b = before.step, st.id == b.id {
                // Completing or undoing stamps only the completion, so a title or part edit made elsewhere
                // (even earlier) still wins on `updatedAt`; any other change stamps `updatedAt`.
                if st.completedAt != b.completedAt, st.completionChangedAt == b.completionChangedAt {
                    d.step?.completionChangedAt = now
                }
                var stContent = st, bContent = b
                stContent.completedAt = nil; stContent.completionChangedAt = nil
                bContent.completedAt = nil; bContent.completionChangedAt = nil
                if changed(stContent, bContent, \.updatedAt) { d.step?.updatedAt = now }
            }
            if d.morningSkipped, !before.morningSkipped, d.morningSkippedAt == nil { d.morningSkippedAt = now }
            var gone = Set(before.notes.map(\.id)).subtracting(d.notes.map(\.id))
            if let s = before.step, d.step?.id != s.id { gone.insert(s.id) }
            if !gone.isEmpty {
                var removed = Dictionary((d.removedItems ?? []).map { ($0.id, $0.deletedAt) }, uniquingKeysWith: max)
                for id in gone { removed[id] = now }
                d.removedItems = removed.map { ItemTombstone(id: $0.key, deletedAt: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
            }
            let oldNotes = Dictionary(before.notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            d.notes = d.notes.map { n in
                guard let b = oldNotes[n.id] else { return claim(n, device) }
                var n = n
                if changed(n, b, \.updatedAt) { n.updatedAt = now }
                return n
            }
            let oldReflections = Dictionary(before.reflectionVersions.map { ($0.createdAt, $0) }, uniquingKeysWith: { a, _ in a })
            func stampReflection(_ r: Reflection) -> Reflection {
                guard let b = oldReflections[r.createdAt] else { return claim(r, device) }
                var r = r
                if changed(r, b, \.updatedAt) { r.updatedAt = now }
                return r
            }
            d.reflection = d.reflection.map(stampReflection)
            d.mergeCandidates = d.mergeCandidates?.map(stampReflection)
            return d
        }
        return s
    }

    /// Synced fields get their own stamps (and `updatedAt`) when they change. Device-local fields
    /// (`Settings.DeviceLocal`) never stamp anything: they don't travel.
    static func stampSettings(_ new: Settings, since old: Settings, at now: Date) -> Settings {
        var s = new
        var syncedChanged = false
        if new.rhythm != old.rhythm {
            syncedChanged = true
            if new.rhythmUpdatedAt == old.rhythmUpdatedAt { s.rhythmUpdatedAt = now }
        }
        if new.cloudAssist != old.cloudAssist {
            syncedChanged = true
            if new.cloudAssistUpdatedAt == old.cloudAssistUpdatedAt { s.cloudAssistUpdatedAt = now }
        }
        if syncedChanged, new.updatedAt == old.updatedAt { s.updatedAt = now }
        return s
    }

    /// Content differs, ignoring the stamp, and the edit didn't set a new stamp itself.
    static func changed<T: Equatable>(_ new: T, _ old: T, _ stamp: WritableKeyPath<T, Date?>) -> Bool {
        guard new[keyPath: stamp] == old[keyPath: stamp] else { return false }
        var a = new, b = old
        a[keyPath: stamp] = nil
        b[keyPath: stamp] = nil
        return a != b
    }

    /// Recorded here: features store "This iPhone" (or nothing); a version from another device already
    /// names its device and keeps it.
    static func recordedHere(deviceID: String?, name: String?) -> Bool {
        deviceID == nil && (name == nil || name?.hasPrefix("This ") == true)
    }

    static func claim(_ n: Note, _ device: DeviceIdentity) -> Note {
        guard recordedHere(deviceID: n.deviceID, name: n.device) else { return n }
        var n = n
        n.deviceID = device.id
        n.device = device.model
        return n
    }

    static func claim(_ r: Reflection, _ device: DeviceIdentity) -> Reflection {
        guard recordedHere(deviceID: r.deviceID, name: r.device) else { return r }
        var r = r
        r.deviceID = device.id
        r.device = device.model
        return r
    }

    static func claimNew(in day: Day, _ device: DeviceIdentity) -> Day {
        var d = day
        d.notes = d.notes.map { claim($0, device) }
        d.reflection = d.reflection.map { claim($0, device) }
        return d
    }
}

// MARK: - Audio a snapshot refers to

/// Recording file names, shared by the app's `VoiceStorage` and sync: `<id>.m4a`.
public enum AudioNaming {
    public static func fileName(for id: UUID) -> String { "\(id.uuidString).m4a" }
}

extension CompassSnapshot {
    /// Every recording file the snapshot uses: evening entries (all versions), spoken notes
    /// (`<note id>.m4a`) and the B7 answers. Sync uploads and downloads only these, so a deleted
    /// recording (its item gone, or replaced on redo) never travels again.
    public var referencedAudioFiles: Set<String> {
        var names = Set<String>()
        for d in days {
            for r in d.reflectionVersions { if let f = r.audioFileName { names.insert(f) } }
            for n in d.notes where n.isSpoken { names.insert(AudioNaming.fileName(for: n.id)) }
        }
        for g in [goal].compactMap({ $0 }) + pastGoals {
            if let why = g.why, why.isSpoken { names.insert(AudioNaming.fileName(for: why.id)) }
        }
        return names
    }
}

/// Which recordings to copy, given what each side has and what was deleted. Pure, so the rules are
/// testable without iCloud.
public enum AudioSyncPlan {
    /// Local files to copy into iCloud: referenced, not deleted anywhere, not there yet.
    public static func toUpload(local: Set<String>, remote: Set<String>, referenced: Set<String>, tombstones: [AudioTombstone]) -> Set<String> {
        local.intersection(referenced).subtracting(remote).subtracting(tombstones.map(\.name))
    }

    /// iCloud files to bring here: referenced by the merged snapshot, not deleted, not here yet.
    public static func toDownload(remote: Set<String>, local: Set<String>, referenced: Set<String>, tombstones: [AudioTombstone]) -> Set<String> {
        remote.intersection(referenced).subtracting(local).subtracting(tombstones.map(\.name))
    }

    /// Local files to remove after a merge: deleted on some device, or used before the merge and not
    /// after it (their day was deleted or wiped elsewhere). Files the snapshot never used (a take being
    /// recorded right now) are left alone.
    public static func toRemoveLocally(local: Set<String>, referencedBefore: Set<String>, referencedAfter: Set<String>, tombstones: [AudioTombstone]) -> Set<String> {
        let dropped = referencedBefore.subtracting(referencedAfter)
        return local.intersection(dropped.union(tombstones.map(\.name)))
    }
}
