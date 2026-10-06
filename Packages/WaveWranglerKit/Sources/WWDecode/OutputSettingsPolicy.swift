import Foundation
import WWCore
import WWSources

/// WW-050 mixed-input output settings: one common output rate and sample format for every source of a
/// recorder group or episode, chosen from their `FormatInterpretation`s alone. Pure: it never touches
/// files, clocks or content, so the same inputs and configuration always give the same decision.
///
/// Rules (policy version 1):
/// 1. Inputs must be current interpretations (`FormatInterpretation.currentVersion`, `DecodeEnvelope.version`)
///    at envelope rates. A source listed twice must carry the same interpretation both times.
/// 2. Rate: the configured preferred rate (default 48 kHz) when it is feasible. A rate is feasible when it
///    is on the output grid (`supportedOutputRates`) and no source needs more than `maximumDecimation`
///    source frames per output frame. When the preferred rate is infeasible, or the user chooses
///    `.matchSources`, the rate is derived from the sources: the most common source rate that is feasible
///    (ties to the higher rate, which keeps more bandwidth). One always is: the highest source rate.
/// 3. Sample format: the configured format (default 24-bit integer PCM), never silently changed. Sources
///    with more precision than the output are named in a reason.
/// 4. Channels: every decoded source channel becomes its own output channel, in input order. There is no
///    downmix or upmix, so mixed channel counts need no conversion.
///
/// **Bump `version`** whenever a rule above, a default or the meaning of a reason changes. Every decision
/// records its `OutputSettingsBasis`; `OutputSettingsDecision.invalidations` names what makes it stale.
public enum OutputSettingsPolicy {
    public static let version = 1

    /// The output grid: the envelope's standard rates.
    public static let supportedOutputRates = DecodeEnvelope.standardSampleRates
    /// Mirrors WWRender's `RenderRecipe.maximumDecimationLimit` (WWDecode cannot import WWRender). The
    /// check here is nominal (clock ratio 1); the renderer re-checks the exact step with the clock map.
    public static let maximumDecimationLimit = 64

    public static func decide(
        _ interpretations: [FormatInterpretation],
        configuration: OutputSettingsConfiguration = .default
    ) throws(OutputSettingsFailure) -> OutputSettingsDecision {
        guard (1 ... maximumDecimationLimit).contains(configuration.maximumDecimation) else {
            throw .invalidConfiguration("maximumDecimation \(configuration.maximumDecimation) outside 1...\(maximumDecimationLimit)")
        }
        let inputs = try validatedInputs(interpretations)
        var reasons: [OutputSettingsReason] = []

        let sourceRates = inputs.map(\.sourceSampleRate)
        let rate: Int
        switch configuration.rateChoice {
        case .preferred:
            let preferred = configuration.preferredSampleRate
            if let rejection = infeasibility(of: preferred, inputs, configuration) {
                reasons.append(rejection)
                rate = try derivedRate(inputs, configuration, &reasons)
            } else {
                rate = preferred
                reasons.append(.preferredRateChosen(preferred))
            }
        case .matchSources:
            reasons.append(.userChoseSourceDerivedRate)
            rate = try derivedRate(inputs, configuration, &reasons)
        }

        let distinctRates = Array(Set(sourceRates)).sorted()
        if distinctRates.count > 1 { reasons.append(.mixedSourceRates(distinctRates)) }
        let resampled = inputs.filter { $0.sourceSampleRate != rate }.map(\.source)
        if !resampled.isEmpty { reasons.append(.sourcesResampled(resampled, outputRate: rate)) }

        let format = configuration.sampleFormat
        reasons.append(.sampleFormatConfigured(format))
        let distinctFormats = Array(Set(inputs.map(\.sampleFormat.description))).sorted()
        if distinctFormats.count > 1 { reasons.append(.mixedSourceSampleFormats(distinctFormats)) }
        let finer = inputs.filter { format.losesPrecision(of: $0.sampleFormat) }.map(\.source)
        if !finer.isEmpty { reasons.append(.sourcePrecisionExceedsOutput(finer, output: format)) }

        let counts = inputs.map(\.channelCount)
        if Set(counts).count > 1 { reasons.append(.mixedChannelCountsKeptPerSource(Array(Set(counts)).sorted())) }

        let settings = OutputSettings(
            sampleRate: rate,
            sampleFormat: format,
            channels: inputs.map { OutputSettings.SourceChannels(source: $0.source, channelCount: $0.channelCount) }
        )
        return OutputSettingsDecision(policyVersion: version, settings: settings, reasons: reasons, basis: basis(of: inputs, configuration: configuration))
    }

    /// The basis a decision would record for these inputs (after validation, de-duplicated, in input order).
    public static func basis(of interpretations: [FormatInterpretation], configuration: OutputSettingsConfiguration) -> OutputSettingsBasis {
        var seen = Set<SourceID>()
        let inputs = interpretations.filter { seen.insert($0.source).inserted }.map(OutputSettingsBasis.Input.init)
        return OutputSettingsBasis(policyVersion: version, configuration: configuration, inputs: inputs)
    }

    // MARK: Rules

    static func validatedInputs(_ interpretations: [FormatInterpretation]) throws(OutputSettingsFailure) -> [FormatInterpretation] {
        guard !interpretations.isEmpty else { throw .noInputs }
        var bySource: [SourceID: FormatInterpretation] = [:]
        var ordered: [FormatInterpretation] = []
        for interpretation in interpretations {
            guard interpretation.formatInterpretationVersion == FormatInterpretation.currentVersion,
                  interpretation.envelopeVersion == DecodeEnvelope.version
            else {
                throw .staleInterpretation(interpretation.source, formatInterpretationVersion: interpretation.formatInterpretationVersion, envelopeVersion: interpretation.envelopeVersion)
            }
            guard DecodeEnvelope.standardSampleRates.contains(interpretation.sourceSampleRate),
                  interpretation.output.sampleRate == interpretation.sourceSampleRate
            else { throw .rateOutsideEnvelope(interpretation.source, interpretation.sourceSampleRate) }
            guard interpretation.channelCount > 0, interpretation.output.channelCount == interpretation.channelCount else {
                throw .inconsistentChannelCount(interpretation.source, interpretation.channelCount)
            }
            if let existing = bySource[interpretation.source] {
                guard existing == interpretation else { throw .conflictingInterpretations(interpretation.source) }
                continue
            }
            bySource[interpretation.source] = interpretation
            ordered.append(interpretation)
        }
        return ordered
    }

    /// Why `rate` cannot be the common output rate, or nil when it can.
    static func infeasibility(of rate: Int, _ inputs: [FormatInterpretation], _ configuration: OutputSettingsConfiguration) -> OutputSettingsReason? {
        guard supportedOutputRates.contains(rate) else { return .rateNotOnOutputGrid(rate) }
        let tooFine = inputs.filter { Int64($0.sourceSampleRate) > Int64(configuration.maximumDecimation) * Int64(rate) }.map(\.source)
        guard tooFine.isEmpty else {
            return .rateExceedsMaximumDecimation(rate, sources: tooFine, maximumDecimation: configuration.maximumDecimation)
        }
        return nil
    }

    static func derivedRate(_ inputs: [FormatInterpretation], _ configuration: OutputSettingsConfiguration, _ reasons: inout [OutputSettingsReason]) throws(OutputSettingsFailure) -> Int {
        var counts: [Int: Int] = [:]
        for input in inputs { counts[input.sourceSampleRate, default: 0] += 1 }
        let candidates = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }.map(\.key)
        for candidate in candidates {
            if let rejection = infeasibility(of: candidate, inputs, configuration) {
                reasons.append(rejection)
                continue
            }
            reasons.append(.sourceDerivedRate(candidate, rule: .mostCommonFeasibleSourceRate))
            return candidate
        }
        // Unreachable for validated inputs: the highest source rate is a grid rate and needs no decimation.
        throw .noFeasibleRate
    }
}

// MARK: - Configuration

public enum OutputSampleFormat: String, Sendable, Codable, Hashable, CaseIterable {
    case pcmInt16, pcmInt24, pcmInt32, pcmFloat32

    public var bitsPerSample: Int {
        switch self {
        case .pcmInt16: 16
        case .pcmInt24: 24
        case .pcmInt32: 32
        case .pcmFloat32: 32
        }
    }

    public var isFloat: Bool { self == .pcmFloat32 }

    /// Whether this output cannot hold every value a source of `format` can carry. Decoding is float32, so
    /// float32 output loses only what decoding already loses (`isExactInFloat32 == false`).
    func losesPrecision(of format: SourceSampleFormat) -> Bool {
        if isFloat { return format.encoding != .lossy && !format.isExactInFloat32 }
        switch format.encoding {
        case .floatingPoint: return true
        case .signedInteger, .lossless: return (format.bitsPerSample ?? 0) > bitsPerSample
        case .lossy: return false
        }
    }
}

public struct OutputSettingsConfiguration: Sendable, Codable, Hashable {
    public enum RateChoice: String, Sendable, Codable, Hashable {
        /// Use `preferredSampleRate` when feasible, else derive one from the sources.
        case preferred
        /// The user chose a rate derived from the sources.
        case matchSources
    }

    public var preferredSampleRate: Int
    public var sampleFormat: OutputSampleFormat
    public var rateChoice: RateChoice
    public var maximumDecimation: Int

    public init(
        preferredSampleRate: Int = 48000,
        sampleFormat: OutputSampleFormat = .pcmInt24,
        rateChoice: RateChoice = .preferred,
        maximumDecimation: Int = OutputSettingsPolicy.maximumDecimationLimit
    ) {
        self.preferredSampleRate = preferredSampleRate
        self.sampleFormat = sampleFormat
        self.rateChoice = rateChoice
        self.maximumDecimation = maximumDecimation
    }

    /// 48 kHz, 24-bit integer PCM.
    public static let `default` = OutputSettingsConfiguration()
}

// MARK: - Decision

public struct OutputSettings: Sendable, Codable, Hashable {
    public struct SourceChannels: Sendable, Codable, Hashable {
        public var source: SourceID
        public var channelCount: Int
    }

    /// The one common rate every source is rendered at.
    public var sampleRate: Int
    public var sampleFormat: OutputSampleFormat
    /// One output channel per decoded source channel, in this order (no downmix or upmix).
    public var channels: [SourceChannels]

    public var outputChannelCount: Int { channels.reduce(0) { $0 + $1.channelCount } }
}

public enum SourceDerivedRateRule: String, Sendable, Codable, Hashable {
    case mostCommonFeasibleSourceRate
}

/// Why the policy chose what it did, in the order the rules applied.
public enum OutputSettingsReason: Sendable, Codable, Hashable {
    case preferredRateChosen(Int)
    case rateNotOnOutputGrid(Int)
    case rateExceedsMaximumDecimation(Int, sources: [SourceID], maximumDecimation: Int)
    case userChoseSourceDerivedRate
    case sourceDerivedRate(Int, rule: SourceDerivedRateRule)
    case mixedSourceRates([Int])
    case sourcesResampled([SourceID], outputRate: Int)
    case sampleFormatConfigured(OutputSampleFormat)
    case mixedSourceSampleFormats([String])
    case sourcePrecisionExceedsOutput([SourceID], output: OutputSampleFormat)
    case mixedChannelCountsKeptPerSource([Int])
}

/// Everything a decision depends on. Two equal bases always give the same decision.
public struct OutputSettingsBasis: Sendable, Codable, Hashable {
    public struct Input: Sendable, Codable, Hashable {
        public var source: SourceID
        public var formatInterpretationVersion: Int
        public var envelopeVersion: Int
        public var sourceFingerprint: FileSystemFingerprint
        public var sourceSampleRate: Int
        public var sampleFormat: SourceSampleFormat
        public var channelCount: Int

        public init(_ interpretation: FormatInterpretation) {
            source = interpretation.source
            formatInterpretationVersion = interpretation.formatInterpretationVersion
            envelopeVersion = interpretation.envelopeVersion
            sourceFingerprint = interpretation.sourceFingerprint
            sourceSampleRate = interpretation.sourceSampleRate
            sampleFormat = interpretation.sampleFormat
            channelCount = interpretation.channelCount
        }
    }

    public var policyVersion: Int
    public var configuration: OutputSettingsConfiguration
    /// De-duplicated, in input (channel) order.
    public var inputs: [Input]
}

/// What makes a recorded decision stale. A decision is current only when there are none.
public enum OutputSettingsInvalidation: Sendable, Codable, Hashable {
    case policyVersionChanged(recorded: Int, current: Int)
    case configurationChanged
    case inputAdded(SourceID)
    case inputDropped(SourceID)
    /// A version, the fingerprint, the rate, the sample format or the channel count changed.
    case inputChanged(SourceID)
    case inputOrderChanged
    /// The source is listed more than once with unequal interpretations, which `decide` refuses.
    case conflictingInputs(SourceID)
}

public struct OutputSettingsDecision: Sendable, Codable, Hashable {
    public var policyVersion: Int
    public var settings: OutputSettings
    public var reasons: [OutputSettingsReason]
    public var basis: OutputSettingsBasis

    /// Every reason this decision no longer applies to `interpretations` under `configuration`.
    public func invalidations(
        for interpretations: [FormatInterpretation],
        configuration: OutputSettingsConfiguration,
        policyVersion current: Int = OutputSettingsPolicy.version
    ) -> [OutputSettingsInvalidation] {
        var found: [OutputSettingsInvalidation] = []
        if basis.policyVersion != current { found.append(.policyVersionChanged(recorded: basis.policyVersion, current: current)) }
        if basis.configuration != configuration { found.append(.configurationChanged) }
        let now = OutputSettingsPolicy.basis(of: interpretations, configuration: configuration).inputs
        let recorded = Dictionary(basis.inputs.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        let currentInputs = Dictionary(now.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        for input in now {
            guard let old = recorded[input.source] else {
                found.append(.inputAdded(input.source))
                continue
            }
            if old != input { found.append(.inputChanged(input.source)) }
        }
        for input in basis.inputs where currentInputs[input.source] == nil { found.append(.inputDropped(input.source)) }
        let kept = now.map(\.source).filter { recorded[$0] != nil }
        let recordedKept = basis.inputs.map(\.source).filter { currentInputs[$0] != nil }
        if kept != recordedKept { found.append(.inputOrderChanged) }
        // Same equality as validatedInputs: a repeat must equal the first listing in full.
        var firstListing: [SourceID: FormatInterpretation] = [:]
        var conflicting: [SourceID] = []
        for interpretation in interpretations {
            guard let first = firstListing[interpretation.source] else {
                firstListing[interpretation.source] = interpretation
                continue
            }
            if first != interpretation, !conflicting.contains(interpretation.source) { conflicting.append(interpretation.source) }
        }
        found += conflicting.map(OutputSettingsInvalidation.conflictingInputs)
        return found
    }

    public func isCurrent(for interpretations: [FormatInterpretation], configuration: OutputSettingsConfiguration) -> Bool {
        invalidations(for: interpretations, configuration: configuration).isEmpty
    }
}

public enum OutputSettingsFailure: Error, Sendable, Hashable {
    case noInputs
    case staleInterpretation(SourceID, formatInterpretationVersion: Int, envelopeVersion: Int)
    case rateOutsideEnvelope(SourceID, Int)
    case inconsistentChannelCount(SourceID, Int)
    case conflictingInterpretations(SourceID)
    case invalidConfiguration(String)
    /// No source rate is feasible. Unreachable for validated inputs (the highest source rate always is); explicit, never a guess.
    case noFeasibleRate
}
