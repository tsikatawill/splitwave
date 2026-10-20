// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Splitwave",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "splitwave", targets: ["splitwave"]),
        .executable(name: "SplitwaveApp", targets: ["SplitwaveApp"]),
        .library(name: "SplitwaveCore", targets: ["SplitwaveCore"]),
    ],
    targets: [
        .target(
            name: "SplitwaveCore",
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "splitwave",
            dependencies: ["SplitwaveCore"],
            linkerSettings: [
                // Embeds an Info.plist so the bare binary carries NSAudioCaptureUsageDescription.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "Resources/CLI-Info.plist"]),
            ]
        ),
        .executableTarget(
            name: "SplitwaveApp",
            dependencies: ["SplitwaveCore"]
        ),
        .testTarget(
            name: "SplitwaveCoreTests",
            dependencies: ["SplitwaveCore"]
        ),
    ]
)
