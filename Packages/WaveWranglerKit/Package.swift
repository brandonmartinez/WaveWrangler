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
        // Pure discontinuity detector/segmenter (WW-017) between the frozen WW-016 estimator and WWTimeMap:
        // splits an occurrence into epochs or leaves regions unsupported; never bridges a jump, never approves.
        .library(name: "WWAlignSegment", targets: ["WWAlignSegment"]),
        // WW-021/WW-023 integration: headless analysis -> proposal -> accepted map -> aligned derived assets.
        .library(name: "WWAlignPipeline", targets: ["WWAlignPipeline"]),
        // Pure M3 proposal and protected-cut admission policy; mapping is supplied by an Alignment adapter.
        .library(name: "WWCutPolicy", targets: ["WWCutPolicy"]),
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
        .target(name: "WWAlignSegment", dependencies: ["WWCore", "WWTimeMap", "WWAlignEstimate"]),
        .target(name: "WWAlignPipeline", dependencies: ["WWCore", "WWTimeMap", "WWSources", "WWDecode", "WWDerived", "WWPersistence", "WWAlignEstimate", "WWRender"]),
        .target(name: "WWCutPolicy"),
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
        .testTarget(name: "WWAlignSegmentTests", dependencies: ["WWAlignSegment", "WWAlignEstimate", "WWTimeMap", "WWCore"]),
        .testTarget(name: "WWAlignPipelineTests", dependencies: ["WWAlignPipeline", "WWDerived", "WWDecode", "WWSources", "WWTimeMap", "WWPersistence", "WWAlignEstimate", "WWRender", "WWCore"]),
        .testTarget(name: "WWCutPolicyTests", dependencies: ["WWCutPolicy"]),
        // Headless validation on a user-approved local episode copy. Skipped unless WW_LOCAL_EPISODE_DIR is
        // set at run time (never on CI); see docs/m2/evidence/m2-local-episode-validation.md.
        .testTarget(name: "WWLocalEpisodeValidationTests", dependencies: ["WWDecode", "WWSources", "WWAlignEstimate", "WWRender", "WWTimeMap", "WWCore", "WWDerived", "WWPersistence", "WWAlignPipeline"]),
    ],
    swiftLanguageModes: [.v6]
)
