import Foundation

// MARK: - Versions

/// Versions recorded in every ``RenderManifest``. Bump ``renderer`` for any change that can alter a rendered
/// sample; bump ``outputAssetFormat`` for any change to how rendered chunks or manifests are laid out.
public enum RenderVersions {
    /// Implementation version of ``GroupRenderer``.
    public static let renderer = 1
    /// Layout of ``RenderedChunk`` (planar binary32, output-channel order = request order) and of
    /// ``RenderManifest``.
    public static let outputAssetFormat = 1
}

// MARK: - Kernel

/// A Kaiser-windowed sinc low-pass interpolation kernel, defined relative to the LOWER of the input and
/// output Nyquist frequencies on the aligned timeline (so it band-limits for both up- and down-conversion).
///
/// All frequencies are fractions of the lower Nyquist. The ideal cutoff sits halfway between
/// `passbandEdge` and `stopbandEdge`; `halfWidth` is the one-sided support in lower-rate samples.
/// This is a CANDIDATE design: its parameters are calibrated, not qualified, until the frozen
/// `m2-freeze-render` holdout passes.
public struct KaiserSincKernelSpec: Sendable, Hashable, Codable {
    /// One-sided support, in samples at the lower rate (taps = 2 * halfWidth at ratio 1).
    public let halfWidth: Int
    /// End of the passband, as a fraction of the lower Nyquist.
    public let passbandEdge: Double
    /// Start of the stopband, as a fraction of the lower Nyquist.
    public let stopbandEdge: Double
    /// Kaiser window shape parameter.
    public let kaiserBeta: Double
    /// Prototype table resolution: entries per lower-rate sample (linear interpolation between them).
    public let tablePhasesPerSample: Int

    public init(halfWidth: Int, passbandEdge: Double, stopbandEdge: Double, kaiserBeta: Double, tablePhasesPerSample: Int) {
        self.halfWidth = halfWidth
        self.passbandEdge = passbandEdge
        self.stopbandEdge = stopbandEdge
        self.kaiserBeta = kaiserBeta
        self.tablePhasesPerSample = tablePhasesPerSample
    }

    /// Ideal cutoff in cycles per lower-rate sample: the midpoint of the transition band (as a fraction of
    /// the lower Nyquist) times 1/2.
    public var cutoffCyclesPerSample: Double { (passbandEdge + stopbandEdge) / 4 }
}

// MARK: - Recipe

/// How rounding is applied. There is exactly one policy; it is recorded so a later change is visible.
public enum RenderRoundingPolicy: String, Sendable, Hashable, Codable {
    /// The source position of every output frame is exact (rational). Its fractional part is converted to
    /// binary64 once per output frame per occurrence and shared by every channel of that occurrence; taps
    /// accumulate in binary64; output samples are binary32. Unit-ratio runs at an integer source phase are
    /// copied exactly.
    case exactPositionSharedBinary64Phase = "exact-position/shared-binary64-phase/binary32-output"
}

/// What happens where a channel has no supported source position (gap, unsupported epoch, outside
/// coverage) and to taps that fall outside the current span. Exactly one policy; recorded for audit.
public enum RenderPaddingPolicy: String, Sendable, Hashable, Codable {
    /// Explicit digital silence (0.0). Taps never read across a span (epoch) boundary.
    case explicitZero = "explicit-zero/no-cross-span-taps"
}

/// A versioned render recipe. It deliberately has NO gain, downmix, proxy or time-stretch parameter: the
/// only transform is the group's clock map (pitch 1/a), applied identically to every channel.
public struct RenderRecipe: Sendable, Hashable {
    public static let currentVersion = 1
    /// Output chunk bounds (frames). Chunking never changes rendered samples.
    public static let chunkFrameRange = 64 ... (1 << 16)
    /// The largest supported decimation (source frames per output frame). Larger decimation would need
    /// impractically long kernels and is refused, never approximated.
    public static let maximumDecimationLimit = 64

    public let version: Int
    public let kernel: KaiserSincKernelSpec
    public let outputChunkFrames: Int
    public let maximumDecimation: Int
    public let rounding: RenderRoundingPolicy
    public let padding: RenderPaddingPolicy

    /// The M2 calibration candidate (not qualified until the frozen holdout passes).
    public static let m2Candidate = try! RenderRecipe(
        kernel: KaiserSincKernelSpec(halfWidth: 32, passbandEdge: 0.8, stopbandEdge: 1.0, kaiserBeta: 9.6, tablePhasesPerSample: 2048),
        outputChunkFrames: 4096
    )

    public init(kernel: KaiserSincKernelSpec, outputChunkFrames: Int, maximumDecimation: Int = RenderRecipe.maximumDecimationLimit) throws(RenderFailure) {
        try self.init(version: Self.currentVersion, kernel: kernel, outputChunkFrames: outputChunkFrames, maximumDecimation: maximumDecimation, rounding: .exactPositionSharedBinary64Phase, padding: .explicitZero)
    }

    private init(version: Int, kernel: KaiserSincKernelSpec, outputChunkFrames: Int, maximumDecimation: Int, rounding: RenderRoundingPolicy, padding: RenderPaddingPolicy) throws(RenderFailure) {
        guard version == Self.currentVersion else { throw .invalidRecipe("unsupported recipe version \(version)") }
        guard (4 ... 256).contains(kernel.halfWidth) else { throw .invalidRecipe("halfWidth outside 4...256") }
        guard kernel.passbandEdge.isFinite, kernel.stopbandEdge.isFinite,
              kernel.passbandEdge > 0, kernel.passbandEdge < kernel.stopbandEdge, kernel.stopbandEdge <= 1
        else { throw .invalidRecipe("band edges must satisfy 0 < passband < stopband <= 1") }
        guard kernel.kaiserBeta.isFinite, kernel.kaiserBeta >= 0, kernel.kaiserBeta <= 40 else { throw .invalidRecipe("kaiserBeta outside 0...40") }
        guard (256 ... 65536).contains(kernel.tablePhasesPerSample) else { throw .invalidRecipe("tablePhasesPerSample outside 256...65536") }
        guard Self.chunkFrameRange.contains(outputChunkFrames) else { throw .invalidRecipe("outputChunkFrames outside \(Self.chunkFrameRange)") }
        guard (1 ... Self.maximumDecimationLimit).contains(maximumDecimation) else { throw .invalidRecipe("maximumDecimation outside 1...\(Self.maximumDecimationLimit)") }
        self.version = version
        self.kernel = kernel
        self.outputChunkFrames = outputChunkFrames
        self.maximumDecimation = maximumDecimation
        self.rounding = rounding
        self.padding = padding
    }
}

extension RenderRecipe: Codable {
    enum CodingKeys: String, CodingKey { case version, kernel, outputChunkFrames, maximumDecimation, rounding, padding }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: c.decode(Int.self, forKey: .version),
            kernel: c.decode(KaiserSincKernelSpec.self, forKey: .kernel),
            outputChunkFrames: c.decode(Int.self, forKey: .outputChunkFrames),
            maximumDecimation: c.decode(Int.self, forKey: .maximumDecimation),
            rounding: c.decode(RenderRoundingPolicy.self, forKey: .rounding),
            padding: c.decode(RenderPaddingPolicy.self, forKey: .padding)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(kernel, forKey: .kernel)
        try c.encode(outputChunkFrames, forKey: .outputChunkFrames)
        try c.encode(maximumDecimation, forKey: .maximumDecimation)
        try c.encode(rounding, forKey: .rounding)
        try c.encode(padding, forKey: .padding)
    }
}
