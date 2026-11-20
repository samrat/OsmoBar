// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OsmoBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "OsmoCore", targets: ["OsmoCore"]),
        .executable(name: "OsmoBar", targets: ["OsmoBar"])
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
            name: "OsmoBar",
            dependencies: ["OsmoCore"],
            path: "Sources/OsmoBar",
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
