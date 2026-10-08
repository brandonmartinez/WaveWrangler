import Foundation
import WWCore
import WWDecode
import WWDerived
import WWRender
import WWTimeMap

// MARK: - Payload

/// One output channel of one aligned segment, as stored in the derived (app-cache) store. Internal derived
/// asset only: export stays blocked until M4.
///
/// Layout: `"WWAS"`, UInt32 LE header length, the JSON header, then `frameCount` binary32 LE samples.
public struct AlignedAudioSegment: Sendable, Equatable {
    public struct Header: Sendable, Codable, Equatable {
        public var formatVersion: Int
        public var group: RecorderGroupID
        public var source: SourceID
        public var occurrence: SourceOccurrenceID
        public var decodedChannel: Int
        public var map: MapRevisionReference
        /// The content identity of the accepted map revision it was rendered under.
        public var mapDigest: String
        public var outputRate: Int
        public var segmentIndex: Int64
        public var firstOutputFrame: Int64
        public var frameCount: Int
        public var rendererVersion: Int
        public var renderRecipeVersion: Int
        public var outputAssetFormatVersion: Int
    }

    public static let formatVersion = 2
    static let magic = Data("WWAS".utf8)

    public let header: Header
    public let samples: [Float]

    public enum DecodingError: Error, Equatable {
        case notAnAlignedSegment
        case unsupportedVersion(Int)
        case lengthMismatch
    }

    static func encode(header: Header, samples: ArraySlice<Float>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(header)
        var data = Data(capacity: magic.count + 4 + json.count + samples.count * 4)
        data.append(magic)
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(json)
        for sample in samples {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ data: Data) throws -> AlignedAudioSegment {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Data(bytes[0 ..< 4]) == magic else { throw DecodingError.notAnAlignedSegment }
        let length = Int(UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24)
        guard bytes.count >= 8 + length else { throw DecodingError.lengthMismatch }
        let header = try JSONDecoder().decode(Header.self, from: Data(bytes[8 ..< (8 + length)]))
        guard header.formatVersion == formatVersion else { throw DecodingError.unsupportedVersion(header.formatVersion) }
        let body = bytes.count - 8 - length
        guard header.frameCount >= 0, body == header.frameCount * 4 else { throw DecodingError.lengthMismatch }
        var samples = [Float](repeating: 0, count: header.frameCount)
        var offset = 8 + length
        for index in samples.indices {
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            samples[index] = Float(bitPattern: bits)
            offset += 4
        }
        return AlignedAudioSegment(header: header, samples: samples)
    }
}

// MARK: - Plan

/// Why a placed source's channels are not rendered.
public enum NotRenderedReason: Sendable, Equatable {
    /// Its epoch has no supported mapping in the accepted map.
    case epochUnsupported(RecordingEpochID)
    /// Content work is not allowed for it (availability, authorization or registration).
    case ineligible(SourceIneligibility)
    /// No current probed facts (analyse first).
    case factsUnavailable
}

/// One recorder group's render: every same-group mapped channel, on one global segment grid.
struct GroupRenderJob: Sendable {
    struct Participant: Sendable {
        let source: AlignmentSource
        let facts: SourceFacts
        var occurrence: SourceOccurrenceID { alignmentOccurrenceID(for: source.id) }
    }

    let episode: EpisodeID
    let revision: MapRevisionReference
    let identity: AcceptedMapIdentity
    let map: GroupTimeMap
    let nominalOutputRate: NominalRate
    let participants: [Participant]
    let outputFrames: Range<Int64>
    let segmentFrames: Int64
    let recipeBaseName: String

    var outputRate: Int { Int(nominalOutputRate.framesPerSecond) }

    var channels: [(participant: Int, channel: Int)] {
        participants.indices.flatMap { index in (0 ..< participants[index].facts.channelCount).map { (index, $0) } }
    }

    var segmentIndices: ClosedRange<Int64> {
        Self.floorDiv(outputFrames.lowerBound, segmentFrames) ... Self.floorDiv(outputFrames.upperBound - 1, segmentFrames)
    }

    func frames(ofSegment index: Int64) -> Range<Int64> {
        Swift.max(outputFrames.lowerBound, index * segmentFrames) ..< Swift.min(outputFrames.upperBound, (index + 1) * segmentFrames)
    }

    /// The segment's identity lives in the recipe name (the M2-C5 key has no range component).
    func recipe(ofSegment index: Int64) -> RecipeReference {
        let range = frames(ofSegment: index)
        return RecipeReference(
            name: recipeBaseName + "[group=\(map.group);rate=\(outputRate);seg=\(index);frames=\(range.lowerBound)..<\(range.upperBound)]",
            revision: AlignmentAssetKinds.renderRecipeVersion
        )
    }

    func key(participant: Participant, channel: Int, segment: Int64) -> DerivedAssetKey {
        DerivedAssetKey(
            asset: AlignmentAssetKinds.alignedAudio,
            sources: [SourceRevision(source: participant.source.id, token: participant.facts.revisionToken)],
            format: .current,
            occurrence: participant.occurrence,
            channel: channel,
            map: revision,
            recipe: recipe(ofSegment: segment),
            // The exact accepted map content: a different map never shares (or adopts) this segment.
            upstream: [identity.key]
        )
    }

    func slot(participant: Participant, channel: Int, segment: Int64) -> DerivedSlot {
        PipelineSlots.alignedSegment(group: map.group, source: participant.source.id, channel: channel, segment: segment)
    }

    /// Checked, provisional process-memory admission. CollectingSink retains ALL output channels until
    /// publication finishes; only one channel at a time is encoded/staged/read back by the store. The
    /// multipliers allow for Data copies, decoder buffers and Swift array capacity, not just the renderer's
    /// much smaller reported window. Unmeasured rates, cursor sizes and map complexity refuse up front.
    func admissionBytes(chunkFrames: Int, recipe: RenderRecipe, concurrency: Int) throws(AlignmentWorkFailure) -> Int {
        guard concurrency <= 2 else { throw .renderEnvelope("concurrency \(concurrency) exceeds the provisional render envelope (2)") }
        guard outputRate <= 48_000 else { throw .renderEnvelope("output rate \(outputRate) exceeds the provisional render envelope (48000 Hz)") }
        guard chunkFrames <= 16_384 else { throw .renderEnvelope("decoder chunk \(chunkFrames) exceeds the provisional render envelope (16384 frames)") }
        guard participants.count <= 16 else { throw .renderEnvelope("too many simultaneous source cursors (\(participants.count))") }
        var complexity = map.epochs.count
        for epoch in map.epochs {
            if case let .mapped(segments, _) = epoch.mapping {
                let (sum, overflow) = complexity.addingReportingOverflow(segments.count)
                guard !overflow else { throw .renderEnvelope("map complexity overflows admission accounting") }
                complexity = sum
            }
        }
        for placement in map.placements {
            let (sum, overflow) = complexity.addingReportingOverflow(placement.spans.count)
            guard !overflow else { throw .renderEnvelope("map complexity overflows admission accounting") }
            complexity = sum
        }
        guard complexity <= 64 else { throw .renderEnvelope("map complexity \(complexity) exceeds the provisional render envelope (64)") }
        func add(_ left: Int, _ right: Int) throws(AlignmentWorkFailure) -> Int {
            let (result, overflow) = left.addingReportingOverflow(right)
            guard !overflow else { throw .renderEnvelope("render memory accounting overflow") }
            return result
        }
        func multiply(_ factors: Int...) throws(AlignmentWorkFailure) -> Int {
            var result = 1
            for factor in factors {
                let (product, overflow) = result.multipliedReportingOverflow(by: factor)
                guard !overflow else { throw .renderEnvelope("render memory accounting overflow") }
                result = product
            }
            return result
        }

        let frames = Int(Swift.min(segmentFrames, Int64(outputFrames.count)))
        let history = Int(CursorSampleProvider.history(for: recipe))
        let reach = try add(try multiply(recipe.outputChunkFrames, recipe.maximumDecimation), history)
        let perStream = try add(try add(history, reach), try multiply(2, chunkFrames))
        let output = try multiply(frames, channels.count, MemoryLayout<Float>.size)
        let stagedChannel = try multiply(frames, MemoryLayout<Float>.size, 8)
        var streams = 0
        for participant in participants {
            let retained = try multiply(perStream, participant.facts.channelCount, MemoryLayout<Float>.size, 2)
            let decoder = try multiply(chunkFrames, participant.facts.channelCount, MemoryLayout<Float>.size, 2)
            streams = try add(streams, try add(retained, decoder))
        }
        let estimate = try add(try add(output, stagedChannel), try add(streams, 8 << 20))
        guard estimate <= AlignmentPipelineConfiguration.maximumMemoryBudgetBytes else {
            throw .memoryBudget(requested: estimate, budget: AlignmentPipelineConfiguration.maximumMemoryBudgetBytes)
        }
        return estimate
    }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Output frames covering every mapped placed frame of the participants: `[floor(G·t_first),
    /// ceil(G·t_last)]` over each occurrence's placed spans. Frames outside the spans (outside the map's
    /// coverage) are never mapped, so they never widen the hull. Nil when nothing is mapped.
    static func hull(map: GroupTimeMap, occurrences: [SourceOccurrenceID], outputRate: Int) throws(AlignmentWorkFailure) -> Range<Int64>? {
        var lo: ExactRational?
        var hi: ExactRational?
        do throws(TimeMapError) {
            for occurrence in occurrences {
                guard let placement = map.placements.first(where: { $0.occurrence.id == occurrence }) else { continue }
                for span in placement.spans where span.endFrame > span.startFrame {
                    for frame in [span.startFrame, span.endFrame - 1] {
                        guard case let .aligned(position) = try map.alignedTime(ofFrame: frame, in: occurrence) else { continue }
                        if lo.map({ position.instant < $0 }) ?? true { lo = position.instant }
                        if hi.map({ $0 < position.instant }) ?? true { hi = position.instant }
                    }
                }
            }
            guard let lo, let hi else { return nil }
            let g = ExactRational(Int64(outputRate))
            let first = try lo.multiplied(by: g).floor()
            let last = try hi.multiplied(by: g).ceil()
            guard let k0 = Int64(exactly: first), let k1 = Int64(exactly: last + 1) else { throw TimeMapError.exactArithmeticEnvelopeExceeded }
            return k0 ..< k1
        } catch {
            throw .render(.arithmeticEnvelopeExceeded)
        }
    }
}

/// The renderer's planar output for one segment, kept per output channel.
struct CollectingSink: RenderOutputSink {
    let first: Int64
    var channels: [[Float]]
    var next: Int64

    init(manifest: RenderManifest) {
        first = manifest.outputStartFrame
        next = first
        let frames = Int(manifest.outputFrameCount)
        channels = (0 ..< manifest.channels.count).map { _ in
            var channel = [Float]()
            channel.reserveCapacity(frames)
            return channel
        }
    }

    mutating func append(_ chunk: RenderedChunk) throws {
        guard chunk.firstOutputFrame == next, chunk.channelCount == channels.count else {
            throw AlignmentWorkFailure.render(.sinkFailed("non-contiguous chunk"))
        }
        for c in channels.indices {
            channels[c].append(contentsOf: chunk.samples[(c * chunk.frameCount) ..< ((c + 1) * chunk.frameCount)])
        }
        next += Int64(chunk.frameCount)
    }

    func finish() throws -> [[Float]] { channels }

    mutating func abandon() { channels = [] }
}

// MARK: - Run

/// What one group's aligned-asset run did.
public struct GroupRenderReport: Sendable, Equatable {
    public let group: RecorderGroupID
    public let outputRate: Int
    public let outputFrames: Range<Int64>
    public let segments: Int
    /// Segments rendered this run (published, or discarded by the coordinator's currency check).
    public var segmentsRendered = 0
    /// Segments whose every channel was already ready or adopted from the store without rendering.
    public var segmentsReused = 0
    public var results: [PipelineJobResult] = []
    public var failure: AlignmentWorkFailure?
    /// Largest number of frames any one source stream retained.
    public var peakStreamFrames = 0
    public var peakRenderWorkingSetBytes = 0
}

enum AlignedAssetRun {
    static func run(_ job: GroupRenderJob, environment: PipelineEnvironment) async -> GroupRenderReport {
        var report = GroupRenderReport(
            group: job.map.group, outputRate: job.outputRate, outputFrames: job.outputFrames,
            segments: job.segmentIndices.count
        )
        let bytes: Int
        do throws(AlignmentWorkFailure) {
            bytes = try job.admissionBytes(
                chunkFrames: environment.decoder.configuration.chunkFrames, recipe: .m2Candidate,
                concurrency: environment.configuration.concurrency
            )
        } catch {
            report.failure = error
            return report
        }
        do {
            return try await environment.withAdmission(bytes: bytes) {
                await runAdmitted(job, environment: environment)
            }
        } catch {
            report.failure = workFailure(error)
            return report
        }
    }

    /// Cache reads, coordinator adoption, cursors, rendering and publication all retain the same
    /// process-wide admission. A cached channel can materialize multiple full-payload copies.
    private static func runAdmitted(_ job: GroupRenderJob, environment: PipelineEnvironment) async -> GroupRenderReport {
        var report = GroupRenderReport(
            group: job.map.group, outputRate: job.outputRate, outputFrames: job.outputFrames,
            segments: job.segmentIndices.count
        )
        let coordinator = environment.coordinator
        var toRender: [Int64] = []
        do throws(AlignmentWorkFailure) {
            for segment in job.segmentIndices {
                try await checkCurrent(job, coordinator: coordinator)
                let recipe = job.recipe(ofSegment: segment)
                await coordinator.setRecipe(recipe)
                let entries = job.channels.map { entry in
                    let participant = job.participants[entry.participant]
                    return (slot: job.slot(participant: participant, channel: entry.channel, segment: segment),
                            key: job.key(participant: participant, channel: entry.channel, segment: segment))
                }
                var allReady = true
                for entry in entries where await coordinator.state(of: entry.slot) != .ready(entry.key) { allReady = false }
                if let reasons = await staleReasons(entries.map(\.key), coordinator: coordinator) {
                    throw .staleInputs(reasons)
                }
                if entries.allSatisfy({ coordinator.store.payload(for: $0.key) != nil }) {
                    if allReady {
                        report.segmentsReused += 1
                        continue
                    }
                    // Adopted by the coordinator without running work; no content is opened.
                    let results = await boundedMap(entries, limit: environment.configuration.concurrency) { entry in
                        await coordinator.run(entry.slot, key: entry.key) { () throws(AlignmentWorkFailure) -> Data in
                            throw .encoding("the cached aligned segment disappeared before it was adopted")
                        }
                    }
                    report.results += results
                    if let failed = results.first(where: { !$0.isAvailable }) {
                        switch failed.outcome {
                        case .cancelled: throw .cancelled
                        case let .discardedStale(reasons): throw .staleInputs(reasons)
                        default: throw failed.failure ?? .encoding("a cached aligned segment did not publish")
                        }
                    }
                    report.segmentsReused += 1
                    continue
                }
                toRender.append(segment)
            }
        } catch {
            report.failure = error
            return report
        }
        guard !toRender.isEmpty else { return report }
        let segments = toRender

        let decoder = environment.decoder
        do {
            return try await withCursors(job.participants[...], decoder: decoder, opened: [:]) { [report] streams in
                var report = report
                let provider = CursorSampleProvider(streams: streams)
                for segment in segments {
                    do throws(AlignmentWorkFailure) {
                        try await renderSegment(segment, job: job, provider: provider, environment: environment, report: &report)
                    } catch {
                        report.failure = error
                        break
                    }
                }
                for stream in streams.values { report.peakStreamFrames = Swift.max(report.peakStreamFrames, await stream.peakHeldFrames) }
                return report
            }
        } catch {
            report.failure = workFailure(error)
            return report
        }
    }

    /// The accepted map must still be the job's exact map (revision and content), and the coordinator must
    /// be running.
    static func checkCurrent(_ job: GroupRenderJob, coordinator: DerivedJobCoordinator) async throws(AlignmentWorkFailure) {
        if Task.isCancelled { throw .cancelled }
        if await coordinator.isShutdown { throw .cancelled }
        guard await coordinator.inputs.acceptedMaps[job.episode] == job.revision.revision else { throw .acceptedMapChanged }
        guard await coordinator.state(of: job.identity.slot) == .ready(job.identity.key) else { throw .acceptedMapChanged }
    }

    static func staleReasons(_ keys: [DerivedAssetKey], coordinator: DerivedJobCoordinator) async -> Set<StaleReason>? {
        var reasons = Set<StaleReason>()
        for key in keys { reasons.formUnion(await coordinator.staleReasons(for: key)) }
        return reasons.isEmpty ? nil : reasons
    }

    static func renderSegment(
        _ segment: Int64,
        job: GroupRenderJob,
        provider: CursorSampleProvider,
        environment: PipelineEnvironment,
        report: inout GroupRenderReport
    ) async throws(AlignmentWorkFailure) {
        let coordinator = environment.coordinator
        try await checkCurrent(job, coordinator: coordinator)
        let frames = job.frames(ofSegment: segment)
        let request = RenderRequest(
            groupMap: job.map,
            outputRate: job.nominalOutputRate,
            outputFrames: frames,
            channels: job.channels.map { entry in
                RenderChannel(occurrence: job.participants[entry.participant].occurrence, decodedChannel: entry.channel, statedChannel: .unknown)
            },
            inputAssets: job.participants.map { participant in
                RenderInputAsset(
                    occurrence: participant.occurrence,
                    assetVersion: "decode[\(participant.facts.revisionToken);fiv=\(participant.facts.formatInterpretationVersion);env=\(participant.facts.envelopeVersion)]"
                )
            },
            recipe: .m2Candidate
        )
        let result: RenderResult<[[Float]]>
        do throws(RenderFailure) {
            result = try await GroupRenderer.render(request, provider: provider) { manifest in CollectingSink(manifest: manifest) }
        } catch {
            throw error == .cancelled ? .cancelled : .render(error)
        }
        report.peakRenderWorkingSetBytes = Swift.max(report.peakRenderWorkingSetBytes, result.report.peakWorkingSetBytes)
        // A result derived from what the cursors returned is published only once every source is verified
        // unchanged since it was opened.
        for stream in provider.streams.values {
            do throws(DecodeFailure) {
                try await stream.verifyUnchanged()
            } catch {
                throw error.asWorkFailure
            }
        }
        #if DEBUG
        await environment.hooks.beforeSegmentPublish?(job.map.group, segment)
        #endif
        try await checkCurrent(job, coordinator: coordinator)
        let rendered = result.product
        let entries = job.channels.enumerated().map { index, entry in (output: index, participant: job.participants[entry.participant], channel: entry.channel) }
        // One encode at a time per group: each group render occupies one unit of the configured concurrency.
        let results = await boundedMap(entries, limit: 1) { entry in
            let header = AlignedAudioSegment.Header(
                formatVersion: AlignedAudioSegment.formatVersion, group: job.map.group, source: entry.participant.source.id,
                occurrence: entry.participant.occurrence, decodedChannel: entry.channel, map: job.revision, mapDigest: job.identity.digest,
                outputRate: job.outputRate, segmentIndex: segment, firstOutputFrame: frames.lowerBound,
                frameCount: frames.count, rendererVersion: result.manifest.rendererVersion,
                renderRecipeVersion: result.manifest.recipe.version, outputAssetFormatVersion: result.manifest.outputAssetFormatVersion
            )
            return await coordinator.run(
                job.slot(participant: entry.participant, channel: entry.channel, segment: segment),
                key: job.key(participant: entry.participant, channel: entry.channel, segment: segment)
            ) { () throws(AlignmentWorkFailure) -> Data in
                do {
                    return try AlignedAudioSegment.encode(header: header, samples: rendered[entry.output][...])
                } catch {
                    throw .encoding(String(describing: error))
                }
            }
        }
        report.results += results
        report.segmentsRendered += 1
        if let failed = results.first(where: { !$0.isAvailable }) {
            switch failed.outcome {
            case .cancelled: throw .cancelled
            case let .discardedStale(reasons): throw .staleInputs(reasons)
            default: throw failed.failure ?? .encoding("an aligned segment did not publish")
            }
        }
    }

    /// Opens a gateway cursor per participant (nested, so all stay open together) and lends their streams.
    static func withCursors<T: Sendable>(
        _ remaining: ArraySlice<GroupRenderJob.Participant>,
        decoder: SourceDecoder,
        opened: [SourceID: SourceSampleStream],
        _ body: @escaping @Sendable ([SourceID: SourceSampleStream]) async throws -> T
    ) async throws -> T {
        guard let participant = remaining.first else { return try await body(opened) }
        let history = CursorSampleProvider.history(for: .m2Candidate)
        return try await decoder.withDecodingCursor(participant.source.url, source: participant.source.id) { cursor in
            let interpretation = cursor.interpretation
            try SourceProbe.verify(interpretation, source: participant.source.id, token: participant.facts.revisionToken)
            guard interpretation.sourceSampleRate == participant.facts.sampleRate,
                  interpretation.frames.validFrames == participant.facts.frameCount,
                  interpretation.channelCount == participant.facts.channelCount
            else { throw AlignmentWorkFailure.sourceFactsMismatch }
            var next = opened
            next[participant.source.id] = SourceSampleStream(cursor: cursor, channelCount: participant.facts.channelCount, history: history)
            return try await withCursors(remaining.dropFirst(), decoder: decoder, opened: next, body)
        }
    }
}
