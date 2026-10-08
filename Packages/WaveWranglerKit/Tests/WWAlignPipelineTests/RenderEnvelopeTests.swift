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

    @Test("Checked admission enumerates rate, source, channel, chunk and segment corners")
    func admissionCorners() async throws {
        let fixture = try await Self.fixture(targets: [2, 2, 2], label: "admission-corners")
        let map = try fixture.model.timeMap(revision: 1, in: fixture.episodeID)
        let group = try #require(map.groups.first(where: { $0.group == fixture.groups[1] }))
        let seed = try #require(fixture.sources.first(where: { $0.id == fixture.id("target-0") }))
        let key = SourceProbe.key(source: seed.id, token: try PipelineFixture.registration(seed.id, seed.url).token)
        let baseFacts = try SourceFacts.decode(#require(fixture.store.payload(for: key)))
        let version = try #require(fixture.model.episode(fixture.episodeID)?.alignment?.map(revision: 1))
        let reference = MapRevisionReference(episode: fixture.episodeID, revision: 1)
        let identity = try fixture.pipeline.mapIdentity(
            revision: reference, version: version, map: map, registered: await fixture.coordinator.inputs.sources
        )
        var accepted = 0
        var refused = 0
        for rate in [8_000, 44_100, 48_000] {
            for sources in [1, 3, 4, 16] {
                for channels in [1, 2, 8] {
                    var facts = baseFacts
                    facts.interpretation.channelCount = channels
                    let participants = Array(repeating: GroupRenderJob.Participant(source: seed, facts: facts), count: sources)
                    for seconds in [1, 10, 180] {
                        let frames = Int64(seconds * rate)
                        let job = GroupRenderJob(
                            episode: fixture.episodeID, revision: reference, identity: identity, map: group,
                            nominalOutputRate: try NominalRate(Int64(rate)), participants: participants,
                            outputFrames: 0 ..< frames, segmentFrames: frames, recipeBaseName: "corners"
                        )
                        for chunk in [1, 4_096, 16_384] {
                            do throws(AlignmentWorkFailure) {
                                let bytes = try job.admissionBytes(
                                    chunkFrames: chunk, recipe: .m2Candidate, concurrency: 2
                                )
                                #expect(bytes <= AlignmentPipelineConfiguration.maximumMemoryBudgetBytes)
                                accepted += 1
                            } catch {
                                guard case .memoryBudget = error else {
                                    Issue.record("unexpected corner refusal: \(error)")
                                    continue
                                }
                                refused += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(accepted > 0 && refused > 0 && accepted + refused == 324)
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

    @Test("Different public pipeline instances cannot jointly admit more than the process budget")
    func multiInstanceAdmission() async throws {
        let first = try await Self.fixture(label: "process-first")
        let second = try await Self.fixture(label: "process-second")
        let entered = Latch()
        let release = Latch()
        let secondEntered = Box(false)
        let bytes = 300 << 20
        let firstWork = Task {
            try await first.pipeline.environment.withAdmission(bytes: bytes) {
                await entered.open()
                await release.wait()
            }
        }
        await entered.wait()
        let secondWork = Task {
            try await second.pipeline.environment.withAdmission(bytes: bytes) {
                secondEntered.value = true
            }
        }
        try await ConcurrencyTests.until {
            let local = await second.pipeline.gate.snapshot
            let process = await ResourceGate.process.snapshot
            return local.active == 1 && process.waiting > 0
        }
        let held = await ResourceGate.process.snapshot
        #expect(held.activeBytes >= bytes && held.activeBytes <= AlignmentPipelineConfiguration.maximumMemoryBudgetBytes)
        #expect(!secondEntered.value)
        await release.open()
        try await firstWork.value
        try await secondWork.value
        #expect(await first.pipeline.gate.snapshot.activeBytes == 0)
        #expect(await second.pipeline.gate.snapshot.activeBytes == 0)
        #expect(secondEntered.value)
    }

    @Test("Default 10-second segments plan a complete 75-minute six-channel render")
    func defaultLongFormPlanning() async throws {
        let fixture = try await Self.fixture(targets: [2, 2, 2], label: "default-long-form")
        let map = try fixture.model.timeMap(revision: 1, in: fixture.episodeID)
        let group = try #require(map.groups.first(where: { $0.group == fixture.groups[1] }))
        let participants = try fixture.sources.filter { $0.id != fixture.id("ref") }.map { source in
            let key = SourceProbe.key(source: source.id, token: try PipelineFixture.registration(source.id, source.url).token)
            return GroupRenderJob.Participant(source: source, facts: try SourceFacts.decode(#require(fixture.store.payload(for: key))))
        }
        let version = try #require(fixture.model.episode(fixture.episodeID)?.alignment?.map(revision: 1))
        let reference = MapRevisionReference(episode: fixture.episodeID, revision: 1)
        let identity = try fixture.pipeline.mapIdentity(
            revision: reference, version: version, map: map, registered: await fixture.coordinator.inputs.sources
        )
        let config = AlignmentPipelineConfiguration()
        let rate = 48_000
        let job = GroupRenderJob(
            episode: fixture.episodeID, revision: reference, identity: identity, map: group,
            nominalOutputRate: try NominalRate(Int64(rate)), participants: participants,
            outputFrames: 0 ..< Int64(75 * 60 * rate),
            segmentFrames: Int64(config.renderSegmentSeconds * rate), recipeBaseName: config.renderRecipeName
        )
        #expect(config.renderSegmentSeconds == 10)
        #expect(job.segmentIndices.count == 450)
        #expect(job.segmentIndices.count * job.channels.count == 2700)
        #expect(job.frames(ofSegment: job.segmentIndices.upperBound).upperBound == job.outputFrames.upperBound)
        let bytes = try job.admissionBytes(chunkFrames: 16_384, recipe: .m2Candidate, concurrency: config.concurrency)
        #expect(bytes <= config.analysisMemoryBudgetBytes)
    }

    @Test("The checked episode-wide result guard still refuses excessive one-second segments")
    func longFormResultGuard() async throws {
        let config = AlignmentPipelineConfiguration(
            targetExcerptSeconds: 10, searchDeviationSeconds: 2, renderSegmentSeconds: 1
        )
        let fixture = try await Self.fixture(
            configuration: config, targets: [2, 2, 2], seconds: 75 * 60, label: "long-form-result-guard"
        )
        let opens = fixture.content.total.opens
        do {
            _ = try await fixture.render()
            Issue.record("the 4096-result guard must refuse before opening a cursor")
        } catch let refusal as AlignedAssetRefusal {
            guard case let .renderEnvelope(reason) = refusal else {
                Issue.record("expected a typed result-count refusal, got \(refusal)")
                return
            }
            #expect(reason.contains("4096"))
        }
        #expect(fixture.content.total.opens == opens)
    }

    @Test("Simultaneous cold-cache adoption across coordinators opens no render cursors")
    func cacheFanOut() async throws {
        let config = AlignmentPipelineConfiguration(
            targetExcerptSeconds: 10, searchDeviationSeconds: 2, renderSegmentSeconds: 10
        )
        let fixture = try await Self.fixture(configuration: config, targets: [4, 3], seconds: 20, label: "cache-fan-out")
        let initial = try await fixture.render()
        #expect(initial.isComplete)
        let opens = fixture.content.total.opens
        await fixture.coordinator.acceptMap(MapRevisionReference(episode: fixture.episodeID, revision: 2))
        try await fixture.pipeline.activate(model: fixture.model, episode: fixture.episodeID)
        let restored = try await fixture.render()
        #expect(restored.isComplete)
        #expect(restored.groups.allSatisfy { $0.segmentsReused == $0.segments })
        #expect(fixture.content.total.opens == opens)
        var pipelines: [AlignmentPipeline] = []
        for _ in 0 ..< 3 {
            let coordinator = DerivedJobCoordinator(store: fixture.store)
            for source in fixture.sources {
                await coordinator.updateSource(try PipelineFixture.registration(source.id, source.url))
            }
            let pipeline = AlignmentPipeline(coordinator: coordinator, decoder: fixture.decoder, configuration: config)
            try await pipeline.activate(model: fixture.model, episode: fixture.episodeID)
            pipelines.append(pipeline)
        }
        let reports = await boundedMap(pipelines, limit: 3) { pipeline -> Result<AlignedAssetReport, any Error> in
            do {
                return .success(try await pipeline.renderAlignedAssets(
                    model: fixture.model, episode: fixture.episodeID,
                    sources: fixture.sources, authorizations: fixture.authorizations
                ))
            } catch {
                return .failure(error)
            }
        }
        for result in reports {
            let report = try result.get()
            #expect(report.isComplete)
            #expect(report.groups.allSatisfy { $0.segmentsReused == $0.segments && $0.segmentsRendered == 0 })
        }
        #expect(fixture.content.total.opens == opens)
        for pipeline in pipelines { #expect(await pipeline.gate.snapshot.activeBytes == 0) }
    }
}
