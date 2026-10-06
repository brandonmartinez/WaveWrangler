import Foundation
import WWCore
import WWTimeMap

// WWAlignEstimate (WW-016 / WW-021 part 1): a pure offset/drift PROPOSAL estimator with abstention.
//
// Hard rules (docs/m2/ww-019-m2-contracts.md M2-C4, .squad/decisions.md 2026-10-06):
// * Input is decoded sample buffers (plain `Float` arrays + rate) supplied by the caller. This module never
//   opens, reads, hashes or decodes a file and has no file/URL/network API (WWAlignEstimateTests scans it).
// * Output is a per-epoch PROPOSAL (`acousticConsistentProposal`) or an ABSTENTION. There is no case that
//   carries a clock approval, and nothing here can construct one: audio correlation measures where sound
//   arrived, not when the recorder's clock ticked. A constant or slowly varying acoustic propagation delay
//   is indistinguishable from a clock offset/drift in this evidence, so the estimator never approves a
//   clock. The M2 drift fallback stays manual epochs/anchors.
// * Scores are evidence measures (correlation coefficients, margins, fractions), never probabilities.
// * Synchronous and CPU-bound: callers must run it off the main thread.

public enum AlignEstimateError: Error, Equatable, Sendable {
    case invalidSampleRate(Int)
    case emptyBuffer
    case nonFiniteSample(index: Int)
    case invalidParameter(String)
    case duplicateEpoch(RecordingEpochID)
    case referenceEpochInTracks(RecordingEpochID)
    case invalidDeclaredOverlap(SourceOccurrenceID)
    /// The proposal could not be expressed as an exact WWTimeMap segment (e.g. outside the map envelope).
    case timeMap(TimeMapError)
}

/// Decoded mono samples at an integer nominal rate. The caller decodes; this module never reads content.
public struct SampleBuffer: Sendable {
    public let samples: [Float]
    public let sampleRate: Int

    /// - Throws: for rates below 8 kHz (the proxy needs at least 2x oversampling), above the map envelope,
    ///   empty buffers, or non-finite samples.
    public init(samples: [Float], sampleRate: Int) throws(AlignEstimateError) {
        guard sampleRate >= 8000, Int64(sampleRate) <= TimeMapEnvelope.maxNominalRate else { throw .invalidSampleRate(sampleRate) }
        guard !samples.isEmpty else { throw .emptyBuffer }
        if let index = samples.firstIndex(where: { !$0.isFinite }) { throw .nonFiniteSample(index: index) }
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var durationSeconds: Double { Double(samples.count) / Double(sampleRate) }
}

/// One occurrence's samples within ONE clock epoch of a recorder group. A group with several epochs
/// (declared restarts) supplies one track per epoch; epochs are estimated independently and never bridged.
public struct EstimatorTrack: Sendable {
    public let group: RecorderGroupID
    public let epoch: RecordingEpochID
    public let occurrence: SourceOccurrenceID
    /// Group-clock instant of sample 0 (the occurrence span's `groupClockOffset`), seconds.
    public let groupClockStart: ExactRational
    public let buffer: SampleBuffer
    /// Frames of this buffer the caller declares to overlap the reference (half-open). `nil` = all frames.
    /// Coverage fractions are measured against this range, and a proposal's segment spans exactly it.
    public let declaredOverlap: Range<Int>?

    public init(group: RecorderGroupID, epoch: RecordingEpochID, occurrence: SourceOccurrenceID, groupClockStart: ExactRational = .zero, buffer: SampleBuffer, declaredOverlap: Range<Int>? = nil) {
        self.group = group
        self.epoch = epoch
        self.occurrence = occurrence
        self.groupClockStart = groupClockStart
        self.buffer = buffer
        self.declaredOverlap = declaredOverlap
    }

    var overlapFrames: Range<Int> { declaredOverlap ?? 0..<buffer.samples.count }
}

/// Where to look for the offset (aligned time minus group-clock time), seconds. A capture-metadata seed may
/// set the centre; it remains a search hint and is carried into the proposal only as a seed.
public struct SearchRange: Sendable, Equatable {
    public let centerOffsetSeconds: Double
    public let maximumDeviationSeconds: Double
    public let seed: CaptureMetadataSeed?

    public init(centerOffsetSeconds: Double = 0, maximumDeviationSeconds: Double, seed: CaptureMetadataSeed? = nil) throws(AlignEstimateError) {
        guard centerOffsetSeconds.isFinite else { throw .invalidParameter("centerOffsetSeconds") }
        guard maximumDeviationSeconds.isFinite, maximumDeviationSeconds > 0, maximumDeviationSeconds <= 600 else { throw .invalidParameter("maximumDeviationSeconds") }
        self.centerOffsetSeconds = centerOffsetSeconds
        self.maximumDeviationSeconds = maximumDeviationSeconds
        self.seed = seed
    }
}

/// The timeline reference track (aligned time == its group clock) and the tracks to estimate against it.
public struct EstimationRequest: Sendable {
    public let reference: EstimatorTrack
    public let tracks: [EstimatorTrack]
    public let search: SearchRange

    public init(reference: EstimatorTrack, tracks: [EstimatorTrack], search: SearchRange) {
        self.reference = reference
        self.tracks = tracks
        self.search = search
    }
}

/// Estimator parameters. The defaults are the values frozen by `m2-freeze-estimator`
/// (docs/m2/fixtures/m2-freeze-estimator.json); a change is a new estimator version and needs a new freeze.
public struct EstimatorParameters: Sendable, Equatable {
    /// Common analysis (proxy) rate every track is resampled to, Hz.
    public var proxyRate: Double = 4000
    /// Proxy low-pass cutoff as a fraction of the proxy rate.
    public var proxyCutoffFraction: Double = 0.45
    public var windowSeconds: Double = 2
    /// Windows placed evenly across each track's declared overlap.
    public var windowCount: Int = 16
    /// Minimum normalised-correlation peak for an eligible window.
    public var minimumPeakScore: Double = 0.35
    /// A window is ambiguous when its second correlation peak reaches this fraction of the first.
    public var ambiguityRatio: Double = 0.8
    /// A window is periodic when its self-similarity at a non-trivial shift reaches this value.
    public var periodicityThreshold: Double = 0.5
    /// Peaks/shifts closer than this to the main peak (or to zero shift) are the same lobe, milliseconds.
    public var lobeExclusionMilliseconds: Double = 5
    /// Proxy-band RMS below which a window (target or reference region) is silent.
    public var silenceRMS: Double = 1e-4
    /// Every eligible window must lie within this distance of one affine line, milliseconds.
    public var consistencyToleranceMilliseconds: Double = 1
    /// Fitted drift beyond this magnitude is refused as implausible, ppm.
    public var maximumAbsolutePPM: Double = 500
    /// Cycle (triangle) disagreement above this abstains every epoch in the cycle, milliseconds.
    public var cycleToleranceMilliseconds: Double = 2

    public init() {}

    func validate() throws(AlignEstimateError) {
        func check(_ ok: Bool, _ name: String) throws(AlignEstimateError) { if !ok { throw .invalidParameter(name) } }
        try check(proxyRate.isFinite && proxyRate >= 1000 && proxyRate <= 16000, "proxyRate")
        try check(proxyCutoffFraction > 0.1 && proxyCutoffFraction < 0.5, "proxyCutoffFraction")
        try check(windowSeconds.isFinite && windowSeconds >= 0.25 && windowSeconds <= 30, "windowSeconds")
        try check(windowCount >= ProvisionalClockGates.minimumWindows && windowCount <= 256, "windowCount")
        try check(minimumPeakScore > 0 && minimumPeakScore < 1, "minimumPeakScore")
        try check(ambiguityRatio > 0 && ambiguityRatio < 1, "ambiguityRatio")
        try check(periodicityThreshold > 0 && periodicityThreshold < 1, "periodicityThreshold")
        try check(lobeExclusionMilliseconds > 0 && lobeExclusionMilliseconds < windowSeconds * 250, "lobeExclusionMilliseconds")
        try check(silenceRMS.isFinite && silenceRMS > 0, "silenceRMS")
        try check(consistencyToleranceMilliseconds > 0 && consistencyToleranceMilliseconds <= ProvisionalClockGates.maximumResidualP95Milliseconds, "consistencyToleranceMilliseconds")
        try check(maximumAbsolutePPM > 0 && maximumAbsolutePPM < 100_000, "maximumAbsolutePPM")
        try check(cycleToleranceMilliseconds > 0 && cycleToleranceMilliseconds.isFinite, "cycleToleranceMilliseconds")
    }
}
