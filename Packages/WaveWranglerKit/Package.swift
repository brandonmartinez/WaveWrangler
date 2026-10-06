// swift-tools-version: 6.2
// Tools version 6.2 keeps the package buildable by the GitHub-hosted macos-26 Xcode 26.x toolchains as
// well as local Xcode 27. Do not raise it without checking the CI runner image.

import PackageDescription

let package = Package(
    name: "WaveWranglerKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "WWCore", targets: ["WWCore"]),
        .library(name: "WWPersistence", targets: ["WWPersistence"]),
        .library(name: "WWSources", targets: ["WWSources"]),
        .library(name: "WWEpisodeSetup", targets: ["WWEpisodeSetup"]),
        .library(name: "WWOrganizer", targets: ["WWOrganizer"]),
        // Pure exact clock-epoch / coordinate maps (WW-015). No I/O, no decoding.
        .library(name: "WWTimeMap", targets: ["WWTimeMap"]),
        // Headless persistence probe for multi-process and observed-provider trials (synthetic documents only).
        .executable(name: "wwpersist-probe", targets: ["WWPersistenceProbe"]),
    ],
    targets: [
        .target(name: "WWCore"),
        .target(name: "WWPersistence", dependencies: ["WWCore"]),
        .target(name: "WWSources", dependencies: ["WWCore"]),
        .target(name: "WWEpisodeSetup", dependencies: ["WWCore", "WWSources"]),
        .target(name: "WWOrganizer", dependencies: ["WWCore"]),
        .target(name: "WWTimeMap", dependencies: ["WWCore"]),
        .executableTarget(name: "WWPersistenceProbe", dependencies: ["WWPersistence", "WWCore", "WWSources"]),
        .testTarget(name: "WWCoreTests", dependencies: ["WWCore"]),
        .testTarget(name: "WWPersistenceTests", dependencies: ["WWPersistence", "WWCore", "WWPersistenceProbe", "WWOrganizer"]),
        .testTarget(name: "WWSourcesTests", dependencies: ["WWSources", "WWCore"]),
        .testTarget(name: "WWEpisodeSetupTests", dependencies: ["WWEpisodeSetup", "WWCore", "WWSources"]),
        .testTarget(name: "WWOrganizerTests", dependencies: ["WWOrganizer", "WWCore", "WWPersistence"]),
        .testTarget(name: "WWTimeMapTests", dependencies: ["WWTimeMap", "WWCore"]),
    ],
    swiftLanguageModes: [.v6]
)
