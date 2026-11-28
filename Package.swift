// swift-tools-version:5.9
import PackageDescription
import Foundation

// Command Line Tools ship the Swift Testing macros outside the default plugin path.
let cltTestingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testFlags: [SwiftSetting] = FileManager.default.fileExists(atPath: cltTestingPlugins)
    ? [.unsafeFlags(["-plugin-path", cltTestingPlugins])] : []

let package = Package(
    name: "Phosphor",
    platforms: [.macOS(.v14)],
    targets: [
        // Foundation-only logic (catalog, log scanning, pricing, alerts, status, export): unit-tested.
        .target(name: "PhosphorCore", path: "Sources/PhosphorCore"),
        .executableTarget(
            name: "Phosphor",
            dependencies: ["PhosphorCore"],
            path: "Sources/Phosphor"
        ),
        .testTarget(
            name: "PhosphorCoreTests",
            dependencies: ["PhosphorCore"],
            path: "Tests/PhosphorCoreTests",
            swiftSettings: testFlags
        ),
        .testTarget(
            name: "PhosphorTests",
            dependencies: ["Phosphor"],
            path: "Tests/PhosphorTests",
            swiftSettings: testFlags
        ),
    ]
)
