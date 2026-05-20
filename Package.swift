// swift-tools-version: 5.9
import PackageDescription

let devFw = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let devLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "hdhr_VCR",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "hdhr_VCR",
            path: "Sources/hdhr_VCR"
        ),
        .testTarget(
            name: "hdhr_VCRTests",
            dependencies: ["hdhr_VCR"],
            path: "Tests/hdhr_VCRTests",
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
