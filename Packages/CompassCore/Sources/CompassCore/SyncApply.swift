import Foundation

// MARK: - What a sync pass does

/// Everything `SyncCoordinator.apply` knows when envelopes arrive from iCloud.
public struct SyncApplyInput: Sendable {
    /// This device's envelope, built from the model as it is now.
    public var local: SyncEnvelope
    /// Every envelope read from iCloud (this device's own file among them is ignored).
    public var remote: [SyncEnvelope]
    /// The newest "Delete everything" this device has already carried out.
    public var appliedWipe: Date?
    /// An onboarding step (A1–A7) is on screen: nothing may end it or reset what the user has typed.
    public var isOnboarding: Bool
    /// A goal this device created in onboarding before it had seen the user's iCloud data (A1 "Start a
    /// new goal", or Begin tapped before the backup check finished). It must win over the backup's goal.
    /// It guards sync passes until one promotes it or reads another device's goals, and expires after
    /// `freshGoalLifetime` (see `SyncApply`).
    public var freshGoalID: UUID?
    /// The time of this pass, for the fresh goal's expiry. nil skips the age check.
    public var now: Date?

    public init(local: SyncEnvelope, remote: [SyncEnvelope], appliedWipe: Date? = nil, isOnboarding: Bool = false,
                freshGoalID: UUID? = nil, now: Date? = nil) {
        self.local = local
        self.remote = remote
        self.appliedWipe = appliedWipe
        self.isOnboarding = isOnboarding
        self.freshGoalID = freshGoalID
        self.now = now
    }
}

/// The decision, carried out by the coordinator.
public struct SyncApplyPlan: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// The model already holds the merged result.
        case keep
        /// Another device's "Delete everything", and nothing was made here since: erase this device too.
        case eraseLocal
        /// Put this snapshot into the model.
        case adopt(CompassSnapshot, Source)
    }

    public enum Source: Equatable, Sendable {
        /// Other devices' changes (not this device's own edit, not stamped).
        case merge
        /// This device's change (a fresh goal put back on top of the backup's): stamped and pushed.
        case localChange
    }

    public var action: Action
    /// The merged envelope: tombstones, wipe and audio tombstones to keep.
    public var merged: SyncEnvelope
    /// The merge carries a wipe this device hasn't carried out yet.
    public var newWipe: Bool
    /// Only what this device made after a wipe is left: open wherever that leads.
    public var openEntry: Bool
    /// What to remember as `SyncApplyInput.freshGoalID` for the next pass.
    public var freshGoalID: UUID?
}

/// `SyncCoordinator.apply`'s decision as a pure function, so every branch is tested without iCloud:
///
/// 1. **Remote wipe, nothing made here since** → `.eraseLocal`.
/// 2. **Remote wipe with local survivors** → adopt what survives, `openEntry` (the screen it was on may be gone).
/// 3. **A goal arriving mid-onboarding** → adopt the merge and stay on the onboarding step. The draft is never
///    reset: finishing onboarding then sets the new goal on top (`setGoal`), so the arrived goal becomes a
///    past goal and the history stays.
/// 4. **A fresh goal demoted by the merge** (onboarding finished here before the backup arrived) → put it back
///    as current with the backup's goal in past goals, as if the backup had been merged first; this device's
///    settings come back too. Adopted as a local change, so the result travels and every device agrees.
///    The marker (`freshGoalID`) lasts until the first pass that promotes or reads another device's
///    envelope holding a goal (current or past), or `freshGoalLifetime` after the goal was made, whichever
///    comes first; a goal-less envelope (an install that hasn't onboarded) doesn't use it up. After that
///    the merge alone keeps the result: the backup's goal is ended by this device, and an old device that
///    demoted the fresh goal first only marked it `demotedByMerge`, which never outvotes the device holding
///    it as current.
/// 5. **Otherwise** → adopt the merge when it differs from the model, else keep.
///
/// In every case this device's own settings (`Settings.DeviceLocal`: reminders switch, input, time-zone pin)
/// stay as they are here; they never come from another device.
public enum SyncApply {
    public static func plan(_ input: SyncApplyInput) -> SyncApplyPlan? {
        let local = input.local
        let others = input.remote.filter { $0.deviceID != local.deviceID }
        guard let merged = SnapshotMerger.merge([local] + others) else { return nil }
        let before = local.snapshot
        let newWipe = merged.wipedAt.map { $0 > (input.appliedWipe ?? .distantPast) } ?? false
        // An old wipe a fresh install hears about for the first time has nothing here to erase.
        let lostLocalData = newWipe && merged.wipedAt.map { before.keepingOnly(createdSince: $0) != before } == true

        var plan = SyncApplyPlan(action: .keep, merged: merged, newWipe: newWipe, openEntry: false,
                                 freshGoalID: input.freshGoalID)
        // Blank: no goal and no day with content (a skip made here after the wipe doesn't count).
        if lostLocalData && merged.snapshot.isBlank {
            plan.action = .eraseLocal
            plan.freshGoalID = nil
            return plan
        }

        var next = merged.snapshot
        next.settings = next.settings.keepingDeviceLocal(before.settings.deviceLocal)
        var source = SyncApplyPlan.Source.merge
        if let freshID = input.freshGoalID {
            if let fresh = before.goal, fresh.id == freshID, !isExpired(fresh, now: input.now) {
                let promoted = promoting(fresh, settings: before.settings, in: next)
                if let promoted {
                    next = promoted
                    source = .localChange
                }
                // Settled once this pass promoted, or read another device's goals (current or past) and
                // found nothing to promote over. An envelope with no goals (an install still onboarding, or
                // never onboarded) says nothing about the backup, so the marker waits for the next pass.
                if promoted != nil || others.contains(where: { $0.isReadable && $0.snapshot.hasGoals }) {
                    plan.freshGoalID = nil
                }
            } else {
                // Expired, or no longer this device's current goal (replaced, ended): nothing to guard.
                plan.freshGoalID = nil
            }
        }

        if next != before { plan.action = .adopt(next, source) }
        plan.openEntry = lostLocalData && !input.isOnboarding
        return plan
    }

    /// How long a fresh goal is guarded when no other device's envelope shows up (a single-device account):
    /// an old device appearing months later doesn't see its goal ended by it.
    public static let freshGoalLifetime: TimeInterval = 7 * 24 * 60 * 60

    static func isExpired(_ fresh: Goal, now: Date?) -> Bool {
        guard let now else { return false }
        return now.timeIntervalSince(fresh.createdAt) > freshGoalLifetime
    }

    /// The merge demoted `fresh` (an earlier goal from another device stays current, because this device
    /// never knew it). Returns the snapshot with `fresh` current again and the other goal ended as replaced,
    /// or nil when `fresh` wasn't demoted that way (e.g. another device replaced it with a later goal).
    static func promoting(_ fresh: Goal, settings: Settings, in s: CompassSnapshot) -> CompassSnapshot? {
        guard let current = s.goal, current.id != fresh.id, current.createdAt <= fresh.createdAt,
              let demoted = s.pastGoals.first(where: { $0.id == fresh.id }) else { return nil }
        var out = s
        // Ended by this device (as if it had set the fresh goal over it): not a merge's demotion.
        var ended = current
        if ended.status == .active { ended.status = .replaced }
        ended.endedAt = ended.endedAt ?? fresh.createdAt
        ended.demotedByMerge = nil
        var promoted = demoted
        promoted.status = fresh.status
        promoted.endedAt = fresh.endedAt
        promoted.demotedByMerge = nil
        out.goal = promoted
        out.pastGoals = ([ended] + s.pastGoals.filter { $0.id != fresh.id && $0.id != current.id }).sorted {
            ($0.endedAt ?? $0.createdAt, $0.id.uuidString) > ($1.endedAt ?? $1.createdAt, $1.id.uuidString)
        }
        out.settings = SnapshotMerger.mergeSettings(settings, s.settings).keepingDeviceLocal(settings.deviceLocal)
        return out
    }
}

// MARK: - The store file and the widget

/// When the app looks at the store file for changes another process (the widget) made.
public enum StoreReload {
    /// Read the file only when it changed after this app's last successful save, and never while a save
    /// has failed (the file is then older than the app's memory, and taking it would undo what was added).
    public static func shouldRead(fileModifiedAt: Date?, lastSavedAt: Date?, saveFailed: Bool) -> Bool {
        guard !saveFailed, let fileModifiedAt else { return false }
        guard let lastSavedAt else { return true }
        return fileModifiedAt > lastSavedAt
    }
}

extension CompassSnapshot {
    /// What the widget changed in the store file, taken into this snapshot: a step completed or undone
    /// there more recently than here. Nothing else is read from the file, so a stale file never deletes
    /// a note or a step (nothing missing from it counts as removed).
    public func takingWidgetChanges(from file: CompassSnapshot) -> CompassSnapshot {
        var out = self
        for fileDay in file.days {
            guard let theirs = fileDay.step, let i = out.days.firstIndex(where: { $0.key == fileDay.key }),
                  let ours = out.days[i].step, ours.id == theirs.id, theirs.completionTime > ours.completionTime else { continue }
            out.days[i].step?.completedAt = theirs.completedAt
            out.days[i].step?.completionChangedAt = theirs.completionChangedAt
        }
        return out
    }
}

// MARK: - Audio tombstones

extension AudioTombstone {
    /// How long a deletion is remembered. A device offline for longer than this could only bring a file
    /// back if its snapshot still used it, and the merge has removed the item by then.
    public static let retention: TimeInterval = 90 * 24 * 60 * 60

    /// Deletions younger than `retention`.
    public static func pruned(_ tombstones: [AudioTombstone], now: Date) -> [AudioTombstone] {
        tombstones.filter { now.timeIntervalSince($0.deletedAt) <= retention }
    }

    /// Only a recording some snapshot used can be in iCloud or on another device (`AudioSyncPlan` moves
    /// nothing else), so only those need a tombstone. A discarded take never does.
    public static func isNeeded(for name: String, referenced: Set<String>) -> Bool {
        referenced.contains(name)
    }
}
