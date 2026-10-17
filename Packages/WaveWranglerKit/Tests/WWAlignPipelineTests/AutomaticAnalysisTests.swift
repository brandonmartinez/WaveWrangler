import Foundation
import Testing
import WWAlignEstimate
import WWCore
import WWTimeMap
@testable import WWDerived
@testable import WWAlignPipeline

@Suite("Automatic alignment integration", .serialized)
struct AutomaticAnalysisTests {
    @Test(arguments: [-1.0, 1.0])
    func processedChannelKeepsItsOriginalTimingAndPolarityUntilAcceptance(polarity: Double) async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [
                SourceSpec(name: "ref", channels: 1, seconds: 96, signal: .scene(seed: 990), sampleRate: 8000),
            ]),
            GroupSpec(name: "Target", sources: [
                SourceSpec(name: "tgt", channels: 1, seconds: 96,
                           signal: .processedScene(seed: 990, rate: 1.00018, offset: 0.83, polarity: polarity),
                           sampleRate: 8000),
            ]),
        ])
        let report = try await Self.run(fixture)
        let record = try #require(report.records[fixture.epochs[1]])
        let proposal = try #require(record.proposal, "\(String(describing: record.abstention)); \(record.windows)")
        for time in [record.coverage.declaredStart, record.coverage.declaredEnd] {
            #expect(abs(proposal.segment.rateRatio.approximateDouble * time + proposal.segment.alignedOffset.approximateDouble
                - (1.00018 * time + 0.83)) < 0.001)
        }
        #expect(record.refinementRatePPM?.isFinite == true)
        #expect(record.windows.filter { $0.status == "eligible" }.allSatisfy { $0.polarity == Int(polarity) })
        #expect(fixture.model.episodes[0].alignment == nil)
        #expect(fixture.content.total.readsOnMainThread == 0)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("Whole-track matching preserves selected channels and mixed nominal rates in seven-channel sources")
    func multichannelMixedRates() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [
                SourceSpec(name: "ref", channels: 7, seconds: 32, signal: .scene(seed: 561), sampleRate: 44_100),
            ]),
            GroupSpec(name: "Target", sources: [
                SourceSpec(name: "tgt", channels: 7, seconds: 32,
                           signal: .scene(seed: 561, rate: 0.99982, offset: 1.25), sampleRate: 48_000),
            ]),
        ])
        let speaker = SpeakerID()
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(speakerID: speaker,
                              primary: ChannelReference(sourceID: fixture.id("ref"), statedChannel: 6),
                              backups: [ChannelReference(sourceID: fixture.id("tgt"), statedChannel: 6)]),
        ]
        let report = try await fixture.pipeline.analyseSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[1], speaker: speaker
        )
        let record = try #require(report.records[fixture.epochs[1]])
        let proposal = try #require(record.proposal, "\(String(describing: record.abstention))")
        #expect(record.recipe.contains("channels=6,6"))
        for time in [record.coverage.declaredStart, record.coverage.declaredEnd] {
            #expect(abs(proposal.segment.rateRatio.approximateDouble * time + proposal.segment.alignedOffset.approximateDouble
                - (0.99982 * time + 1.25)) < 0.001)
        }
        #expect(fixture.content.total.readsOnMainThread == 0)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("Whole-channel fingerprints are reused across analyses and keyed by channel and revision")
    func fingerprintCache() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups())
        let report = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: fixture.authorizations
        )
        let facts = try #require(report.facts[fixture.id("ref")])
        let source = try #require(fixture.sources.first { $0.id == facts.source })
        let environment = fixture.pipeline.environment
        let first = try await environment.gate.withAdmission(bytes: 200 << 20) {
            try await FingerprintAnalysis.load(source: source, facts: facts, channel: 0, minimumRate: 8000, environment: environment)
        }
        let reads = fixture.content.total.decodedFrames
        #expect(reads == facts.frameCount, "the first index reads the complete channel exactly once")
        let cached = try await environment.gate.withAdmission(bytes: 200 << 20) {
            try await FingerprintAnalysis.load(source: source, facts: facts, channel: 0, minimumRate: 8000, environment: environment)
        }
        #expect(cached.bands == first.bands && cached.energy == first.energy)
        #expect(fixture.content.total.decodedFrames == reads, "unchanged index must not decode again")
        let other = try await environment.gate.withAdmission(bytes: 200 << 20) {
            try await FingerprintAnalysis.load(source: source, facts: facts, channel: 1, minimumRate: 8000, environment: environment)
        }
        #expect(fixture.content.total.decodedFrames == reads * 2)
        #expect(other.energy != first.energy, "selected-channel indexes must not alias")
        var changed = facts
        changed.revisionToken = "synthetic-new-revision"
        let changedFacts = changed
        await fixture.coordinator.updateSource(SourceRevision(source: source.id, token: changed.revisionToken))
        _ = try await environment.gate.withAdmission(bytes: 200 << 20) {
            try await FingerprintAnalysis.load(source: source, facts: changedFacts, channel: 0, minimumRate: 8000, environment: environment)
        }
        #expect(fixture.content.total.decodedFrames == reads * 3, "a new source revision rebuilds the index")
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("Source changes while an entire channel is being fingerprinted never publish an alignment")
    func fingerprintCurrency() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "fingerprint-currency")
        let path = ProceduralContentIO.path(fixture.url("ref"))
        let fired = Box(false)
        fixture.content.setOnRead { readPath, index in
            guard readPath == path, index == 2, fired.update({ let first = !$0; $0 = true; return first }) else { return }
            do { try fixture.rewrite("ref") } catch { Issue.record(error) }
        }
        let report = try await Self.run(fixture)
        #expect(fired.value)
        #expect(report.records.isEmpty)
        #expect(report.epochFailures[fixture.epochs[1]] != nil)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("Sources longer than the whole-track envelope are explicitly refused before decoding")
    func fingerprintDurationBound() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [SourceSpec(name: "ref", seconds: 7201, signal: .silence)]),
            GroupSpec(name: "Target", sources: [SourceSpec(name: "tgt", seconds: 7201, signal: .silence)]),
        ])
        let report = try await Self.run(fixture)
        guard case .estimator(.invalidParameter)? = report.epochFailures[fixture.epochs[1]] else {
            Issue.record("expected explicit duration-envelope failure")
            return
        }
        #expect(fixture.content.total.decodedFrames == 0)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    static func assign(_ fixture: PipelineFixture) -> SpeakerID {
        let speaker = SpeakerID()
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(
                speakerID: speaker, primary: ChannelReference(sourceID: fixture.id("ref"), statedChannel: 0),
                backups: [ChannelReference(sourceID: fixture.id("tgt"), statedChannel: 0)]
            ),
        ]
        return speaker
    }

    static func run(_ fixture: PipelineFixture) async throws -> AlignmentAnalysisReport {
        let speaker = assign(fixture)
        return try await fixture.pipeline.analyseSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[1], speaker: speaker
        )
    }

    @Test("New automatic recipes cannot reuse v1 analyses, and old analysis payloads are refused")
    func identitiesAndEvidence() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups())
        let manual = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: fixture.authorizations
        )
        var unit = AnalysisUnit(
            referenceChoice: try #require(manual.plan.reference), reference: fixture.sources[0],
            referenceFacts: try #require(manual.facts[fixture.id("ref")]),
            targetGroup: fixture.groups[1], targetEpoch: fixture.epochs[1], target: fixture.sources[1],
            targetFacts: try #require(manual.facts[fixture.id("tgt")]),
            configuration: fixture.configuration, chunkFrames: fixture.decoder.configuration.chunkFrames
        )
        let old = unit.key
        unit.automatic = true
        #expect(unit.key != old)
        #expect(unit.recipe.name.contains("est=ww-auto-align/4"))
        #expect(unit.recipe.name.contains("polarity-rate-sinc12"))
        #expect(!unit.recipe.name.contains("est=ww-align-estimate/1"))
        let report = try await Self.run(fixture)
        let record = try #require(report.records[fixture.epochs[1]])
        #expect(record.proposal != nil)
        #expect(record.estimator == "ww-auto-align/4")
        #expect(record.proposal?.provenance.estimator == record.estimator)
        #expect(record.coarseWindows?.isEmpty == false)
        #expect((record.automaticAttempts?.count ?? 0) >= record.coverage.windowCount * 3)
        #expect((record.automaticAttempts?.count ?? 0) <= record.coverage.windowCount * 9)
        #expect(record.fingerprintSeconds?.count == 2)
        #expect(record.windows.count == record.coverage.windowCount)
        #expect(record.windows.allSatisfy { $0.method == "speech-ncc+phat-rate-polarity" })
        #expect(record.windows.allSatisfy { $0.polarity == 1 })
        #expect(record.refinementRatePPM != nil)
        #expect(try EpochAnalysisRecord.decode(EpochAnalysisRecord.encode(record)) == record)
        for version in [2, 3] {
            var oldRecord = record
            oldRecord.recordVersion = version
            #expect(throws: AnalysisRecordError.unsupportedVersion(version)) {
                try EpochAnalysisRecord.decode(EpochAnalysisRecord.encode(oldRecord))
            }
        }
        #expect(fixture.model.episodes[0].alignment == nil, "a measurement never silently applies timing")
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("A primary low-coverage abstention is not rewritten as a physical gap")
    func primaryAbstentionSurvives() async throws {
        let fixture = try await PipelineFixture(
            TwoRecorder.groups(targetSignal: .gap(seed: TwoRecorder.seed, rate: TwoRecorder.rate,
                                                  offset: TwoRecorder.offset, start: 6, end: 19)),
            label: "primary-abstention"
        )
        let report = try await fixture.analyse(preferredReference: "ref")
        let record = try #require(report.records[fixture.epochs[1]])
        #expect(record.flags.contains("coverageGap"))
        #expect(record.proposal == nil)
        #expect(record.abstention?.abstentionReason == .silent)
        #expect(record.abstention?.detail.contains("windows eligible") == true)
        #expect(record.abstention?.detail.contains("declare an epoch boundary") == false)
    }

    @Test("Whole-track indexing is admitted before reading any audio")
    func clippedCoarseAdmission() async throws {
        let budget = 160 << 20
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [SourceSpec(name: "ref", seconds: 1800, signal: .scene(seed: 42))]),
            GroupSpec(name: "Target", sources: [SourceSpec(name: "tgt", seconds: 1800, signal: .scene(seed: 42))]),
        ], configuration: AlignmentPipelineConfiguration(analysisMemoryBudgetBytes: budget), label: "auto-retry-admission")
        let report = try await Self.run(fixture)
        guard case let .memoryBudget(requested, actualBudget)? = report.epochFailures[fixture.epochs[1]] else {
            Issue.record("expected explicit memory-budget refusal, got \(report.epochFailures)")
            return
        }
        #expect(actualBudget == budget && requested > budget)
        #expect(fixture.content.total.decodedFrames == 0, "refuse before reading any audio samples")
        #expect(report.records.isEmpty)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("Cancellation during automatic decoding closes cursors, releases admission and publishes nothing")
    func cancellation() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "auto-cancel")
        let sourcePath = ProceduralContentIO.path(fixture.url("tgt"))
        let fired = Box(false)
        let coordinator = fixture.coordinator
        let slot = PipelineSlots.analysis(fixture.epochs[1])
        fixture.content.setOnRead { path, index in
            guard path == sourcePath, index == 1, fired.update({ let first = !$0; $0 = true; return first }) else { return }
            cancelSlotDuringRead(coordinator, slot)
        }
        let report = try await Self.run(fixture)
        #expect(fired.value)
        #expect(report.epochFailures[fixture.epochs[1]] == .cancelled)
        #expect(report.records.isEmpty)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("A source revision changed at publication discards new automatic evidence")
    func staleAtPublish() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "auto-stale")
        let coordinator = fixture.coordinator
        let target = fixture.id("tgt")
        let slot = PipelineSlots.analysis(fixture.epochs[1])
        fixture.script.set { committing, _ in
            if committing == slot { await coordinator.updateSource(SourceRevision(source: target, token: "changed")) }
        }
        let report = try await Self.run(fixture)
        #expect(report.records.isEmpty)
        #expect(report.epochFailures[fixture.epochs[1]] == .staleInputs([.sourceChanged(target)]))
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("A source changed between sparse windows is refused by the gateway")
    func sparseCurrency() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups(), label: "auto-sparse-currency")
        let factsReport = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: fixture.authorizations
        )
        let facts = try #require(factsReport.facts[fixture.id("tgt")])
        let source = try #require(fixture.sources.first { $0.id == facts.source })
        let path = ProceduralContentIO.path(source.url)
        let changed = Box(false)
        fixture.content.setOnRead { readPath, _ in
            guard readPath == path, changed.update({ let first = !$0; $0 = true; return first }) else { return }
            do { try fixture.rewrite("tgt") } catch { Issue.record(error) }
        }
        await #expect(throws: (any Error).self) {
            try await AutomaticAnalysis.buffers(source, facts: facts, ranges: [0..<48_000, 96_000..<144_000],
                                                channel: 0, minimumRate: 8000, decoder: fixture.decoder)
        }
        #expect(changed.value)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("Sparse seeking and sequential streaming preserve identical filtered sample coordinates")
    func sparseDecodeCoordinates() async throws {
        let ranges: [Range<Int64>] = [13_317..<54_987, 155_555..<203_333, 207_123..<254_111]
        var outputs: [[[Float]]] = []
        var decodedFrames: [Int] = []
        for randomAccess in [false, true] {
            let fixture = try await PipelineFixture([
                GroupSpec(name: "Synthetic recorder", sources: [
                    SourceSpec(name: "ref", seconds: 6, signal: .scene(seed: 84), randomAccess: randomAccess),
                ]),
            ], label: "auto-sparse-coordinates")
            let report = try await fixture.pipeline.prepareManual(
                model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: fixture.authorizations
            )
            let facts = try #require(report.facts[fixture.id("ref")])
            outputs.append(try await AutomaticAnalysis.buffers(
                fixture.sources[0], facts: facts, ranges: ranges, channel: 0, minimumRate: 8000, decoder: fixture.decoder
            ))
            decodedFrames.append(Int(fixture.content.total.decodedFrames))
            await ConcurrencyTests.expectQuiescent(fixture)
        }
        #expect(outputs[0] == outputs[1], "filter context and fractional range origins must survive sparse seeks")
        #expect(outputs[0].map(\.count) == ranges.map { AnalysisDecimator.outputCount(frames: Int64($0.count), factor: 6) })
        #expect(decodedFrames[1] < decodedFrames[0], "a seekable cursor skips unrequested content")
    }
}

@Suite("Automatic alignment pipeline reliability", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["WW_ESTIMATOR_TESTS"] == "1", "serialized automatic pipeline pass"))
struct AutomaticPipelineReliabilityTests {
    @Test("Whole-track discovery finds an offset outside the old search hint without an anchor")
    func outsideOldSearchHint() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [
                SourceSpec(name: "ref", channels: 1, seconds: 420, signal: .scene(seed: 662), sampleRate: 8000, randomAccess: true),
            ]),
            GroupSpec(name: "Target", sources: [
                SourceSpec(name: "tgt", channels: 1, seconds: 420,
                           signal: .scene(seed: 662, rate: 1.00012, offset: -180), sampleRate: 8000, randomAccess: true),
            ]),
        ], configuration: AlignmentPipelineConfiguration(), label: "fingerprint-outside-hint")
        let report = try await AutomaticAnalysisTests.run(fixture)
        let record = try #require(report.records[fixture.epochs[1]])
        let proposal = try #require(record.proposal, "\(String(describing: record.abstention))")
        #expect(abs(proposal.segment.alignedOffset.approximateDouble + 180) < 0.001)
        #expect(abs(proposal.ppm - 120) < 1)
        #expect(record.searchDeviationSeconds == 120)
        #expect(fixture.model.episodes[0].alignment == nil)
    }

    @Test("Complete energy indexes bridge a long shared recorded pause, not asymmetric missing audio")
    func longSharedPause() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [
                SourceSpec(name: "ref", seconds: 160,
                           signal: .sharedSilence(seed: 663, rate: 1, offset: 0, start: 50, end: 85), sampleRate: 8000),
            ]),
            GroupSpec(name: "Target", sources: [
                SourceSpec(name: "tgt", seconds: 160,
                           signal: .sharedSilence(seed: 663, rate: 1.00008, offset: 0.5, start: 50, end: 85), sampleRate: 8000),
            ]),
        ], label: "fingerprint-long-pause")
        let report = try await AutomaticAnalysisTests.run(fixture)
        let record = try #require(report.records[fixture.epochs[1]])
        let proposal = try #require(record.proposal, "\(String(describing: record.abstention))")
        #expect(record.windows.contains { $0.method == "whole-track-silence" })
        #expect(abs(proposal.ppm - 80) < 1)
        #expect(proposal.acousticResidualMaxMilliseconds < 1)
    }

    @Test("A 75-minute selected-speaker match indexes both complete tracks with bounded memory")
    func longRecording() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [
                SourceSpec(name: "ref", channels: 1, seconds: 4500, signal: .scene(seed: 81), sampleRate: 8000, randomAccess: true),
            ]),
            GroupSpec(name: "Target", sources: [
                SourceSpec(name: "tgt", channels: 1, seconds: 4500,
                           signal: .scene(seed: 81, rate: 1.000145, offset: -38.617), sampleRate: 8000, randomAccess: true),
            ]),
        ], configuration: AlignmentPipelineConfiguration(), label: "auto-long")
        let sampler = MemorySampler()
        let report = try await AutomaticAnalysisTests.run(fixture)
        let peaks = sampler.stop()
        let record = try #require(report.records[fixture.epochs[1]])
        let proposal = try #require(record.proposal, "\(String(describing: record.abstention))")
        let errors = [record.coverage.declaredStart, 2250, record.coverage.declaredEnd].map {
            abs(proposal.segment.rateRatio.approximateDouble * $0 + proposal.segment.alignedOffset.approximateDouble
                - (1.000145 * $0 - 38.617)) * 1000
        }
        let gate = await fixture.pipeline.gate.snapshot
        print("AUTO-PIPELINE 75min truthErrorsMs=\(errors), ppm=\(proposal.ppm), decodedFrames=\(fixture.content.total.decodedFrames), admittedPeakBytes=\(gate.peakBytes), resident=\(peaks.resident), footprint=\(peaks.footprint)")
        #expect(errors.max()! < 1)
        #expect(abs(proposal.ppm - 145) < 0.5)
        let compensation = try #require(record.refinementRatePPM)
        #expect(abs(compensation - 145) < 30, "long-track coarse drift must reach the fine resampler")
        #expect(record.coverage.declaredEnd - record.coverage.declaredStart > 4400)
        #expect(record.coverage.eligibleSpanFraction >= 0.8)
        #expect(record.fingerprintSeconds == [4500, 4500])
        #expect(fixture.content.total.decodedFrames >= 8000 * 9000, "both whole tracks are indexed")
        #expect(fixture.content.total.decodedFrames < 8000 * 9500, "fine verification remains sparse after indexing")
        #expect(gate.peakBytes <= fixture.configuration.analysisMemoryBudgetBytes)
        #expect(peaks.resident < 768 << 20 && peaks.footprint < 768 << 20)
        #expect(fixture.content.total.readsOnMainThread == 0)
        #expect(fixture.content.peakOpenReaders <= fixture.configuration.concurrency, "header probes share the configured concurrency cap")
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test("True steps, asymmetric missing coverage and equal repeated solutions remain unsupported")
    func falsePositiveControls() async throws {
        let cases: [(String, Signal, Signal)] = [
            ("step", .scene(seed: 82), .scene(seed: 82, offset: 0.5, stepAt: 20, stepBy: 0.08)),
            ("missing", .scene(seed: 82), .gap(seed: 82, rate: 1, offset: 0.5, start: 10, end: 30)),
            ("repeated", .echo(seed: 82, delay: 1.2), .scene(seed: 82)),
            ("unrelated", .scene(seed: 82), .scene(seed: 982)),
            ("periodic", .sine(hz: 180), .sine(hz: 180)),
        ]
        for (name, reference, target) in cases {
            let fixture = try await PipelineFixture([
                GroupSpec(name: "Reference", sources: [SourceSpec(name: "ref", seconds: 42, signal: reference)]),
                GroupSpec(name: "Target", sources: [SourceSpec(name: "tgt", seconds: 42, signal: target)]),
            ], label: "auto-negative-\(name)")
            let report = try await AutomaticAnalysisTests.run(fixture)
            let record = try #require(report.records[fixture.epochs[1]], "\(name): \(report.epochFailures)")
            #expect(record.proposal == nil, "\(name) falsely proposed timing")
            #expect(record.abstention != nil)
            print("AUTO-NEGATIVE \(name): \(record.abstention?.reason ?? "missing")")
            if name == "step" {
                #expect(record.abstention?.abstentionReason == .discontinuous || record.abstention?.abstentionReason == .insufficientCoverage)
            }
            #expect(fixture.model.episodes[0].alignment == nil)
            await ConcurrencyTests.expectQuiescent(fixture)
        }
    }

    @Test("Matching recorded pauses remain reviewable without inventing a physical gap")
    func sharedPause() async throws {
        let fixture = try await PipelineFixture([
            GroupSpec(name: "Reference", sources: [
                SourceSpec(name: "ref", seconds: 42, signal: .sharedSilence(seed: 93, rate: 1, offset: 0, start: 14, end: 20)),
            ]),
            GroupSpec(name: "Target", sources: [
                SourceSpec(name: "tgt", seconds: 42, signal: .sharedSilence(seed: 93, rate: 1.00008, offset: 0.5, start: 14, end: 20)),
            ]),
        ], label: "auto-shared-pause")
        let report = try await AutomaticAnalysisTests.run(fixture)
        let record = try #require(report.records[fixture.epochs[1]])
        let proposal = try #require(record.proposal, "\(String(describing: record.abstention))")
        #expect(record.automaticAttempts?.contains { $0.status == "sharedSilence" } == true)
        #expect(abs(proposal.ppm - 80) < 5)
        #expect(proposal.acousticResidualMaxMilliseconds < 1)
        #expect(!record.flags.contains("discontinuity"))
        #expect(fixture.model.episodes[0].alignment == nil)
    }
}
