import Foundation
import CompassCore

/// Where the cloud model is. Nothing secret lives in the repo: the endpoint comes from the build
/// (`COMPASS_CLOUD_ASSIST_ENDPOINT` build setting → Info.plist `CompassCloudAssistEndpoint`, empty by
/// default) or, for development, a `CompassCloudAssistEndpoint` user default. With neither, the client
/// reports `.disabled` and the app shows plain transcripts and no step ideas (the on-device fallback).
enum CloudAssistEndpoint {
    static let infoKey = "CompassCloudAssistEndpoint"

    static var configuration: CloudAssistConfiguration {
        let override = UserDefaults.standard.string(forKey: infoKey)
        let built = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String
        let override_ = CloudAssistConfiguration(endpointString: override)
        return override_.endpoint != nil ? override_ : CloudAssistConfiguration(endpointString: built)
    }
}
