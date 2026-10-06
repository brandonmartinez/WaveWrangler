import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

/// WW-050 mixed-input output-settings policy. Interpretations come from `DecodeEnvelope.interpret` over
/// declared stream facts (no files), so every input is one the envelope really produces.
@Suite("Output settings policy")
struct OutputSettingsPolicyTests {
    static let opened = OpenedFileState(fileNumber: 7, sizeBytes: 1 << 20, modificationSeconds: 1_700_000_000, modificationNanoseconds: 0)

    static func fingerprint(_ size: Int64 = 1 << 20) -> FileSystemFingerprint {
        FileSystemFingerprint(fileSize: .known(size), contentModificationDate: .known(Date(timeIntervalSince1970: 1_700_000_000)), fileIdentifier: .known(7))
    }

    enum Kind { case int(Int), float(Int), alac(Int), aac, opus }

    static func input(_ rate: Int, _ kind: Kind = .int(24), channels: Int = 2, source: SourceID = SourceID(), size: Int64 = 1 << 20) throws -> FormatInterpretation {
        let c = UInt32(channels)
        let facts: EncodedStreamFacts
        switch kind {
        case .int(let bits), .float(let bits):
            let isFloat = if case .float = kind { true } else { false }
            let bytes = UInt32(bits / 8) * c
            facts = EncodedStreamFacts(
                containerTypeCode: FourCharacterCode.code("caff"), formatID: FourCharacterCode.code("lpcm"),
                formatFlags: isFloat ? 0b1 : 0b100, sampleRate: Double(rate), bytesPerPacket: bytes, framesPerPacket: 1,
                bytesPerFrame: bytes, channelsPerFrame: c, bitsPerChannel: UInt32(bits), readerLengthFrames: 1000,
                containerLength: .consistent(declaredBytes: 1000 * Int64(bytes)), openedFile: opened
            )
        case .alac(let bits):
            facts = EncodedStreamFacts(
                containerTypeCode: FourCharacterCode.code("m4af"), formatID: FourCharacterCode.code("alac"),
                formatFlags: UInt32([16: 1, 20: 2, 24: 3, 32: 4][bits]!), sampleRate: Double(rate), bytesPerPacket: 0, framesPerPacket: 4096,
                bytesPerFrame: 0, channelsPerFrame: c, bitsPerChannel: 0, readerLengthFrames: 1000, openedFile: opened
            )
        case .aac, .opus:
            let isAAC = if case .aac = kind { true } else { false }
            facts = EncodedStreamFacts(
                containerTypeCode: FourCharacterCode.code(isAAC ? "m4af" : "caff"), formatID: FourCharacterCode.code(isAAC ? "aac " : "opus"),
                formatFlags: 0, sampleRate: Double(rate), bytesPerPacket: 0, framesPerPacket: isAAC ? 1024 : 960,
                bytesPerFrame: 0, channelsPerFrame: c, bitsPerChannel: 0,
                packetTable: PacketTableFacts(validFrames: 1000, primingFrames: isAAC ? 2112 : 312, remainderFrames: 0),
                readerLengthFrames: 1000, openedFile: opened
            )
        }
        let url = URL(fileURLWithPath: "/nonexistent/x.\(kind.ext)")
        return try Result { () throws(DecodeFailure) in try DecodeEnvelope.interpret(facts, url: url, source: source, fingerprint: fingerprint(size)) }.get()
    }

    static func decide(_ inputs: [FormatInterpretation], _ configuration: OutputSettingsConfiguration = .default) -> Result<OutputSettingsDecision, OutputSettingsFailure> {
        Result { () throws(OutputSettingsFailure) in try OutputSettingsPolicy.decide(inputs, configuration: configuration) }
    }

    // MARK: Rate

    @Test func defaultIs48kHz24BitPCM() {
        let configuration = OutputSettingsConfiguration.default
        #expect(configuration.preferredSampleRate == 48000 && configuration.sampleFormat == .pcmInt24 && configuration.rateChoice == .preferred)
        #expect(configuration.maximumDecimation == OutputSettingsPolicy.maximumDecimationLimit && OutputSettingsPolicy.version == 1)
        #expect(OutputSettingsPolicy.supportedOutputRates == DecodeEnvelope.standardSampleRates)
    }

    @Test func mixedRatesDepthsAndChannelsShareOne48kHzRate() throws {
        let a = try Self.input(44100, .int(16), channels: 1)
        let b = try Self.input(48000, .float(32), channels: 2)
        let c = try Self.input(96000, .alac(24), channels: 6)
        let d = try Self.input(22050, .aac, channels: 8)
        let e = try Self.input(16000, .opus, channels: 1)
        let decision = try Self.decide([a, b, c, d, e]).get()
        #expect(decision.policyVersion == OutputSettingsPolicy.version)
        #expect(decision.settings.sampleRate == 48000 && decision.settings.sampleFormat == .pcmInt24)
        #expect(decision.settings.channels.map(\.source) == [a, b, c, d, e].map(\.source))
        #expect(decision.settings.channels.map(\.channelCount) == [1, 2, 6, 8, 1] && decision.settings.outputChannelCount == 18)
        #expect(decision.reasons == [
            .preferredRateChosen(48000),
            .mixedSourceRates([16000, 22050, 44100, 48000, 96000]),
            .sourcesResampled([a, c, d, e].map(\.source), outputRate: 48000),
            .sampleFormatConfigured(.pcmInt24),
            .mixedSourceSampleFormats(["floatingPoint32 LE", "lossless24", "lossy", "signedInteger16 LE"]),
            .sourcePrecisionExceedsOutput([b.source], output: .pcmInt24),
            .mixedChannelCountsKeptPerSource([1, 2, 6, 8]),
        ])
    }

    @Test(arguments: DecodeEnvelope.standardSampleRates)
    func everyEnvelopeRateAloneGets48kHz(rate: Int) throws {
        let decision = try Self.decide([try Self.input(rate)]).get()
        #expect(decision.settings.sampleRate == 48000)
        #expect(decision.reasons.contains(.sourcesResampled([decision.settings.channels[0].source], outputRate: 48000)) == (rate != 48000))
    }

    @Test func userChoiceDerivesTheMostCommonSourceRateTiesToTheHigher() throws {
        let matching = OutputSettingsConfiguration(rateChoice: .matchSources)
        let inputs = [try Self.input(44100), try Self.input(44100), try Self.input(96000), try Self.input(48000)]
        let decision = try Self.decide(inputs, matching).get()
        #expect(decision.settings.sampleRate == 44100)
        #expect(Array(decision.reasons.prefix(2)) == [.userChoseSourceDerivedRate, .sourceDerivedRate(44100, rule: .mostCommonFeasibleSourceRate)])
        let tie = [try Self.input(44100), try Self.input(96000)]
        #expect(try Self.decide(tie, matching).get().settings.sampleRate == 96000)
        #expect(try Self.decide(tie.reversed(), matching).get().settings.sampleRate == 96000, "order-independent rate")
    }

    @Test func preferredRateOffTheOutputGridFallsBackToTheSources() throws {
        let inputs = [try Self.input(44100), try Self.input(48000), try Self.input(44100)]
        let decision = try Self.decide(inputs, OutputSettingsConfiguration(preferredSampleRate: 50000)).get()
        #expect(decision.settings.sampleRate == 44100)
        #expect(Array(decision.reasons.prefix(2)) == [.rateNotOnOutputGrid(50000), .sourceDerivedRate(44100, rule: .mostCommonFeasibleSourceRate)])
    }

    @Test func preferredRateBeyondTheDecimationLimitFallsBackAndNamesTheSources() throws {
        let fine = try Self.input(192_000)
        let inputs = [try Self.input(8000), try Self.input(8000), fine]
        // 192 kHz / 8 kHz = 24 > 16: 8 kHz is infeasible both as the preferred rate and as the commonest source rate.
        let configuration = OutputSettingsConfiguration(preferredSampleRate: 8000, maximumDecimation: 16)
        let decision = try Self.decide(inputs, configuration).get()
        #expect(decision.settings.sampleRate == 192_000)
        #expect(Array(decision.reasons.prefix(3)) == [
            .rateExceedsMaximumDecimation(8000, sources: [fine.source], maximumDecimation: 16),
            .rateExceedsMaximumDecimation(8000, sources: [fine.source], maximumDecimation: 16),
            .sourceDerivedRate(192_000, rule: .mostCommonFeasibleSourceRate),
        ])
        // 192 kHz / 16 kHz = 12: feasible at a limit of 12, not at 11.
        let limit = try Self.decide([fine], OutputSettingsConfiguration(preferredSampleRate: 16000, maximumDecimation: 12)).get()
        #expect(limit.settings.sampleRate == 16000)
        let over = try Self.decide([fine], OutputSettingsConfiguration(preferredSampleRate: 16000, maximumDecimation: 11)).get()
        #expect(over.settings.sampleRate == 192_000)
    }

    @Test func sourceDerivedFallbackSkipsInfeasibleSourceRates() throws {
        let fine = try Self.input(32000)
        let inputs = [fine, try Self.input(8000), try Self.input(8000)]
        let decision = try Self.decide(inputs, OutputSettingsConfiguration(preferredSampleRate: 50000, maximumDecimation: 2)).get()
        #expect(decision.settings.sampleRate == 32000)
        #expect(Array(decision.reasons.prefix(3)) == [
            .rateNotOnOutputGrid(50000),
            .rateExceedsMaximumDecimation(8000, sources: [fine.source], maximumDecimation: 2),
            .sourceDerivedRate(32000, rule: .mostCommonFeasibleSourceRate),
        ])
    }

    /// Seeded property check over random mixed groups and configurations: a decision always exists, its
    /// rate is feasible for every source, it is the preferred rate exactly when that is feasible and
    /// chosen, and a derived rate is the most common feasible source rate (ties to the higher).
    @Test func seededMixedGroupsAlwaysGetOneFeasibleRate() throws {
        var rng = SplitMix64(state: 0x5757_3035_304F_5350) // "WW050OSP"
        func pick<T>(_ values: [T]) -> T { values[Int(rng.next() % UInt64(values.count))] }
        let kinds: [Kind] = [.int(16), .int(24), .int(32), .float(32), .float(64), .alac(16), .alac(20), .alac(24), .alac(32), .aac, .opus]
        var preferredCount = 0, derivedCount = 0, rejections = 0
        for _ in 0..<500 {
            var inputs: [FormatInterpretation] = []
            for _ in 0..<(1 + Int(rng.next() % 6)) {
                let kind = pick(kinds)
                let rates: [Int] = switch kind {
                case .aac: DecodeEnvelope.aacSampleRates
                case .opus: DecodeEnvelope.opusSampleRates
                default: DecodeEnvelope.standardSampleRates
                }
                let channels: [Int] = switch kind {
                case .int, .float: Array(1...8)
                case .opus: [1, 2]
                default: [1, 2, 6, 8]
                }
                inputs.append(try Self.input(pick(rates), kind, channels: pick(channels)))
            }
            let configuration = OutputSettingsConfiguration(
                preferredSampleRate: pick(DecodeEnvelope.standardSampleRates + [48000, 48000, 50000]),
                sampleFormat: pick(OutputSampleFormat.allCases),
                rateChoice: pick([.preferred, .preferred, .matchSources]),
                maximumDecimation: pick([1, 2, 4, 64])
            )
            let decision = try Self.decide(inputs, configuration).get()
            let rate = decision.settings.sampleRate
            #expect(OutputSettingsPolicy.infeasibility(of: rate, inputs, configuration) == nil)
            #expect(decision.settings.sampleFormat == configuration.sampleFormat)
            #expect(decision.settings.outputChannelCount == inputs.reduce(0) { $0 + $1.channelCount })
            let preferredFeasible = OutputSettingsPolicy.infeasibility(of: configuration.preferredSampleRate, inputs, configuration) == nil
            if configuration.rateChoice == .preferred, preferredFeasible {
                #expect(rate == configuration.preferredSampleRate && decision.reasons.first == .preferredRateChosen(rate))
                preferredCount += 1
            } else {
                var counts: [Int: Int] = [:]
                for input in inputs { counts[input.sourceSampleRate, default: 0] += 1 }
                let best = counts.filter { OutputSettingsPolicy.infeasibility(of: $0.key, inputs, configuration) == nil }
                    .max { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }!.key
                #expect(rate == best && decision.reasons.contains(.sourceDerivedRate(best, rule: .mostCommonFeasibleSourceRate)))
                derivedCount += 1
            }
            rejections += decision.reasons.filter { if case .rateExceedsMaximumDecimation = $0 { true } else { false } }.count
        }
        #expect(preferredCount > 100 && derivedCount > 100 && rejections > 20, "generator coverage: \(preferredCount)/\(derivedCount)/\(rejections)")
    }

    // MARK: Sample format

    @Test func precisionReasonsFollowTheConfiguredFormat() throws {
        let i16 = try Self.input(48000, .int(16)), i24 = try Self.input(48000, .int(24)), i32 = try Self.input(48000, .int(32))
        let f32 = try Self.input(48000, .float(32)), f64 = try Self.input(48000, .float(64))
        let a20 = try Self.input(48000, .alac(20)), a32 = try Self.input(48000, .alac(32)), aac = try Self.input(48000, .aac)
        let all = [i16, i24, i32, f32, f64, a20, a32, aac]
        let expected: [OutputSampleFormat: [FormatInterpretation]] = [
            .pcmInt16: [i24, i32, f32, f64, a20, a32],
            .pcmInt24: [i32, f32, f64, a32],
            .pcmInt32: [f32, f64],
            .pcmFloat32: [i32, f64, a32],
        ]
        for format in OutputSampleFormat.allCases {
            let decision = try Self.decide(all, OutputSettingsConfiguration(sampleFormat: format)).get()
            #expect(decision.settings.sampleFormat == format, "the configured format is never changed")
            let named = decision.reasons.compactMap { reason -> [SourceID]? in
                if case .sourcePrecisionExceedsOutput(let sources, format) = reason { return sources }
                return nil
            }
            #expect(named == [expected[format]!.map(\.source)], "\(format)")
        }
        let uniform = try Self.decide([i16, try Self.input(48000, .int(16))]).get()
        #expect(!uniform.reasons.contains { if case .mixedSourceSampleFormats = $0 { true } else { false } })
        #expect(!uniform.reasons.contains { if case .sourcePrecisionExceedsOutput = $0 { true } else { false } })
    }

    // MARK: Validation

    @Test func refusesInvalidInputsExplicitly() throws {
        #expect(Self.decide([]) == .failure(.noInputs))
        var stale = try Self.input(48000)
        stale.formatInterpretationVersion = FormatInterpretation.currentVersion + 1
        #expect(Self.decide([stale]) == .failure(.staleInterpretation(stale.source, formatInterpretationVersion: stale.formatInterpretationVersion, envelopeVersion: DecodeEnvelope.version)))
        var oldEnvelope = try Self.input(48000)
        oldEnvelope.envelopeVersion = DecodeEnvelope.version - 1
        #expect(Self.decide([oldEnvelope]) == .failure(.staleInterpretation(oldEnvelope.source, formatInterpretationVersion: FormatInterpretation.currentVersion, envelopeVersion: oldEnvelope.envelopeVersion)))
        var offRate = try Self.input(48000)
        offRate.sourceSampleRate = 47999
        #expect(Self.decide([offRate]) == .failure(.rateOutsideEnvelope(offRate.source, 47999)))
        var mismatchedOutput = try Self.input(48000)
        mismatchedOutput.output.sampleRate = 44100
        #expect(Self.decide([mismatchedOutput]) == .failure(.rateOutsideEnvelope(mismatchedOutput.source, 48000)))
        var channels = try Self.input(48000)
        channels.output.channelCount = 1
        #expect(Self.decide([channels]) == .failure(.inconsistentChannelCount(channels.source, 2)))
        let source = SourceID()
        let first = try Self.input(48000, source: source), second = try Self.input(44100, source: source)
        #expect(Self.decide([first, second]) == .failure(.conflictingInterpretations(source)))
        for bound in [0, OutputSettingsPolicy.maximumDecimationLimit + 1] {
            guard case .failure(.invalidConfiguration) = Self.decide([first], OutputSettingsConfiguration(maximumDecimation: bound)) else {
                Issue.record("maximumDecimation \(bound) accepted")
                continue
            }
        }
    }

    @Test func aSourceListedTwiceWithTheSameInterpretationCountsOnce() throws {
        let a = try Self.input(44100), b = try Self.input(48000)
        let decision = try Self.decide([a, b, a]).get()
        #expect(decision.settings.channels.map(\.source) == [a.source, b.source])
        #expect(decision.basis.inputs.map(\.source) == [a.source, b.source])
    }

    @Test func decisionsAreDeterministicAndCodable() throws {
        let inputs = [try Self.input(44100, .int(16), channels: 1), try Self.input(96000, .float(64), channels: 8), try Self.input(24000, .opus)]
        let first = try Self.decide(inputs).get()
        #expect(try Self.decide(inputs).get() == first)
        let encoded = try JSONEncoder().encode(first)
        #expect(try JSONDecoder().decode(OutputSettingsDecision.self, from: encoded) == first)
    }

    // MARK: Invalidation

    @Test func invalidationIsExplicitForEveryInputAndPolicyChange() throws {
        let a = try Self.input(44100), b = try Self.input(48000, .int(16)), c = try Self.input(96000)
        let decision = try Self.decide([a, b]).get()
        #expect(decision.isCurrent(for: [a, b], configuration: .default))
        #expect(decision.invalidations(for: [a, b], configuration: .default).isEmpty)
        #expect(decision.invalidations(for: [a, b, a], configuration: .default).isEmpty, "a repeated source is the same input")

        #expect(decision.invalidations(for: [a, b], configuration: .default, policyVersion: 2) == [.policyVersionChanged(recorded: 1, current: 2)])
        #expect(decision.invalidations(for: [a, b], configuration: OutputSettingsConfiguration(sampleFormat: .pcmFloat32)) == [.configurationChanged])
        #expect(decision.invalidations(for: [a, b], configuration: OutputSettingsConfiguration(rateChoice: .matchSources)) == [.configurationChanged])
        #expect(decision.invalidations(for: [a, b, c], configuration: .default) == [.inputAdded(c.source)])
        #expect(decision.invalidations(for: [a], configuration: .default) == [.inputDropped(b.source)])
        #expect(decision.invalidations(for: [b, a], configuration: .default) == [.inputOrderChanged])

        var changes: [(String, FormatInterpretation)] = []
        var v = b; v.formatInterpretationVersion += 1; changes.append(("interpretation version", v))
        v = b; v.envelopeVersion += 1; changes.append(("envelope version", v))
        v = b; v.sourceFingerprint = Self.fingerprint(12345); changes.append(("fingerprint", v))
        v = b; v.sourceSampleRate = 96000; changes.append(("rate", v))
        v = b; v.sampleFormat = .int(24, bigEndian: false); changes.append(("sample format", v))
        v = b; v.channelCount = 1; changes.append(("channel count", v))
        for (label, changed) in changes {
            #expect(decision.invalidations(for: [a, changed], configuration: .default) == [.inputChanged(b.source)], "\(label)")
            #expect(!decision.isCurrent(for: [a, changed], configuration: .default), "\(label)")
        }
        // Fields the decision does not depend on (priming, layout) do not invalidate it.
        v = b; v.frames.primingFrames += 1; v.channelLayout = .undeclared
        #expect(decision.isCurrent(for: [a, v], configuration: .default))
    }

    /// A source listed twice with unequal interpretations is refused by `decide`, so it is never current.
    @Test func conflictingRepeatsAreNeverCurrent() throws {
        let a = try Self.input(44100), b = try Self.input(48000, .int(16))
        let decision = try Self.decide([a, b]).get()
        var rate = b; rate.sourceSampleRate = 96000; rate.output.sampleRate = 96000
        var priming = b; priming.frames.primingFrames += 1
        var otherPriming = a; otherPriming.frames.primingFrames += 2
        let cases: [(String, [FormatInterpretation], [OutputSettingsInvalidation])] = [
            ("decision-relevant field", [a, b, rate], [.conflictingInputs(b.source)]),
            ("field the decision ignores", [a, b, priming], [.conflictingInputs(b.source)]),
            ("first listing differs", [a, priming, b], [.conflictingInputs(b.source)]),
            ("two sources, reported once each", [a, b, otherPriming, priming, otherPriming], [.conflictingInputs(a.source), .conflictingInputs(b.source)]),
        ]
        for (label, inputs, expected) in cases {
            #expect(decision.invalidations(for: inputs, configuration: .default) == expected, "\(label)")
            #expect(!decision.isCurrent(for: inputs, configuration: .default), "\(label)")
            guard case .failure(.conflictingInterpretations) = Self.decide(inputs) else {
                Issue.record("\(label): decide accepted conflicting inputs")
                continue
            }
        }
    }
}

private extension OutputSettingsPolicyTests.Kind {
    var ext: String {
        switch self {
        case .int, .float: "caf"
        case .alac, .aac: "m4a"
        case .opus: "caf"
        }
    }
}
