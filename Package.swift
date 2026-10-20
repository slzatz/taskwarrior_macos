// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TaskwarriorApp",
    // A version string: tools 5.9 names nothing past .v14, and tools 6 would switch the
    // package to the Swift 6 language mode.
    platforms: [.macOS("15.0")],
    targets: [
        // Everything that does not touch AppKit/SwiftUI lives here so it can be
        // unit-tested and reused by a future table-based (checkbox) view.
        .target(
            name: "TaskwarriorCore",
            path: "Sources/TaskwarriorCore"
        ),
        .executableTarget(
            name: "TaskwarriorApp",
            dependencies: ["TaskwarriorCore"],
            path: "Sources/TaskwarriorApp"
        ),
        .testTarget(
            name: "TaskwarriorCoreTests",
            dependencies: ["TaskwarriorCore"],
            path: "Tests/TaskwarriorCoreTests"
        ),
    ]
)
