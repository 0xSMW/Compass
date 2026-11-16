// swift-tools-version:6.0
// CompassCore: pure-Swift domain core. Builds and tests on Linux (`swift test`)
// and is linked by the Compass app, the widget and the UI tests.
import PackageDescription

let package = Package(
    name: "CompassCore",
    // macOS 15 for `Synchronization.Mutex` (iOS 18 already has it); the package is only built for iOS and Linux.
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CompassCore", targets: ["CompassCore"]),
    ],
    targets: [
        .target(name: "CompassCore"),
        .testTarget(name: "CompassCoreTests", dependencies: ["CompassCore"]),
    ]
)
