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
        .library(name: "WWDecode", targets: ["WWDecode"]),
        // Versioned-map API, consent-gated content digest and the cancellable derived-asset/job layer (WW-020).
        .library(name: "WWDerived", targets: ["WWDerived"]),
        // Pure acoustic offset/drift PROPOSAL estimator with abstention (WW-016). Consumes decoded sample
        // buffers; no I/O, no decoding, never approves a clock.
        .library(name: "WWAlignEstimate", targets: ["WWAlignEstimate"]),
        // Pure channel-consistent clock-correction renderer (WW-018/WW-023). Consumes decoded buffers through a
        // caller-owned provider; never opens files.
        .library(name: "WWRender", targets: ["WWRender"]),
        // Headless persistence probe for multi-process and observed-provider trials (synthetic documents only).
        .executable(name: "wwpersist-probe", targets: ["WWPersistenceProbe"]),
    ],
    targets: [
        .target(name: "WWCore"),
        .target(name: "WWPersistence", dependencies: ["WWCore", "WWTimeMap"]),
        .target(name: "WWSources", dependencies: ["WWCore"]),
        .target(name: "WWEpisodeSetup", dependencies: ["WWCore", "WWSources"]),
        .target(name: "WWOrganizer", dependencies: ["WWCore"]),
        .target(name: "WWTimeMap", dependencies: ["WWCore"]),
        .target(name: "WWDecode", dependencies: ["WWCore", "WWSources"]),
        .target(name: "WWDerived", dependencies: ["WWCore", "WWTimeMap", "WWSources", "WWDecode", "WWPersistence"]),
        .target(name: "WWAlignEstimate", dependencies: ["WWCore", "WWTimeMap"]),
        .target(name: "WWRender", dependencies: ["WWCore", "WWTimeMap"]),
        .executableTarget(name: "WWPersistenceProbe", dependencies: ["WWPersistence", "WWCore", "WWSources"]),
        .testTarget(name: "WWCoreTests", dependencies: ["WWCore"]),
        .testTarget(name: "WWPersistenceTests", dependencies: ["WWPersistence", "WWCore", "WWPersistenceProbe", "WWOrganizer", "WWTimeMap"]),
        .testTarget(name: "WWSourcesTests", dependencies: ["WWSources", "WWCore"]),
        .testTarget(name: "WWEpisodeSetupTests", dependencies: ["WWEpisodeSetup", "WWCore", "WWSources"]),
        .testTarget(name: "WWOrganizerTests", dependencies: ["WWOrganizer", "WWCore", "WWPersistence"]),
        .testTarget(name: "WWTimeMapTests", dependencies: ["WWTimeMap", "WWCore"]),
        .testTarget(name: "WWDecodeTests", dependencies: ["WWDecode", "WWSources", "WWCore"]),
        .testTarget(name: "WWDerivedTests", dependencies: ["WWDerived", "WWDecode", "WWSources", "WWTimeMap", "WWPersistence", "WWCore"]),
        .testTarget(name: "WWAlignEstimateTests", dependencies: ["WWAlignEstimate", "WWTimeMap", "WWCore"]),
        .testTarget(name: "WWRenderTests", dependencies: ["WWRender", "WWTimeMap", "WWCore"]),
        // Headless validation on a user-approved local episode copy. Skipped unless WW_LOCAL_EPISODE_DIR is
        // set at run time (never on CI); see docs/m2/evidence/m2-local-episode-validation.md.
        .testTarget(name: "WWLocalEpisodeValidationTests", dependencies: ["WWDecode", "WWSources", "WWAlignEstimate", "WWRender", "WWTimeMap", "WWCore"]),
    ],
    swiftLanguageModes: [.v6]
)
