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
        // Prebuilt whisper.cpp XCFramework (local speech-to-text). Consumed as a binary target
        // because the CLT-only toolchain can't compile whisper.cpp's Metal shaders from source,
        // and the source Swift packages predate the large-v3-turbo model. The release build
        // embeds a precompiled .metallib (GGML_METAL_EMBED_LIBRARY=ON), so `swift build` never
        // invokes `metal`, yet it's still GPU-accelerated at runtime. imports as `import whisper`.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip",
            checksum: "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
        ),
        // The menu-bar app (UI, permissions, hotkeys). Depends on the kit.
        .executableTarget(
            name: "RewriteDB",
            dependencies: ["KeyboardShortcuts", "RewriteDBKit", "whisper"],
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
