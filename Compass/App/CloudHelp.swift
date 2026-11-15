import Foundation
import CompassCore

/// Cloud help (summaries and step ideas) as the app sees it. The contract a backend implements is in
/// `docs/CLOUD_ASSIST.md`. Builds without an endpoint (the repo default) say so where the switch lives
/// (A7, H1) instead of showing a switch that does nothing.
extension AppModel {
    /// A cloud endpoint is configured for this build. Fakes (screenshots, tests) count as configured.
    var cloudHelpConfigured: Bool {
        if let http = cloud as? HTTPCloudAssist { return http.isConfigured }
        return true
    }

    /// Cloud help will actually be asked: the switch is on and there is somewhere to ask.
    var cloudHelpOn: Bool { settings.cloudAssist && cloudHelpConfigured }

    /// The connection came back (or the app became active online): retry what waited for it.
    /// Today's evening summary (D6 "Text and summary appear here when you reconnect.").
    func retryCloudWorkAfterReconnect() async {
        guard cloudHelpOn, ReflectionRules.waitsForNetwork(eveningDay?.reflection), !eveningSession.working else { return }
        await refreshReflection()
    }
}

/// Copy for builds without a cloud endpoint, in the boards' tone.
enum CloudHelpCopy {
    /// A7, under "Summaries and step ideas".
    static let notSetUpCaption = "Not set up in this version of Compass, so nothing leaves your phone for it. You get plain transcripts and no ideas."
    /// H1 row value.
    static let notSetUpValue = "Not set up"
    /// H1, under the list.
    static let notSetUpFootnote = "Cloud help isn’t set up in this version of Compass. Transcripts stay plain and there are no step ideas."
}
