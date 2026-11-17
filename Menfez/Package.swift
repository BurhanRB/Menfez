// swift-tools-version:5.9
import PackageDescription

// Three targets, one shared core:
//
//   MenfezCore   all platform logic: state, routes, WireGuard, DNS, probes.
//                No UI, no argument parsing, fully unit-testable.
//   Menfez       the SwiftUI app. Links MenfezCore for JSON models only and
//                shells out to the helper for privileged work.
//   menfez-route the privileged helper (setuid-free; run through sudo). Same
//                core, thin CLI on top.
//
// DEVELOPER_DIR must point at Xcode when building: the SwiftUI macro plugin
// only ships inside Xcode's macOS platform, not in the Command Line Tools.
let package = Package(
    name: "Menfez",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Menfez", targets: ["Menfez"]),
        .executable(name: "menfez-route", targets: ["menfez-route"]),
        .library(name: "MenfezCore", targets: ["MenfezCore"]),
    ],
    targets: [
        .target(
            name: "MenfezCore",
            path: "Sources/MenfezCore"
        ),
        .executableTarget(
            name: "Menfez",
            dependencies: ["MenfezCore"],
            path: "Sources/Menfez",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .executableTarget(
            name: "menfez-route",
            dependencies: ["MenfezCore"],
            path: "Sources/menfez-route"
        ),
        .testTarget(
            name: "MenfezCoreTests",
            dependencies: ["MenfezCore"],
            path: "Tests/MenfezCoreTests"
        ),
    ]
)
