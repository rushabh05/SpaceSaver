// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SpaceSaver",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SpaceSaverApp", targets: ["SpaceSaverApp"]),
        .executable(name: "spacesaver", targets: ["spacesaver"]),
        .library(name: "SpaceSaverCore", targets: ["SpaceSaverCore"]),
    ],
    targets: [
        .target(
            name: "SpaceSaverCore",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
        ),
        .executableTarget(name: "SpaceSaverApp", dependencies: ["SpaceSaverCore"]),
        .executableTarget(name: "spacesaver", dependencies: ["SpaceSaverCore"]),
        .testTarget(name: "SpaceSaverCoreTests", dependencies: ["SpaceSaverCore"]),
    ]
)
