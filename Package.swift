// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RewriteDB",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Pinned to 1.15.0: later versions use the SwiftUI `#Preview` macro, whose macro
        // plugin ships only with full Xcode — `swift build` under Command Line Tools can't
        // expand it. 1.15.0 is the newest release without `#Preview` and has the full API we use.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.15.0")
    ],
    targets: [
        // Pure, dependency-free logic (models + API parsing). Unit-tested by RewriteDBTests.
        .target(
            name: "RewriteDBKit",
            path: "Sources/RewriteDBKit"
        ),
        // The menu-bar app (UI, permissions, hotkeys). Depends on the kit.
        .executableTarget(
            name: "RewriteDB",
            dependencies: ["KeyboardShortcuts", "RewriteDBKit"],
            path: "Sources/RewriteDB"
        ),
        // Dependency-free test runner: `swift run RewriteDBTests`. Works under the Command
        // Line Tools (XCTest / swift-testing aren't fully available without full Xcode).
        .executableTarget(
            name: "RewriteDBTests",
            dependencies: ["RewriteDBKit"],
            path: "Sources/RewriteDBTests"
        )
    ]
)
