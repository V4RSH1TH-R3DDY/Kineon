// swift-tools-version: 6.4
// Shared code for the TremorTrack+ iPhone and watch apps: contract models, API client, window buffering.
// Pure Foundation, so `swift test` runs on macOS without Xcode.
import PackageDescription

let package = Package(
    name: "TremorKit",
    platforms: [.iOS("26.0"), .watchOS("26.0"), .macOS("14.0")],
    products: [.library(name: "TremorKit", targets: ["TremorKit"])],
    targets: [
        .target(name: "TremorKit"),
        .testTarget(name: "TremorKitTests", dependencies: ["TremorKit"]),
    ]
)
