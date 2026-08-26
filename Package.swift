// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "hdhr_VCR",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "hdhr_VCR",
            dependencies: [],
            path: "Sources/hdhr_VCR",
            resources: [.copy("CHANGELOG.md"), .copy("PrivacyInfo.xcprivacy")]
        ),
        // Pure, testable TUI logic (string layout, DTOs, grid/scheduling math) split out of
        // hdhr_guide specifically so it's unit-testable — a `main.swift`-based executable target
        // can't be @testable imported, so none of this had any automated coverage before this
        // split (see docs/TUIGuide.md's "Robustness fixes"). hdhr_guide stays the thin executable
        // (terminal I/O, global mutable UI state, network calls); this holds everything that
        // doesn't need either.
        .target(
            name: "hdhr_guide_core",
            dependencies: [],
            path: "Sources/hdhr_guide_core"
        ),
        .executableTarget(
            name: "hdhr_guide",
            dependencies: ["hdhr_guide_core"],
            path: "Sources/hdhr_guide"
        ),
        .testTarget(
            name: "hdhr_VCRTests",
            dependencies: ["hdhr_VCR"],
            path: "Tests/hdhr_VCRTests",
            exclude: ["Views/__Snapshots__"]   // reference PNGs — accessed by filesystem path, not bundled
        ),
        .testTarget(
            name: "hdhr_guide_coreTests",
            dependencies: ["hdhr_guide_core"],
            path: "Tests/hdhr_guide_coreTests"
        )
    ]
)
