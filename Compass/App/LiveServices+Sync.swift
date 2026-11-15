import Foundation
import CompassCore

/// Composition for the live (non `-screen`) app: iCloud sync, backup restore and the cloud-assist client.
/// Screenshot runs never start any of this; they keep the fixtures and fakes set up in `AppModel.init`.
@MainActor
enum LiveSync {
    private static var coordinator: SyncCoordinator?
    private static var restorer: BackupRestoring?

    /// True once iCloud is reachable for Compass (account signed in, entitlement present).
    static var iCloudInUse: Bool { coordinator?.iCloudAvailable ?? false }

    /// The real `CloudAssist`, behind the Settings switch and disabled when no endpoint is configured.
    nonisolated static func makeCloudAssist(settings: Settings) -> CloudAssist {
        HTTPCloudAssist(configuration: CloudAssistEndpoint.configuration, switchOn: settings.cloudAssist)
    }

    /// Start syncing the model's snapshot and audio through iCloud. Call once, from the live path.
    /// Not while the store holds data from a newer Compass (nothing here may overwrite or merge it).
    static func start(with model: AppModel) {
        SoundSetting.apply()
        guard coordinator == nil, model.fixture == nil, !(model.storeProblem?.blocksSaving ?? false) else { return }
        let c = SyncCoordinator(model: model)
        coordinator = c
        c.start()
    }

    static func didChangeLocally() { coordinator?.noteLocalChange() }

    /// This install (its sync device id and model). Before sync has started, the saved id if any.
    static var deviceIdentity: DeviceIdentity {
        coordinator?.deviceIdentity
            ?? DeviceIdentity(id: SyncState.load()?.deviceID ?? "this-device", model: SyncDevice.model)
    }

    static func recordDeletion(of key: DayKey, at date: Date) { coordinator?.recordDeletion(of: key, at: date) }

    static func wipeEverywhere(at date: Date) { coordinator?.wipeEverywhere(at: date) }

    /// A first goal made here before the user's iCloud data was merged (see `SyncCoordinator.markFreshGoal`).
    static func markFreshGoal(_ id: UUID) { coordinator?.markFreshGoal(id) }

    /// Read iCloud now.
    static func pullNow() { coordinator?.pullNow() }

    static var backupRestorer: BackupRestoring {
        if let restorer { return restorer }
        let r = ICloudBackupRestorer()
        restorer = r
        return r
    }
}

extension AppModel {
    /// R1–R3 use this: the user's iCloud in the live app, `FakeBackupRestoring` in screenshot runs
    /// (R1/R2 restore the fixture; R3 has nothing).
    var backupRestorer: BackupRestoring {
        if fixture != nil { return FakeBackupRestoring(conditions: conditions) }
        if launch.tapThrough { return FakeBackupRestoring(snapshot: nil) } // a fresh install: Begin onboards
        return LiveSync.backupRestorer
    }

    /// This install, for stamping new recordings and telling devices apart in E5. Screenshot runs use a
    /// fixed id and take the fixtures' "This iPhone" labels at their word.
    var deviceIdentity: DeviceIdentity {
        if fixture != nil || launch.tapThrough { return DeviceIdentity(id: "fixture-device", model: SyncDevice.model, trustsLegacyLabels: true) }
        return LiveSync.deviceIdentity
    }

    /// Put a restored snapshot into the app (R2) and save it; sync carries on from it. Restored items
    /// keep their own devices and times (they are not stamped as made here).
    func applyRestoredSnapshot(_ restored: CompassSnapshot) {
        // This device's own settings (reminders switch, input, time-zone pin) are not restored from another.
        var restored = restored
        restored.settings = restored.settings.keepingDeviceLocal(settings.deviceLocal)
        commit(restored, origin: .restored)
        calendar = SharedStorage.calendar(for: restored.settings)
        if let http = cloud as? HTTPCloudAssist { http.switchOn = restored.settings.cloudAssist }
    }
}
