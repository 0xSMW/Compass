// swift-tools-version:6.0
// CompassCore: pure-Swift domain core. Builds and tests on Linux (`swift test`)
// and is linked by the Compass app, the widget and the UI tests.
import PackageDescription

let package = Package(
    name: "CompassCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CompassCore", targets: ["CompassCore"]),
    ],
    targets: [
        .target(name: "CompassCore"),
        .testTarget(name: "CompassCoreTests", dependencies: ["CompassCore"]),
    ]
)
