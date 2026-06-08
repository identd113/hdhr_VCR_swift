// swift-tools-version: 5.9
import PackageDescription

let devFw = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let devLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "hdhr_VCR",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "hdhr_VCR",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/hdhr_VCR",
            resources: [.copy("CHANGELOG.md"), .copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "hdhr_VCRTests",
            dependencies: ["hdhr_VCR"],
            path: "Tests/hdhr_VCRTests",
            exclude: ["__Snapshots__"],   // reference PNGs — accessed by filesystem path, not bundled
            swiftSettings: [
                .unsafeFlags(["-F", devFw])
            ],
            linkerSettings: [
                .unsafeFlags(["-F", devFw, "-framework", "Testing",
                              "-Xlinker", "-rpath", "-Xlinker", devFw,
                              "-Xlinker", "-rpath", "-Xlinker", devLib])
            ]
        )
    ]
)
