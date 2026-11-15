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
    static func start(with model: AppModel) {
        SoundSetting.apply()
        guard coordinator == nil, model.fixture == nil else { return }
        let c = SyncCoordinator(model: model)
        coordinator = c
        c.start()
    }

    static func didChangeLocally() { coordinator?.noteLocalChange() }

    static func recordDeletion(of key: DayKey, at date: Date) { coordinator?.recordDeletion(of: key, at: date) }

    static func wipeEverywhere(at date: Date) { coordinator?.wipeEverywhere(at: date) }

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
        return LiveSync.backupRestorer
    }

    /// Put a restored snapshot into the app (R2) and save it; sync carries on from it.
    func applyRestoredSnapshot(_ restored: CompassSnapshot) {
        snapshot = restored
        calendar = SharedStorage.calendar(for: restored.settings)
        if let http = cloud as? HTTPCloudAssist { http.switchOn = restored.settings.cloudAssist }
        saveAndSync()
    }

    /// Save through the store and tell sync (AppModel.persist is private to the shared file).
    func saveAndSync() {
        try? store.save(snapshot)
        LiveSync.didChangeLocally()
    }
}
