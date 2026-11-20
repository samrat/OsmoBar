// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OsmoControl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OsmoCore", targets: ["OsmoCore"]),
        .executable(name: "OsmoControl", targets: ["OsmoControl"])
    ],
    targets: [
        .target(
            name: "OsmoCore",
            path: "Sources/OsmoCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Network")
            ]
        ),
        .executableTarget(
            name: "OsmoControl",
            dependencies: ["OsmoCore"],
            path: "Sources/OsmoControl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOKit"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "OsmoCoreTests",
            dependencies: ["OsmoCore"],
            path: "Tests/OsmoCoreTests"
        )
    ]
)
