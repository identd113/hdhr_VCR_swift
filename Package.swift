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
        .testTarget(
            name: "hdhr_VCRTests",
            dependencies: ["hdhr_VCR"],
            path: "Tests/hdhr_VCRTests",
            exclude: ["__Snapshots__"]   // reference PNGs — accessed by filesystem path, not bundled
        )
    ]
)
