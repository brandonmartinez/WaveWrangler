import Foundation
import Testing
import WWCore
import WWDecode
import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Aligned render: provisional memory-envelope admission", .serialized)
struct RenderEnvelopeTests {
    static func fixture(
        configuration: AlignmentPipelineConfiguration = PipelineFixture.smallConfiguration,
        chunkFrames: Int = 16_384,
        targets: [Int] = [2],
        targetRates: [Int] = [],
        seconds: Double = 4,
        label: String = "render-envelope"
    ) async throws -> PipelineFixture {
        let groups = [
            GroupSpec(name: "reference", sources: [
                SourceSpec(name: "ref", channels: 2, seconds: seconds, signal: .scene(seed: TwoRecorder.seed)),
            ]),
            GroupSpec(name: "target", sources: targets.enumerated().map { index, count in
                SourceSpec(
                    name: "target-\(index)", channels: count, seconds: seconds,
                    signal: .scene(seed: TwoRecorder.seed), sampleRate: targetRates.isEmpty ? 48_000 : targetRates[index]
                )
            }),
        ]
        let fixture = try await PipelineFixture(groups, configuration: configuration, chunkFrames: chunkFrames, label: label)
        let analysis = try await fixture.analyse(preferredReference: "ref")
        #expect(analysis.sourceFailures.isEmpty)
        try await fixture.acceptAndActivate(analysis, [fixture.epochs[1]:
            .numeric(ppm: 0, offsetMilliseconds: 0, note: "synthetic clock truth")])
        return fixture
    }

    @Test("Unsupported rates, concurrency and decoder buffers refuse without opening a cursor",
          arguments: ["rate-96k", "rate-192k", "concurrency-4", "buffer-1m"])
    func refusesBeforeSourceAccess(_ shape: String) async throws {
        let rate = shape == "rate-96k" ? 96_000 : shape == "rate-192k" ? 192_000 : 48_000
        let config = AlignmentPipelineConfiguration(
            concurrency: shape == "concurrency-4" ? 4 : 2,
            targetExcerptSeconds: 10, searchDeviationSeconds: 2, renderSegmentSeconds: 2,
            outputSettings: .init(preferredSampleRate: rate)
        )
        let fixture = try await Self.fixture(
            configuration: config, chunkFrames: shape == "buffer-1m" ? 1 << 20 : 16_384, label: shape
        )
        let opens = fixture.content.total.opens
        let report = try await fixture.render()
        #expect(!report.isComplete)
        #expect(report.groups.count == 2)
        for group in report.groups {
            guard case let .renderEnvelope(reason)? = group.failure else {
                Issue.record("expected typed render envelope refusal for \(shape): \(String(describing: group.failure))")
                continue
            }
            #expect(!reason.isEmpty)
            #expect(group.segmentsRendered == 0)
        }
        #expect(fixture.content.total.opens == opens)
        #expect(fixture.content.openReaders == 0)
    }

    @Test("Four inputs and eight channels, and a seven-channel group, retain normal multi-input rendering",
          arguments: [[2, 2, 2, 2], [4, 3]])
    func multiInputSmallSegments(_ targets: [Int]) async throws {
        let fixture = try await Self.fixture(targets: targets, label: "multi-\(targets.count)")
        let report = try await fixture.render()
        #expect(report.isComplete)
        let target = try #require(report.groups.first(where: { $0.group == fixture.groups[1] }))
        #expect(target.failure == nil)
        #expect(target.segmentsRendered > 0)
        #expect(target.results.count == target.segments * targets.reduce(0, +))
        #expect(fixture.content.openReaders == 0)
    }

    @Test("A low shared budget refuses the whole episode before any group's cursor opens")
    func wholeEpisodeBudget() async throws {
        let fixture = try await Self.fixture(targets: [2, 2, 2, 2], label: "low-budget")
        let config = AlignmentPipelineConfiguration(
            analysisMemoryBudgetBytes: 16 << 20, targetExcerptSeconds: 20,
            searchDeviationSeconds: 3, renderSegmentSeconds: 2
        )
        let pipeline = AlignmentPipeline(
            coordinator: fixture.coordinator, decoder: fixture.decoder, configuration: config
        )
        let opens = fixture.content.total.opens
        let report = try await pipeline.renderAlignedAssets(
            model: fixture.model, episode: fixture.episodeID,
            sources: fixture.sources, authorizations: fixture.authorizations
        )
        #expect(!report.isComplete)
        #expect(report.groups.count == 2)
        #expect(report.groups.allSatisfy {
            guard case let .memoryBudget(requested, budget)? = $0.failure else { return false }
            return requested > budget && budget == 16 << 20
        })
        #expect(fixture.content.total.opens == opens)
    }

    @Test("Segment cost accounts for all output channels and store copies; overflow is a typed refusal")
    func checkedAccounting() async throws {
        let fixture = try await Self.fixture(targets: [2, 2, 2], label: "accounting")
        let map = try fixture.model.timeMap(revision: 1, in: fixture.episodeID)
        let group = try #require(map.groups.first(where: { $0.group == fixture.groups[1] }))
        let participants = try fixture.sources.filter { $0.id != fixture.id("ref") }.map { source in
            let factsKey = SourceProbe.key(source: source.id, token: try PipelineFixture.registration(source.id, source.url).token)
            let data = try #require(fixture.store.payload(for: factsKey))
            return GroupRenderJob.Participant(source: source, facts: try SourceFacts.decode(data))
        }
        let identity = try #require(await fixture.pipeline.coordinator.inputs.acceptedMaps[fixture.episodeID])
        let revision = MapRevisionReference(episode: fixture.episodeID, revision: identity)
        let accepted = try #require(fixture.model.episode(fixture.episodeID)?.alignment?.map(revision: identity))
        let mapIdentity = try fixture.pipeline.mapIdentity(
            revision: revision, version: accepted, map: map,
            registered: await fixture.pipeline.coordinator.inputs.sources
        )
        let job = GroupRenderJob(
            episode: fixture.episodeID, revision: revision, identity: mapIdentity, map: group,
            nominalOutputRate: try NominalRate(48_000), participants: participants,
            outputFrames: 0 ..< 180 * 48_000, segmentFrames: 180 * 48_000, recipeBaseName: "test"
        )
        let bytes = try job.admissionBytes(chunkFrames: 16_384, recipe: .m2Candidate, concurrency: 2)
        #expect(bytes > 450 << 20, "the full six-channel sink and per-channel staging must be included")
        #expect(bytes <= 512 << 20)
        let oversized = GroupRenderJob(
            episode: fixture.episodeID, revision: revision, identity: mapIdentity, map: group,
            nominalOutputRate: try NominalRate(48_000), participants: participants,
            outputFrames: 0 ..< Int64.max / 2, segmentFrames: Int64.max, recipeBaseName: "test"
        )
        do throws(AlignmentWorkFailure) {
            _ = try oversized.admissionBytes(chunkFrames: 16_384, recipe: .m2Candidate, concurrency: 2)
            Issue.record("arithmetic overflow must refuse before allocation")
        } catch {
            guard case .renderEnvelope = error else {
                Issue.record("expected typed overflow refusal, got \(error)")
                return
            }
        }
    }

    @Test("Fragmented but valid maps refuse before any source cursor is opened")
    func fragmentedMap() async throws {
        let fixture = try await Self.fixture(label: "fragmented")
        let map = try fixture.model.timeMap(revision: 1, in: fixture.episodeID)
        let group = try #require(map.groups.first(where: { $0.group == fixture.groups[1] }))
        let epoch = try #require(group.epochs.first)
        guard case let .mapped(_, provenance) = epoch.mapping else {
            Issue.record("expected mapped epoch")
            return
        }
        let segments = try (0 ..< 80).map { index in
            try AffineClockSegment(
                groupClockStart: ExactRational(Int64(index), 20),
                groupClockEnd: ExactRational(Int64(index + 1), 20),
                rateRatio: .one, alignedOffset: .zero
            )
        }
        let fragmented = try GroupTimeMap(
            group: group.group, reference: group.reference,
            epochs: [EpochClockMap(epoch: epoch.epoch, mapping: .mapped(segments: segments, provenance: provenance))],
            placements: group.placements
        )
        let source = try #require(fixture.sources.first(where: { $0.id == fixture.id("target-0") }))
        let token = try PipelineFixture.registration(source.id, source.url).token
        let payload = try #require(fixture.store.payload(for: SourceProbe.key(source: source.id, token: token)))
        let facts = try SourceFacts.decode(payload)
        let revision = MapRevisionReference(episode: fixture.episodeID, revision: 1)
        let version = try #require(fixture.model.episode(fixture.episodeID)?.alignment?.map(revision: 1))
        let identity = try fixture.pipeline.mapIdentity(
            revision: revision, version: version, map: map,
            registered: await fixture.coordinator.inputs.sources
        )
        let job = GroupRenderJob(
            episode: fixture.episodeID, revision: revision, identity: identity, map: fragmented,
            nominalOutputRate: try NominalRate(48_000),
            participants: [.init(source: source, facts: facts)],
            outputFrames: 0 ..< 4 * 48_000, segmentFrames: 2 * 48_000, recipeBaseName: "test"
        )
        let opens = fixture.content.total.opens
        do throws(AlignmentWorkFailure) {
            _ = try job.admissionBytes(chunkFrames: 16_384, recipe: .m2Candidate, concurrency: 2)
            Issue.record("fragmented map must refuse")
        } catch {
            guard case .renderEnvelope = error else {
                Issue.record("expected map complexity refusal, got \(error)")
                return
            }
        }
        #expect(fixture.content.total.opens == opens)
    }
}
