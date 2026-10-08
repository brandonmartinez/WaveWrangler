import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWAlignPipeline

enum RenderEnvelopeProfileGate {
    static let enabled = ProcessInfo.processInfo.environment["WW_RENDER_ENVELOPE_PROFILE"] == "1"
    static let reason: Comment = "run each profile in a separate process (WW_RENDER_ENVELOPE_PROFILE=1)"
}

private actor GroupOverlap {
    private var groups = Set<RecorderGroupID>()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive(_ group: RecorderGroupID) async {
        groups.insert(group)
        if groups.count == 2 {
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Aligned render whole-process memory profiles", .serialized,
       .enabled(if: RenderEnvelopeProfileGate.enabled, RenderEnvelopeProfileGate.reason))
struct RenderEnvelopeProfileTests {
    @Test("Six channels at the 180-second segment boundary")
    func boundary() async throws {
        let config = AlignmentPipelineConfiguration(
            concurrency: 2, targetExcerptSeconds: 10, searchDeviationSeconds: 2, renderSegmentSeconds: 180
        )
        let fixture = try await RenderEnvelopeTests.fixture(
            configuration: config, targets: [2, 2, 2], seconds: 180, label: "boundary-180"
        )
        try await profile(fixture, shape: "3 inputs × 2 channels, 48k output, concurrency 2, 16k decoder, 180s segment")
    }

    @Test("Two simultaneous eight-channel groups, cached rerender")
    func simultaneous() async throws {
        let groups = [
            GroupSpec(name: "reference", sources: [
                SourceSpec(name: "ref", channels: 2, seconds: 10, signal: .scene(seed: TwoRecorder.seed)),
            ]),
            GroupSpec(name: "A", sources: (0 ..< 4).map {
                SourceSpec(name: "a-\($0)", channels: 2, seconds: 10, signal: .scene(seed: TwoRecorder.seed))
            }),
            GroupSpec(name: "B", sources: (0 ..< 4).map {
                SourceSpec(name: "b-\($0)", channels: 2, seconds: 10, signal: .scene(seed: TwoRecorder.seed))
            }),
        ]
        let config = AlignmentPipelineConfiguration(
            concurrency: 2, targetExcerptSeconds: 10, searchDeviationSeconds: 2, renderSegmentSeconds: 10
        )
        let overlap = GroupOverlap()
        let fixture = try await PipelineFixture(
            groups, configuration: config,
            hooks: AlignmentPipelineTestHooks(beforeSegmentPublish: { group, _ in await overlap.arrive(group) }),
            label: "simultaneous"
        )
        let analysis = try await fixture.analyse(preferredReference: "ref")
        try await fixture.acceptAndActivate(analysis, [
            fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 0, note: "synthetic clock truth"),
            fixture.epochs[2]: .numeric(ppm: 0, offsetMilliseconds: 0, note: "synthetic clock truth"),
        ])
        try await profile(fixture, shape: "2 groups × 4 inputs × 2 channels, 48k output, concurrency 2, 16k decoder, 10s segment")
    }

    @Test("Seven mixed-rate channels, resampling and cached rerender")
    func resampling() async throws {
        let fixture = try await RenderEnvelopeTests.fixture(
            targets: [4, 3], targetRates: [44_100, 48_000], seconds: 10, label: "seven-mixed-rate"
        )
        try await profile(fixture, shape: "2 inputs × 4+3 channels, 44.1/48k inputs → 48k output, concurrency 2, 16k decoder, 2s segment")
    }

    private func profile(_ fixture: PipelineFixture, shape: String) async throws {
        let baseline = MemorySampler.now()
        let before = MemorySampler.maxResident()
        let sampler = MemorySampler()
        let sources = fixture.sources.filter { $0.id != fixture.id("ref") }
        let ids = Set(sources.map(\.id))
        let authorizations = fixture.authorizations.filter { ids.contains($0.source) }
        let first = try await fixture.pipeline.renderAlignedAssets(
            model: fixture.model, episode: fixture.episodeID, sources: sources, authorizations: authorizations
        )
        let repeatRender = try await fixture.pipeline.renderAlignedAssets(
            model: fixture.model, episode: fixture.episodeID, sources: sources, authorizations: authorizations
        )
        let sampled = sampler.stop()
        let maxRSS = MemorySampler.maxResident()
        #expect(first.isComplete && repeatRender.isComplete)
        #expect(first.groups.allSatisfy { $0.segmentsRendered > 0 })
        #expect(repeatRender.groups.allSatisfy { $0.segmentsReused == $0.segments })
        #expect(fixture.content.openReaders == 0)
        let gate = await fixture.pipeline.gate.snapshot
        print("""
        [render-envelope] shape: \(shape)
        [render-envelope] host: \(ProcessInfo.processInfo.hostName), bytes: baseline RSS \(baseline.resident), footprint \(baseline.footprint), ru_maxrss \(before)
        [render-envelope] sampled RSS \(sampled.resident), physical footprint \(sampled.footprint), ru_maxrss \(maxRSS), gate peak estimates \(gate.peakBytes), gate peak units \(gate.peakActive)
        [render-envelope] first segments \(first.groups.map(\.segmentsRendered)), repeated segments \(repeatRender.groups.map(\.segmentsReused))
        """)
        #expect(maxRSS <= 1_073_741_824)
        #expect(sampled.resident <= 1_073_741_824)
        #expect(sampled.footprint <= 1_073_741_824)
    }
}
