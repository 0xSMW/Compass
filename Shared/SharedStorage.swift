import Foundation
import CompassCore

/// Storage shared by the app and the widget (App Group container). Unsigned simulator builds have no
/// App Group container, so each process falls back to its own Application Support folder.
enum SharedStorage {
    static let appGroup = "group.app.compass.shared"
    static let widgetKind = "CompassTodayStep"

    static var directory: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var snapshotURL: URL { directory.appendingPathComponent("Compass/compass.json") }

    static func makeStore() -> JSONFileStore { JSONFileStore(url: snapshotURL) }

    /// Calendar for the user's rhythm: settings time zone, else the device's.
    static func calendar(for settings: Settings) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = .autoupdatingCurrent // the user's locale for dates (History, I5)
        if let id = settings.timeZoneID, let tz = TimeZone(identifier: id) { c.timeZone = tz } else { c.timeZone = .current }
        return c
    }
}
