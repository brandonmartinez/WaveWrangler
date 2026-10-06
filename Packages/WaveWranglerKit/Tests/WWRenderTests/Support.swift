import Foundation
import Synchronization
import Testing
import WWCore
import WWTimeMap
@testable import WWRender

// MARK: - Exact helpers

func q(_ n: Int64, _ d: Int64 = 1) -> ExactRational { try! ExactRational(n, d) }

func seg(_ u0: ExactRational, _ u1: ExactRational, _ a: ExactRational, _ b: ExactRational) -> AffineClockSegment {
    try! AffineClockSegment(groupClockStart: u0, groupClockEnd: u1, rateRatio: a, alignedOffset: b)
}

let manualProvenance = MapProvenance.manual(ManualCorrection(basis: .numericEntry))

func mapped(_ epoch: RecordingEpochID, _ segments: [AffineClockSegment]) -> EpochClockMap {
    EpochClockMap(epoch: epoch, mapping: .mapped(segments: segments, provenance: manualProvenance))
}

func span(_ start: Int64, _ end: Int64, _ epoch: RecordingEpochID, e: ExactRational = .zero) -> EpochSpan {
    EpochSpan(startFrame: start, endFrame: end, epoch: epoch, groupClockOffset: e)
}

func occurrence(_ id: SourceOccurrenceID = SourceOccurrenceID(), frames: Int64, rate: Int64) -> SourceOccurrence {
    try! SourceOccurrence(id: id, source: SourceID(), nominalRate: NominalRate(rate), frameCount: frames)
}

/// A non-reference recorder group (its timeline reference lives in another group), so any positive affine
/// map is allowed for its epochs.
func groupMap(epochs: [EpochClockMap], placements: [OccurrencePlacement]) throws(TimeMapError) -> GroupTimeMap {
    try GroupTimeMap(
        group: RecorderGroupID(),
        reference: TimelineReference(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID()),
        epochs: epochs,
        placements: placements
    )
}

func rate(_ hz: Int64) -> NominalRate { try! NominalRate(hz) }

func channels(_ occurrence: SourceOccurrenceID, _ count: Int, stated: Bool = true) -> [RenderChannel] {
    (0 ..< count).map { RenderChannel(occurrence: occurrence, decodedChannel: $0, statedChannel: stated ? .known($0) : .unknown) }
}

func assets(_ occurrences: [SourceOccurrenceID]) -> [RenderInputAsset] {
    occurrences.map { RenderInputAsset(occurrence: $0, assetVersion: "decoded-v1/\($0)") }
}

// MARK: - Providers

/// Generates every sample on demand from a pure function of (occurrence, decoded channel, frame), recording
/// each request and whether it ran on the main thread.
final class FunctionProvider: RenderSampleProvider, Sendable {
    typealias Generator = @Sendable (SourceOccurrenceID, Int, Int64) -> Float
    let generate: Generator
    let requests = Mutex<[RenderSampleRequest]>([])
    let calledOnMain = Mutex(false)
    let failAtRequest: Int?
    let mutate: (@Sendable (inout [[Float]]) -> Void)?

    init(failAtRequest: Int? = nil, mutate: (@Sendable (inout [[Float]]) -> Void)? = nil, _ generate: @escaping Generator) {
        self.generate = generate
        self.failAtRequest = failAtRequest
        self.mutate = mutate
    }

    struct Failure: Error {}

    func samples(for request: RenderSampleRequest) async throws -> [[Float]] {
        let index = requests.withLock { list in
            list.append(request)
            return list.count - 1
        }
        if pthread_main_np() != 0 { calledOnMain.withLock { $0 = true } }
        if index == failAtRequest { throw Failure() }
        var result = request.decodedChannels.map { channel in
            request.frames.map { generate(request.occurrence, channel, $0) }
        }
        mutate?(&result)
        return result
    }

    var recorded: [RenderSampleRequest] { requests.withLock { $0 } }
}

/// Serves fixed planar buffers per occurrence.
struct ArrayProvider: RenderSampleProvider {
    let buffers: [SourceOccurrenceID: [[Float]]]

    func samples(for request: RenderSampleRequest) async throws -> [[Float]] {
        let all = buffers[request.occurrence]!
        return request.decodedChannels.map { channel in
            Array(all[channel][Int(request.frames.lowerBound) ..< Int(request.frames.upperBound)])
        }
    }
}

// MARK: - Sinks

/// A thread-safe ordered log of sink lifecycle events.
final class EventLog: Sendable {
    private let storage = Mutex<[String]>([])
    func append(_ event: String) { storage.withLock { $0.append(event) } }
    var events: [String] { storage.withLock { $0 } }
}

/// Collects output as one contiguous planar buffer per channel; records lifecycle calls.
struct CollectingSink: RenderOutputSink {
    let events: EventLog?
    var channels: [[Float]] = []
    var firstFrame: Int64?
    var nextFrame: Int64?
    var failAtChunk: Int?
    var chunkCount = 0

    init(events: EventLog? = nil, failAtChunk: Int? = nil) {
        self.events = events
        self.failAtChunk = failAtChunk
    }

    struct Failure: Error {}

    mutating func append(_ chunk: RenderedChunk) throws {
        if pthread_main_np() != 0 { events?.append("main") }
        if chunkCount == failAtChunk { throw Failure() }
        chunkCount += 1
        if channels.isEmpty {
            channels = Array(repeating: [], count: chunk.channelCount)
            firstFrame = chunk.firstOutputFrame
        } else {
            #expect(chunk.firstOutputFrame == nextFrame)
        }
        nextFrame = chunk.firstOutputFrame + Int64(chunk.frameCount)
        for c in 0 ..< chunk.channelCount {
            channels[c].append(contentsOf: chunk.samples[c * chunk.frameCount ..< (c + 1) * chunk.frameCount])
        }
        events?.append("append")
    }

    mutating func finish() throws -> [[Float]] {
        events?.append("finish")
        return channels
    }

    mutating func abandon() {
        events?.append("abandon")
        channels = []
    }
}

/// Renders a request into memory.
func renderToArrays(_ request: RenderRequest, provider: some RenderSampleProvider) async throws(RenderFailure) -> RenderResult<[[Float]]> {
    try await GroupRenderer.render(request, provider: provider) { _ in CollectingSink() }
}

func recipe(chunk: Int) -> RenderRecipe {
    try! RenderRecipe(kernel: RenderRecipe.m2Candidate.kernel, outputChunkFrames: chunk)
}
