import AudioToolbox
import CryptoKit
import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

// M3-DECODE-003: WW-050 decode truth cases (m3-freeze-decode-3, docs/m2/fixtures/m3-freeze-decode-3.json).
//
// Recipe: 13 strata, stratum = case index mod 13. Nine supported strata write a seeded LandmarkSignal in an
// envelope format (priming per lossy codec and container, lossless and PCM bit depth / channel metadata,
// packet-boundary lengths for the decoded-frame origin, variable-rate codecs at seeded chunk sizes). Four
// planted strata make truncated, corrupt, unsupported and changed-while-decoding sources. Truth is the
// generator: the written samples, frame count, format, channel count and landmark positions, never the
// decoder's own report. Every file is synthetic and lives under $TMPDIR.
//
// Gates are `DecodeGates`, unchanged from both M2 revisions. The revision-3 holdout split runs only
// with WW_M3_DECODE_3_HOLDOUT=1, after this freeze merges, and has NOT been run.

/// The frozen decode gates (m3-freeze-decode-3; DecodeFreezeTests fails on drift).
enum DecodeGates {
    /// "100% of supported truth cases mapped correctly": supported cases with any mapping failure.
    static let maximumSupportedMappingFailures = 0
    /// "landmarks ≤1 output frame": |decoded landmark − truth landmark|, output frames.
    static let landmarkOutputFrames = 1
    /// "every planted bad case is an explicit error": planted cases without their expected typed error.
    static let maximumPlantedWithoutExpectedError = 0
    /// "with no mutation (FileSnapshot equality)": planted cases whose source changed.
    static let maximumPlantedMutations = 0
    /// "and no stale publication": planted cases that finished a sink, left appended output unabandoned,
    /// left a reader open or unbalanced a security scope.
    static let maximumPlantedPublications = 0
    /// A landmark counts as found only above this normalised correlation (otherwise it fails the
    /// landmark gate). Exact formats must also be bit-exact with lag 0.
    static let lossyMinimumCorrelation = 0.5
    static let exactMinimumCorrelation = 0.999
}

enum DecodeFixture {
    static let fixtureID = "M3-DECODE-003"
    static let calibrationCases = 130
    static let holdoutCases = 520
    static let holdoutEnabled = ProcessInfo.processInfo.environment["WW_M3_DECODE_3_HOLDOUT"] == "1"
    /// The calibration split writes and decodes 130 files, so it runs in its own serialized pass
    /// (scripts/test.sh) instead of the parallel package run.
    static let calibrationEnabled = ProcessInfo.processInfo.environment["WW_DECODE_CALIBRATION"] == "1"
    static let recordsDirectory = ProcessInfo.processInfo.environment["WW_DECODE_RECORDS_DIR"]
    /// Compute budget: a split measures at most this many cases at once (never the core count).
    /// `WW_M2_FREEZE_MAX_CONCURRENCY` may lower it; values outside 1...4 are clamped. Records are written in
    /// caseIndex order, so the limit never changes a record.
    static let defaultMaxConcurrency = 4
    static let maxConcurrency = concurrencyLimit(from: ProcessInfo.processInfo.environment["WW_M2_FREEZE_MAX_CONCURRENCY"])

    static func concurrencyLimit(from value: String?) -> Int {
        guard let value, let requested = Int(value) else { return defaultMaxConcurrency }
        return min(max(requested, 1), defaultMaxConcurrency)
    }

    static func seed(split: String, index: Int) -> UInt64 {
        seed(fixtureID: fixtureID, split: split, index: index)
    }

    static func seed(fixtureID: String, split: String, index: Int) -> UInt64 {
        let digest = SHA256.hash(data: Data("ww-m2-fixture|v1|\(fixtureID)|\(split)|\(index)".utf8))
        return digest.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    static func recordsFileName(split: String) -> String {
        "\(split)-3.jsonl"
    }

    static let minimumFrames = 9000
    static let maximumFrames = 40_000
    static let maximumChunkFrames = 65_536
}

enum DecodeStratum: Int, CaseIterable, Sendable {
    case primingAACM4A, primingAACCAF, primingOpusCAF, losslessALAC, losslessFLAC, pcmInteger, pcmFloat
    case originPacketBoundary, variableRate
    case plantedTruncated, plantedCorrupt, plantedUnsupported, plantedStale

    var name: String {
        switch self {
        case .primingAACM4A: "priming-aac-m4a"
        case .primingAACCAF: "priming-aac-caf"
        case .primingOpusCAF: "priming-opus-caf"
        case .losslessALAC: "lossless-alac"
        case .losslessFLAC: "lossless-flac"
        case .pcmInteger: "pcm-integer"
        case .pcmFloat: "pcm-float"
        case .originPacketBoundary: "origin-packet-boundary"
        case .variableRate: "variable-rate"
        case .plantedTruncated: "planted-truncated"
        case .plantedCorrupt: "planted-corrupt"
        case .plantedUnsupported: "planted-unsupported"
        case .plantedStale: "planted-stale"
        }
    }

    var isPlanted: Bool { rawValue >= DecodeStratum.plantedTruncated.rawValue }
}

/// Seeded draws for one case, in the order `DecodeFreezeCase.init` makes them.
struct DecodeCaseRNG {
    var base: SplitMix64
    init(seed: UInt64) { base = SplitMix64(state: seed) }
    mutating func below(_ n: Int) -> Int { Int(base.next() % UInt64(n)) }
    mutating func inRange(_ range: ClosedRange<Int>) -> Int { range.lowerBound + below(range.count) }
    mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
    /// Uniform in [0, 1).
    mutating func fraction() -> Double { Double(base.next() >> 11) / Double(UInt64(1) << 53) }
    /// Log-uniform integer in `range`.
    mutating func logUniform(_ range: ClosedRange<Int>) -> Int {
        let low = log(Double(range.lowerBound)), high = log(Double(range.upperBound) + 1)
        return min(range.upperBound, max(range.lowerBound, Int(exp(low + (high - low) * fraction()))))
    }
}

/// What a planted case does to its source, and the typed error it must produce.
enum DecodePlant: Sendable {
    case truncate(fraction: Double)
    case damagedHeader
    case randomBytes(count: Int, fileExtension: String)
    case text(repeats: Int, fileExtension: String)
    case empty(fileExtension: String)
    case streamingWaveSize
    case outsideEnvelope(name: String, expected: UnsupportedReason)
    case changedWhileDecoding(StaleChange)

    var description: String {
        switch self {
        case let .truncate(fraction): "truncated to \(String(format: "%.4f", fraction))"
        case .damagedHeader: "damaged header"
        case let .randomBytes(count, ext): "\(count) random bytes .\(ext)"
        case let .text(repeats, ext): "text x\(repeats) .\(ext)"
        case let .empty(ext): "empty .\(ext)"
        case .streamingWaveSize: "streaming WAVE data size"
        case let .outsideEnvelope(name, _): name
        case let .changedWhileDecoding(change): "changed while decoding: \(change)"
        }
    }

    var expected: ExpectedDecodeFailure {
        switch self {
        case .truncate: .contentDamage
        case .damagedHeader, .randomBytes, .text: .unreadableContainer
        case .empty: .exactly(.emptyFile)
        case .streamingWaveSize: .exactly(.unsupported(.unverifiableContainerLength))
        case let .outsideEnvelope(_, reason): .exactly(.unsupported(reason))
        case .changedWhileDecoding: .exactly(.sourceChangedDuringDecode)
        }
    }
}

enum StaleChange: String, CaseIterable, Sendable {
    case sizeGrew, identifierChanged, modificationDateChanged, sizeUnknown, vanished

    func apply(_ result: inout MetadataResult) {
        switch self {
        case .sizeGrew: result.modify { $0.fingerprint.fileSize = .known(($0.fingerprint.fileSize.value ?? 0) + 1) }
        case .identifierChanged: result.modify { $0.fingerprint.fileIdentifier = .known(($0.fingerprint.fileIdentifier.value ?? 0) + 1) }
        case .modificationDateChanged: result.modify { $0.fingerprint.contentModificationDate = .known(Date(timeIntervalSince1970: 0)) }
        case .sizeUnknown: result.modify { $0.fingerprint.fileSize = .unknown }
        case .vanished: result = .failure(.notFound)
        }
    }
}

enum ExpectedDecodeFailure: Sendable, CustomStringConvertible {
    /// `DecodeFailure.isContentDamage`.
    case contentDamage
    /// `.unreadableContainer` with any platform status.
    case unreadableContainer
    case exactly(DecodeFailure)

    func matches(_ failure: DecodeFailure?) -> Bool {
        guard let failure else { return false }
        switch self {
        case .contentDamage: return failure.isContentDamage
        case .unreadableContainer:
            if case .unreadableContainer = failure { return true }
            return false
        case let .exactly(expected): return failure == expected
        }
    }

    /// Refused before any sink is made: nothing may be appended at all.
    var refusedBeforeSink: Bool {
        switch self {
        case .contentDamage: false
        case .unreadableContainer: true
        case let .exactly(failure): failure != .sourceChangedDuringDecode
        }
    }

    var description: String {
        switch self {
        case .contentDamage: "content damage"
        case .unreadableContainer: "unreadableContainer"
        case let .exactly(failure): "\(failure)"
        }
    }
}

/// One generated case. Every draw comes from `DecodeCaseRNG(seed:)` in the order written here.
struct DecodeFreezeCase: Sendable {
    let split: String
    let index: Int
    let seed: UInt64
    let stratum: DecodeStratum
    let spec: FixtureSpec
    let frames: Int
    let chunkFrames: Int
    let plant: DecodePlant?
    /// Frames per packet the stratum assumes (origin-packet-boundary only); checked against the source.
    let assumedFramesPerPacket: Int?

    init(split: String, index: Int) {
        self.split = split
        self.index = index
        seed = DecodeFixture.seed(split: split, index: index)
        stratum = DecodeStratum(rawValue: index % DecodeStratum.allCases.count)!
        var rng = DecodeCaseRNG(seed: seed)
        var frames = rng.inRange(DecodeFixture.minimumFrames ... DecodeFixture.maximumFrames)
        let chunkFrames = rng.logUniform(1 ... DecodeFixture.maximumChunkFrames)
        var plant: DecodePlant?
        var assumed: Int?
        let spec: FixtureSpec
        switch stratum {
        case .primingAACM4A: spec = Self.anyEnvelopeSpec(&rng) { $0.container == .m4a && $0.codec == .aac }
        case .primingAACCAF: spec = Self.anyEnvelopeSpec(&rng) { $0.container == .caf && $0.codec == .aac }
        case .primingOpusCAF: spec = Self.anyEnvelopeSpec(&rng) { $0.codec == .opus }
        case .losslessALAC: spec = Self.anyEnvelopeSpec(&rng) { $0.codec == .appleLossless }
        case .losslessFLAC: spec = Self.anyEnvelopeSpec(&rng) { $0.codec == .flac }
        case .pcmInteger: spec = Self.envelopeSpec(&rng, entry: { $0.codec == .linearPCM }, format: { $0.encoding == .signedInteger })
        case .pcmFloat: spec = Self.envelopeSpec(&rng, entry: { $0.codec == .linearPCM }, format: { $0.encoding == .floatingPoint })
        case .originPacketBoundary:
            spec = Self.anyEnvelopeSpec(&rng) { [.aac, .opus, .appleLossless].contains($0.codec) }
            let packet = Self.framesPerPacket(spec)
            let k = rng.inRange((DecodeFixture.minimumFrames + packet - 1) / packet ... DecodeFixture.maximumFrames / packet - 1)
            let delta = rng.pick([-1, 0, 1, 0, rng.inRange(2 ... packet - 2)])
            frames = k * packet + delta
            assumed = packet
        case .variableRate:
            spec = Self.anyEnvelopeSpec(&rng) { $0.codec != .linearPCM }
        case .plantedTruncated:
            spec = Self.anyEnvelopeSpec(&rng) { _ in true }
            plant = .truncate(fraction: 0.02 + 0.95 * rng.fraction())
        case .plantedCorrupt:
            (spec, plant) = Self.corrupt(&rng, variant: index / DecodeStratum.allCases.count)
        case .plantedUnsupported:
            (spec, plant) = Self.unsupported(&rng, variant: index / DecodeStratum.allCases.count)
        case .plantedStale:
            spec = Self.anyEnvelopeSpec(&rng) { _ in true }
            plant = .changedWhileDecoding(StaleChange.allCases[(index / DecodeStratum.allCases.count) % StaleChange.allCases.count])
        }
        self.spec = spec
        self.frames = frames
        self.chunkFrames = chunkFrames
        self.plant = plant
        assumedFramesPerPacket = assumed
    }

    var signal: LandmarkSignal { LandmarkSignal(frames: frames, channelCount: spec.channelCount, seed: seed) }

    var label: String {
        "\(split)#\(index) \(stratum.name) \(spec.testDescription) \(frames) fr chunk \(chunkFrames)" + (plant.map { " [\($0.description)]" } ?? "")
    }

    static func envelopeSpec(
        _ rng: inout DecodeCaseRNG,
        entry: (DecodeEnvelope.Entry) -> Bool,
        format: (SourceSampleFormat) -> Bool = { _ in true }
    ) -> FixtureSpec {
        let entries = DecodeEnvelope.entries.filter { entry($0) && $0.sampleFormats.contains(where: format) }
        let chosen = rng.pick(entries)
        return FixtureSpec(
            container: chosen.container, codec: chosen.codec,
            sampleFormat: rng.pick(chosen.sampleFormats.filter(format)),
            sampleRate: rng.pick(chosen.sampleRates), channelCount: rng.pick(chosen.channelCounts)
        )
    }

    static func anyEnvelopeSpec(_ rng: inout DecodeCaseRNG, _ entry: (DecodeEnvelope.Entry) -> Bool) -> FixtureSpec {
        envelopeSpec(&rng, entry: entry)
    }

    /// Codec packet size the origin stratum builds lengths around: AAC 1024, ALAC 4096, Opus 20 ms.
    static func framesPerPacket(_ spec: FixtureSpec) -> Int {
        switch spec.codec {
        case .aac: 1024
        case .appleLossless: 4096
        case .opus: spec.sampleRate / 50
        default: 1
        }
    }

    static let corruptExtensions = ["wav", "m4a", "caf", "aiff", "flac", "mp3", "bin"]

    /// Planted variants rotate with the case's position in its stratum, so every split covers each one;
    /// the variant's parameters are seeded.
    static let corruptVariants = 5
    static let unsupportedVariants = 8

    static func corrupt(_ rng: inout DecodeCaseRNG, variant: Int) -> (FixtureSpec, DecodePlant) {
        let pcm16 = { (rng: inout DecodeCaseRNG) -> FixtureSpec in
            let container = rng.pick([ContainerKind.wave, .aiff, .caf])
            return FixtureSpec(
                container: container, codec: .linearPCM, sampleFormat: .int(16, bigEndian: container == .aiff),
                sampleRate: rng.pick(DecodeEnvelope.standardSampleRates), channelCount: rng.inRange(1 ... 8)
            )
        }
        switch variant % corruptVariants {
        case 0: return (pcm16(&rng), .damagedHeader)
        case 1: return (pcm16(&rng), .randomBytes(count: rng.logUniform(64 ... 131_072), fileExtension: rng.pick(corruptExtensions)))
        case 2: return (pcm16(&rng), .text(repeats: rng.inRange(1 ... 2000), fileExtension: rng.pick(corruptExtensions)))
        case 3: return (pcm16(&rng), .empty(fileExtension: rng.pick(corruptExtensions)))
        default:
            let wave = FixtureSpec(
                container: .wave, codec: .linearPCM, sampleFormat: rng.pick([.int(16, bigEndian: false), .int(24, bigEndian: false)]),
                sampleRate: rng.pick(DecodeEnvelope.standardSampleRates), channelCount: rng.inRange(1 ... 8)
            )
            return (wave, .streamingWaveSize)
        }
    }

    static func unsupported(_ rng: inout DecodeCaseRNG, variant: Int) -> (FixtureSpec, DecodePlant) {
        let float32 = SourceSampleFormat.float(32, bigEndian: false)
        switch variant % unsupportedVariants {
        case 0:
            var rate = rng.inRange(4000 ... 200_000)
            while DecodeEnvelope.standardSampleRates.contains(rate) { rate += 1 }
            let container = rng.pick([ContainerKind.wave, .aiff, .caf])
            let spec = FixtureSpec(container: container, codec: .linearPCM, sampleFormat: .int(16, bigEndian: container == .aiff), sampleRate: rate, channelCount: rng.inRange(1 ... 2))
            return (spec, .outsideEnvelope(name: "off-grid rate \(rate) Hz \(container.rawValue)", expected: .sampleRate(Double(rate))))
        case 1:
            let channels = rng.inRange(9 ... 16)
            let container = rng.pick([ContainerKind.wave, .caf])
            let spec = FixtureSpec(container: container, codec: .linearPCM, sampleFormat: .int(16, bigEndian: false), sampleRate: rng.pick(DecodeEnvelope.standardSampleRates), channelCount: channels)
            return (spec, .outsideEnvelope(name: "\(channels)-channel \(container.rawValue)", expected: .channelCount(channels)))
        case 2:
            let channels = rng.pick([3, 4, 5, 7])
            let container = rng.pick([ContainerKind.caf, .m4a])
            let spec = FixtureSpec(container: container, codec: .appleLossless, sampleFormat: .lossless(rng.pick([16, 24])), sampleRate: rng.pick(DecodeEnvelope.standardSampleRates), channelCount: channels)
            return (spec, .outsideEnvelope(name: "\(channels)-channel ALAC \(container.rawValue)", expected: .channelCount(channels)))
        case 3:
            let (formatID, codec) = rng.pick([(kAudioFormatULaw, "ulaw"), (kAudioFormatALaw, "alaw")])
            let rate = rng.pick([8000, 16000, 44100, 48000])
            let channels = rng.inRange(1 ... 2)
            let spec = FixtureSpec(container: .wave, codec: .linearPCM, sampleFormat: float32, sampleRate: rate, channelCount: channels, formatOverride: PlantedFailureTests.coded(formatID, rate: Double(rate), channels: UInt32(channels)))
            return (spec, .outsideEnvelope(name: "\(codec) WAVE", expected: .codec(container: "WAVE", codec: codec)))
        case 4:
            let rate = rng.pick([8000, 16000, 44100, 48000])
            let channels = rng.inRange(1 ... 2)
            let spec = FixtureSpec(container: .caf, codec: .linearPCM, sampleFormat: float32, sampleRate: rate, channelCount: channels, formatOverride: PlantedFailureTests.coded(kAudioFormatAppleIMA4, rate: Double(rate), channels: UInt32(channels)))
            return (spec, .outsideEnvelope(name: "IMA4 CAF", expected: .codec(container: "caff", codec: "ima4")))
        case 5:
            let rate = rng.pick(DecodeEnvelope.standardSampleRates)
            let channels = rng.inRange(1 ... 2)
            let spec = FixtureSpec(container: .wave, codec: .linearPCM, sampleFormat: float32, sampleRate: rate, channelCount: channels, formatOverride: PlantedFailureTests.lpcm(8, flags: 0, rate: Double(rate), channels: UInt32(channels)))
            return (spec, .outsideEnvelope(name: "unsigned 8-bit WAVE", expected: .sampleFormat("unsigned 8-bit integer")))
        case 6:
            let rate = rng.pick(DecodeEnvelope.standardSampleRates)
            let channels = rng.inRange(1 ... 2)
            let spec = FixtureSpec(container: .aiff, codec: .linearPCM, sampleFormat: float32, sampleRate: rate, channelCount: channels, formatOverride: PlantedFailureTests.lpcm(8, flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian, rate: Double(rate), channels: UInt32(channels)))
            return (spec, .outsideEnvelope(name: "signed 8-bit AIFF", expected: .sampleFormat("signedInteger8 BE")))
        default:
            let spec = FixtureSpec(container: .m4a, codec: .aac, sampleFormat: .lossy, sampleRate: rng.pick(DecodeEnvelope.aacSampleRates), channelCount: rng.inRange(1 ... 2), fileTypeOverride: kAudioFileAAC_ADTSType, extensionOverride: "aac")
            return (spec, .outsideEnvelope(name: "AAC in ADTS", expected: .container("adts")))
        }
    }
}

// MARK: - Records

/// One measured case (or the split's output-settings check). Codable so a run can write JSON lines.
struct DecodeCaseRecord: Codable, Sendable {
    var split: String
    var caseIndex: Int
    var seed: String
    var stratum: String
    /// "supported", "planted" or "output-settings".
    var kind: String
    var spec: String
    var frames: Int
    var chunkFrames: Int
    var sourceUnchanged: Bool
    var published: Bool
    // Supported cases (and output-settings).
    var mappingFailures: [String] = []
    var landmarkLags: [Int] = []
    var landmarksBelowCorrelation = 0
    var minimumCorrelation: Double?
    var bitExact: Bool?
    var primingFrames: Int64?
    var remainderFrames: Int64?
    var framesPerPacket: Int?
    var packetCount: Int64?
    // Planted cases.
    var plant: String?
    var expected: String?
    var observed: String?
    var expectedErrorMatched: Bool?
    var finishCalled: Bool?
    var appendedNotAbandoned: Bool?
    var readersLeftOpen: Int?
    var scopesBalanced: Bool?
}

struct DecodeGateOutcome: CustomStringConvertible {
    var gate: String
    var worst: Double
    var limit: Double
    var passed: Bool
    var detail: [String]
    var description: String { "\(gate): worst \(worst) limit \(limit) \(passed ? "PASS" : "FAIL") \(detail.prefix(8))" }
}

enum DecodeGateEvaluation {
    /// Evaluates every frozen gate. A gate with no evidence fails (never passes vacuously).
    static func evaluate(_ records: [DecodeCaseRecord]) -> [DecodeGateOutcome] {
        let supported = records.filter { $0.kind == "supported" }
        let planted = records.filter { $0.kind == "planted" }
        let settings = records.filter { $0.kind == "output-settings" }
        func count(_ gate: String, _ pool: [DecodeCaseRecord], limit: Int, failing: (DecodeCaseRecord) -> Bool) -> DecodeGateOutcome {
            guard !pool.isEmpty else { return DecodeGateOutcome(gate: gate, worst: .nan, limit: Double(limit), passed: false, detail: ["no evidence"]) }
            let bad = pool.filter(failing)
            return DecodeGateOutcome(gate: gate, worst: Double(bad.count), limit: Double(limit), passed: bad.count <= limit, detail: bad.map { "\($0.split)#\($0.caseIndex) \($0.stratum): \($0.mappingFailures.prefix(3)) \($0.observed ?? "")" })
        }
        let lags = supported.flatMap(\.landmarkLags)
        let weak = supported.reduce(0) { $0 + $1.landmarksBelowCorrelation }
        let worstLag = lags.map { Double(abs($0)) }.max()
        let landmarks = DecodeGateOutcome(
            gate: "landmarks",
            worst: (worstLag == nil || weak > 0) ? .nan : worstLag!,
            limit: Double(DecodeGates.landmarkOutputFrames),
            passed: worstLag != nil && weak == 0 && worstLag! <= Double(DecodeGates.landmarkOutputFrames),
            detail: weak > 0 ? ["\(weak) landmarks below the detection correlation"] : []
        )
        let present = Set(records.map(\.stratum))
        let missing = DecodeStratum.allCases.map(\.name).filter { !present.contains($0) }
        return [
            count("supported-mapping", supported, limit: DecodeGates.maximumSupportedMappingFailures) {
                !$0.mappingFailures.isEmpty || !$0.sourceUnchanged || !$0.published
            },
            landmarks,
            count("planted-explicit-error", planted, limit: DecodeGates.maximumPlantedWithoutExpectedError) { $0.expectedErrorMatched != true },
            count("planted-no-mutation", planted, limit: DecodeGates.maximumPlantedMutations) { !$0.sourceUnchanged },
            count("planted-no-stale-publication", planted, limit: DecodeGates.maximumPlantedPublications) {
                $0.published || $0.finishCalled != false || $0.appendedNotAbandoned != false || $0.readersLeftOpen != 0 || $0.scopesBalanced != true
            },
            count("output-settings", settings, limit: 0) { !$0.mappingFailures.isEmpty },
            DecodeGateOutcome(gate: "strata-coverage", worst: Double(missing.count), limit: 0, passed: missing.isEmpty, detail: missing),
        ]
    }
}

// MARK: - Running a case

struct DecodeFreezeAttempt {
    var decoded: DecodedSource<CollectedAudio>?
    var failure: DecodeFailure?
    var events: [String]
    var readersLeftOpen: Int
    var scopesBalanced: Bool
}

extension DecodeFreezeCase {
    /// Decodes `url` through a journaling sink, a counting content gateway and an adjustable metadata
    /// gateway. Records outcomes; never asserts.
    static func attempt(_ url: URL, chunkFrames: Int, io: AdjustableIO) async -> DecodeFreezeAttempt {
        let journal = SinkJournal()
        let content = CountingContentIO()
        let ledger = SecurityScopeLedger()
        var decoded: DecodedSource<CollectedAudio>?
        var failure: DecodeFailure?
        do {
            decoded = try await makeDecoder(chunkFrames: chunkFrames, io: io, content: content, ledger: ledger).decode(url, source: SourceID()) { interpretation in
                JournalingSink(inner: CollectingSink(channelCount: interpretation.channelCount, maximumChunk: chunkFrames), journal: journal)
            }
        } catch {
            failure = error
        }
        let balance = io.scopeBalance
        return DecodeFreezeAttempt(
            decoded: decoded, failure: failure, events: journal.events, readersLeftOpen: content.openReaders,
            scopesBalanced: ledger.snapshot.openScopes == 0 && balance.starts == balance.stops
        )
    }

    /// Writes this case's source into `directory` and returns its URL (planted damage applied).
    func materialize(in directory: FixtureDirectory) throws -> URL {
        let name = "\(split)-\(index)-\(stratum.name)"
        switch plant {
        case nil, .changedWhileDecoding, .outsideEnvelope:
            return try directory.write(spec, signal: signal, name: "\(name).\(spec.fileExtension)")
        case let .truncate(fraction):
            let whole = try directory.write(spec, signal: signal, name: "\(name)-whole.\(spec.fileExtension)")
            let bytes = try Data(contentsOf: whole)
            return try directory.writeBytes(bytes.prefix(Int(Double(bytes.count) * fraction)), as: "\(name).\(spec.fileExtension)")
        case .damagedHeader:
            var bytes = try Data(contentsOf: directory.write(spec, signal: signal, name: "\(name)-whole.\(spec.fileExtension)"))
            bytes.replaceSubrange(0 ..< 4, with: Data("XXXX".utf8))
            return try directory.writeBytes(bytes, as: "\(name).\(spec.fileExtension)")
        case let .randomBytes(count, ext):
            var rng = SplitMix64(state: seed ^ 0xBAD0_BAD0_BAD0_BAD0)
            return try directory.writeBytes(Data((0 ..< count).map { _ in UInt8(truncatingIfNeeded: rng.next()) }), as: "\(name).\(ext)")
        case let .text(repeats, ext):
            return try directory.writeBytes(Data(String(repeating: "not audio at all\n", count: repeats).utf8), as: "\(name).\(ext)")
        case let .empty(ext):
            return try directory.writeBytes(Data(), as: "\(name).\(ext)")
        case .streamingWaveSize:
            var bytes = try Data(contentsOf: directory.write(spec, signal: signal, name: "\(name)-whole.wav"))
            guard let tag = bytes.range(of: Data("data".utf8)) else { throw FixtureError.audioToolbox("no data chunk", -1) }
            bytes.replaceSubrange(tag.upperBound ..< tag.upperBound + 4, with: [0xFF, 0xFF, 0xFF, 0xFF])
            return try directory.writeBytes(bytes, as: "\(name).wav")
        }
    }

    func measure(in directory: FixtureDirectory) async throws -> (record: DecodeCaseRecord, interpretation: FormatInterpretation?) {
        let url = try materialize(in: directory)
        let before = try FileSnapshot(url)
        let io: AdjustableIO
        if case let .changedWhileDecoding(change) = plant {
            io = AdjustableIO { result, call in if call == 1 { change.apply(&result) } }
        } else {
            io = AdjustableIO()
        }
        let outcome = await Self.attempt(url, chunkFrames: chunkFrames, io: io)
        let unchanged = (try? FileSnapshot(url)) == before
        var record = DecodeCaseRecord(
            split: split, caseIndex: index, seed: String(format: "0x%016llX", seed), stratum: stratum.name,
            kind: plant == nil ? "supported" : "planted", spec: spec.testDescription, frames: frames, chunkFrames: chunkFrames,
            sourceUnchanged: unchanged, published: outcome.events.contains("finish") || outcome.decoded != nil
        )
        if let plant {
            let expected = plant.expected
            record.plant = plant.description
            record.expected = expected.description
            record.observed = outcome.failure.map { "\($0)" } ?? "decoded"
            record.expectedErrorMatched = expected.matches(outcome.failure) && (!expected.refusedBeforeSink || outcome.events.isEmpty)
            record.finishCalled = outcome.events.contains("finish")
            record.appendedNotAbandoned = outcome.events.contains("append") && outcome.events.last != "abandon"
            record.readersLeftOpen = outcome.readersLeftOpen
            record.scopesBalanced = outcome.scopesBalanced
            if case .changedWhileDecoding = plant, io.metadataCalls != 2 {
                record.expectedErrorMatched = false
                record.observed = (record.observed ?? "") + " (metadata calls \(io.metadataCalls), expected 2)"
            }
            return (record, nil)
        }
        guard let decoded = outcome.decoded else {
            record.mappingFailures = ["decode failed: \(outcome.failure.map { "\($0)" } ?? "no result")"]
            return (record, nil)
        }
        if !outcome.scopesBalanced || outcome.readersLeftOpen != 0 { record.mappingFailures.append("resources not released") }
        if outcome.events.last != "finish" || outcome.events.contains("abandon") { record.mappingFailures.append("sink lifecycle \(outcome.events.suffix(2))") }
        verify(decoded, into: &record)
        return (record, decoded.interpretation)
    }

    /// Checks the decode against the generator's truth, appending a failure line per mismatch.
    func verify(_ decoded: DecodedSource<CollectedAudio>, into record: inout DecodeCaseRecord) {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { failures.append(message()) } }
        let i = decoded.interpretation
        let truthFrames = Int64(frames)
        record.primingFrames = i.frames.primingFrames
        record.remainderFrames = i.frames.remainderFrames
        record.framesPerPacket = i.packets.framesPerPacket
        record.packetCount = i.packets.packetCount

        // Versions, container, codec, bit depth, rate and channel metadata.
        check(i.formatInterpretationVersion == FormatInterpretation.currentVersion, "formatInterpretationVersion \(i.formatInterpretationVersion)")
        check(i.envelopeVersion == DecodeEnvelope.version, "envelopeVersion \(i.envelopeVersion)")
        check(i.container.kind == spec.container, "container \(i.container.kind)")
        check(i.container.extensionMatchesContainer, "extension mismatch")
        check(i.codec.kind == spec.codec, "codec \(i.codec.kind)")
        check(i.sampleFormat == spec.sampleFormat, "sample format \(i.sampleFormat)")
        check(i.sourceSampleRate == spec.sampleRate, "rate \(i.sourceSampleRate)")
        check(i.channelCount == spec.channelCount, "channels \(i.channelCount)")
        check(i.output.sampleRate == spec.sampleRate && i.output.channelCount == spec.channelCount, "output format \(i.output.sampleRate)/\(i.output.channelCount)")
        check(i.output.representsSourceSamplesExactly == spec.sampleFormat.isExactInFloat32, "representsSourceSamplesExactly")
        check(!i.channelLayout.isDeclaredBySource || i.channelLayout.channelLabels.isEmpty || i.channelLayout.channelLabels.count == spec.channelCount, "layout labels \(i.channelLayout.channelLabels.count)")

        // Priming / padding / decoded-frame origin.
        check(i.frames.validFrames == truthFrames, "validFrames \(i.frames.validFrames) != \(truthFrames)")
        if spec.codec.isLossy {
            check(i.frames.hasPacketTable && i.frames.primingFrames > 0, "lossy priming undeclared")
        }
        if spec.codec == .linearPCM {
            check(i.frames.primingFrames == 0 && i.frames.remainderFrames == 0, "PCM priming/remainder \(i.frames.primingFrames)/\(i.frames.remainderFrames)")
        }
        check(i.frames.primingFrames >= 0 && i.frames.remainderFrames >= 0, "negative priming/remainder")
        if i.frames.hasPacketTable, let packets = i.packets.packetCount, i.packets.framesPerPacket > 0 {
            let total = i.frames.primingFrames + i.frames.validFrames + i.frames.remainderFrames
            check(total == packets * Int64(i.packets.framesPerPacket), "priming+valid+remainder \(total) != packets \(packets) x \(i.packets.framesPerPacket)")
        }
        let origin = i.origin
        check(origin.sourceSampleRate == spec.sampleRate, "origin rate")
        check(origin.decodedFrameCount == truthFrames, "origin decodedFrameCount \(origin.decodedFrameCount)")
        check(origin.sourceFrameOfFirstDecodedFrame == 0, "origin first frame \(origin.sourceFrameOfFirstDecodedFrame)")
        check(origin.discardedLeadingStreamFrames == i.frames.primingFrames, "origin leading \(origin.discardedLeadingStreamFrames)")
        check(origin.declaredTrailingStreamFrames == i.frames.remainderFrames, "origin trailing \(origin.declaredTrailingStreamFrames)")
        check(origin.sourceDuration == SourceFramePosition(frame: truthFrames, sampleRate: spec.sampleRate), "sourceDuration")
        let signal = self.signal
        var probes: [Int64] = [0, truthFrames - 1, truthFrames / 2]
        for landmarks in signal.landmarks { probes += landmarks.map(Int64.init) }
        for d in probes {
            check(origin.sourceFrame(forDecodedFrame: d) == d, "sourceFrame(\(d))")
            check(origin.decodedFrame(forSourceFrame: d) == d, "decodedFrame(\(d))")
            check(origin.codecStreamFrame(forDecodedFrame: d) == i.frames.primingFrames + d, "codecStreamFrame(\(d))")
        }
        for outside: Int64 in [-1, truthFrames] {
            check(origin.sourceFrame(forDecodedFrame: outside) == nil && origin.decodedFrame(forSourceFrame: outside) == nil && origin.codecStreamFrame(forDecodedFrame: outside) == nil, "origin maps out-of-range \(outside)")
        }
        let report = decoded.report
        check(report.leadingStreamFramesDiscarded == i.frames.primingFrames, "report leading \(report.leadingStreamFramesDiscarded)")
        check(report.codecStreamFramesRead == i.frames.primingFrames + truthFrames + report.trailingStreamFramesDiscarded, "report stream frames \(report.codecStreamFramesRead)")
        check(report.trailingStreamFramesDiscarded >= 0 && report.trailingStreamFramesDiscarded <= i.frames.remainderFrames + Int64(max(1, i.packets.framesPerPacket)), "report trailing \(report.trailingStreamFramesDiscarded)")
        check(report.chunkCapacityFrames == chunkFrames, "chunk capacity \(report.chunkCapacityFrames)")

        // Variable rate and packet facts.
        check(i.packets.isVariableBitRate == (spec.codec != .linearPCM), "isVariableBitRate \(i.packets.isVariableBitRate)")
        if spec.codec == .linearPCM {
            let bytes = (spec.sampleFormat.bitsPerSample ?? 0) / 8 * spec.channelCount
            check(i.packets.framesPerPacket == 1 && i.packets.bytesPerPacket == bytes, "PCM packets \(i.packets.framesPerPacket)/\(i.packets.bytesPerPacket)")
        } else {
            check(i.packets.bytesPerPacket == 0, "coded bytesPerPacket \(i.packets.bytesPerPacket)")
            check(i.packets.framesPerPacket > 0, "coded framesPerPacket \(i.packets.framesPerPacket)")
            check((i.packets.packetCount ?? 0) > 0, "coded packetCount \(String(describing: i.packets.packetCount))")
        }
        if let assumed = assumedFramesPerPacket {
            check(i.packets.framesPerPacket == assumed, "framesPerPacket \(i.packets.framesPerPacket) != assumed \(assumed)")
        }

        // Decoded samples: chunking, exactness and landmarks.
        let product = decoded.product
        check(product.chunkSizes.allSatisfy { $0 > 0 && $0 <= chunkFrames } && product.chunkSizes.reduce(0, +) == frames, "chunk sizes")
        let channels = product.channels
        guard channels.count == spec.channelCount, channels.allSatisfy({ $0.count == frames }) else {
            failures.append("decoded shape \(channels.count) x \(channels.map(\.count))")
            record.mappingFailures += failures
            return
        }
        if spec.isExact {
            record.bitExact = channels == signal.channels
            check(record.bitExact == true, "not bit-exact")
        }
        let threshold = Float(spec.isExact ? DecodeGates.exactMinimumCorrelation : DecodeGates.lossyMinimumCorrelation)
        var minimum: Float = 1
        for c in channels.indices {
            for (k, truth) in signal.landmarks[c].enumerated() {
                // A channel repeats one burst at all three landmarks, so the search stays within half the
                // gap to its nearest other landmark (half-gap ≥ 1132 frames at 9000 frames and 8 channels).
                let gap = signal.landmarks[c].filter { $0 != truth }.map { abs($0 - truth) }.min() ?? Int.max
                let found = LandmarkSignal.locate(signal.bursts[c][k], in: channels[c], near: truth, window: min(3000, gap / 2))
                minimum = min(minimum, found.correlation)
                if found.correlation < threshold {
                    record.landmarksBelowCorrelation += 1
                    continue
                }
                record.landmarkLags.append(found.lag)
                if spec.isExact { check(found.lag == 0, "exact landmark ch \(c) #\(k) lag \(found.lag)") }
            }
        }
        record.minimumCorrelation = Double(minimum)
        record.mappingFailures += failures
    }
}

// MARK: - Running a split

/// The split-level WW-050 mixed-input check: every supported interpretation of the split, as one group,
/// gets one common output rate and format from `OutputSettingsPolicy` (48 kHz / 24-bit PCM by default,
/// since every envelope rate is within the decimation limit of 48 kHz), and the decision is current.
func outputSettingsRecord(split: String, interpretations: [FormatInterpretation]) -> DecodeCaseRecord {
    var record = DecodeCaseRecord(split: split, caseIndex: -1, seed: "-", stratum: "output-settings", kind: "output-settings", spec: "\(interpretations.count) supported sources", frames: 0, chunkFrames: 0, sourceUnchanged: true, published: true)
    var failures: [String] = []
    switch Result(catching: { () throws(OutputSettingsFailure) in try OutputSettingsPolicy.decide(interpretations) }) {
    case let .failure(error):
        failures.append("policy refused: \(error)")
    case let .success(decision):
        if decision.settings.sampleRate != 48000 { failures.append("rate \(decision.settings.sampleRate)") }
        if decision.settings.sampleFormat != .pcmInt24 { failures.append("format \(decision.settings.sampleFormat)") }
        if decision.policyVersion != OutputSettingsPolicy.version { failures.append("policy version \(decision.policyVersion)") }
        if decision.reasons.first != .preferredRateChosen(48000) { failures.append("first reason \(String(describing: decision.reasons.first))") }
        if decision.settings.outputChannelCount != interpretations.reduce(0, { $0 + $1.channelCount }) { failures.append("output channels \(decision.settings.outputChannelCount)") }
        if decision.settings.channels.map(\.source) != interpretations.map(\.source) { failures.append("channel order") }
        if !decision.isCurrent(for: interpretations, configuration: .default) { failures.append("decision not current for its own inputs") }
        if decision.isCurrent(for: interpretations.dropLast(), configuration: .default) { failures.append("dropping an input did not invalidate") }
        if Set(interpretations.map(\.sourceSampleRate)).count > 1, !decision.reasons.contains(where: { if case .mixedSourceRates = $0 { true } else { false } }) {
            failures.append("mixed rates not named")
        }
    }
    // A user-chosen source-derived rate is the most common source rate, ties to the higher.
    var counts: [Int: Int] = [:]
    for i in interpretations { counts[i.sourceSampleRate, default: 0] += 1 }
    let expected = counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }?.key
    let matching = OutputSettingsConfiguration(rateChoice: .matchSources)
    switch Result(catching: { () throws(OutputSettingsFailure) in try OutputSettingsPolicy.decide(interpretations, configuration: matching) }) {
    case let .failure(error): failures.append("matchSources refused: \(error)")
    case let .success(decision): if decision.settings.sampleRate != expected { failures.append("matchSources rate \(decision.settings.sampleRate) != \(String(describing: expected))") }
    }
    record.mappingFailures = failures
    return record
}

func runDecodeSplit(_ split: String, cases: Int) async throws -> [DecodeCaseRecord] {
    let directory = try FixtureDirectory("m3-freeze-decode-3-\(split)")
    let measured = try await withThrowingTaskGroup(of: (DecodeCaseRecord, FormatInterpretation?).self) { group in
        var next = 0
        func addNext() {
            guard next < cases else { return }
            let index = next
            next += 1
            group.addTask { try await DecodeFreezeCase(split: split, index: index).measure(in: directory) }
        }
        for _ in 0 ..< DecodeFixture.maxConcurrency { addNext() }
        var results: [(DecodeCaseRecord, FormatInterpretation?)] = []
        while let result = try await group.next() {
            results.append(result)
            addNext()
        }
        return results
    }
    let ordered = measured.sorted { $0.0.caseIndex < $1.0.caseIndex }
    var records = ordered.map(\.0)
    records.append(outputSettingsRecord(split: split, interpretations: ordered.compactMap(\.1)))
    if let directory = DecodeFixture.recordsDirectory {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = try records.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(
            toFile: "\(directory)/\(DecodeFixture.recordsFileName(split: split))",
            atomically: true,
            encoding: .utf8
        )
    }
    return records
}
