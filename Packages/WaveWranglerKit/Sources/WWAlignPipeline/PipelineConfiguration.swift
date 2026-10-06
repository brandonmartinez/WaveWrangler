import Foundation
import WWDecode

// WWAlignPipeline (WW-021 / WW-023 integration): the headless pipeline that turns explicitly requested,
// decoded sources into acoustic-consistent PROPOSALS (or abstentions), turns a person's decision into a
// versioned, accepted EpisodeAlignment map, and streams aligned per-channel derived assets for that map.
//
// Hard rules (docs/m2/ww-019-m2-contracts.md M2-C1..C7, .squad/decisions.md):
// * Content is read only through the WWDecode gateway (`SourceDecoder.withDecodingCursor`), only for a
//   source with an explicit `ContentWorkAuthorization` and availability ON. Every other path is
//   metadata-only and opens nothing.
// * The estimator only ever proposes. Acceptance is recorded as `manual(.acceptedAcousticProposal)` (or
//   numeric/anchor manual provenance). Nothing in this module constructs, accepts or carries forward a
//   `clockApproved` provenance.
// * Results publish only through `DerivedJobCoordinator`, whose commit-time currency check discards late
//   results; aligned assets live in the app-cache derived store only. Export stays blocked (M4).
// * Bounded: concurrency is a small configured cap (never `activeProcessorCount`), analysis memory is a
//   byte budget enforced by `ResourceGate`, and analysis buffers are streamed and decimated.
// * No work on the main thread: jobs run in the coordinator's detached utility tasks or in detached
//   pipeline tasks; decoding is `@concurrent`.

/// Tunable, recorded parameters. Every value that changes a result is part of the analysis recipe name,
/// so a change re-keys (and stales) earlier results instead of serving them.
public struct AlignmentPipelineConfiguration: Sendable, Equatable {
    /// Hard ceiling for concurrent pipeline work (user-directed compute budget, 2026-10-06).
    public static let maximumConcurrency = 4
    public static let defaultConcurrency = 2

    /// Concurrent analysis units / probes. Clamped to `1...maximumConcurrency`.
    public let concurrency: Int
    /// Upper bound on the estimated working set of all concurrently admitted analysis units, bytes.
    public let analysisMemoryBudgetBytes: Int
    /// Longest target excerpt analysed per epoch, seconds (centred in the target). The default (10 min)
    /// keeps one unit's estimated working set (~440 MB at a 120 s search) inside the default memory budget;
    /// a longer excerpt mostly buys estimator windows, not accuracy, for a constant-rate segment.
    public let targetExcerptSeconds: Int
    /// The estimator's search half-width around `searchCenterSeconds`, seconds (0, 600].
    public let searchDeviationSeconds: Int
    /// Predicted offset (reference group clock minus target group clock), seconds.
    public let searchCenterSeconds: Int
    /// Analysis buffers are decimated by an integer factor to the lowest exact rate at or above this.
    public let minimumAnalysisRate: Int
    /// Output seconds rendered per aligned-asset segment (one coordinator slot per channel per segment).
    public let renderSegmentSeconds: Int
    /// How the common output rate of aligned assets is chosen (WW-050 `OutputSettingsPolicy`): by default
    /// 48 kHz when feasible, else derived from the sources; `.matchSources` derives it from the sources.
    /// Cached aligned assets are float32 at that rate; `sampleFormat` applies when export lands (M4).
    public let outputSettings: OutputSettingsConfiguration

    public init(
        concurrency: Int = defaultConcurrency,
        analysisMemoryBudgetBytes: Int = 512 << 20,
        targetExcerptSeconds: Int = 600,
        searchDeviationSeconds: Int = 120,
        searchCenterSeconds: Int = 0,
        minimumAnalysisRate: Int = 8000,
        renderSegmentSeconds: Int = 10,
        outputSettings: OutputSettingsConfiguration = .default
    ) {
        self.concurrency = min(max(concurrency, 1), Self.maximumConcurrency)
        self.analysisMemoryBudgetBytes = max(analysisMemoryBudgetBytes, 16 << 20)
        self.targetExcerptSeconds = min(max(targetExcerptSeconds, 10), 3600)
        self.searchDeviationSeconds = min(max(searchDeviationSeconds, 1), 600)
        self.searchCenterSeconds = searchCenterSeconds
        self.minimumAnalysisRate = min(max(minimumAnalysisRate, 8000), 48_000)
        self.renderSegmentSeconds = min(max(renderSegmentSeconds, 1), 300)
        self.outputSettings = outputSettings
    }

    /// The analysis recipe: estimator identity plus every parameter that changes an analysis result.
    var analysisRecipeName: String {
        "ww.alignment-analysis[est=\(AlignmentAssetKinds.estimatorIdentifier);excerpt=\(targetExcerptSeconds);dev=\(searchDeviationSeconds);center=\(searchCenterSeconds);rate>=\(minimumAnalysisRate);dec=\(AnalysisDecimator.designVersion)]"
    }

    /// The render recipe name (output segmenting and the output-settings policy revision are part of the
    /// asset's identity; the chosen rate is added per segment).
    var renderRecipeName: String {
        "ww.aligned-render[recipe=\(AlignmentAssetKinds.renderRecipeVersion);renderer=\(AlignmentAssetKinds.rendererVersion);segment=\(renderSegmentSeconds);policy=\(OutputSettingsPolicy.version)]"
    }
}
