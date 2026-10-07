import Foundation
import Testing
import WWAlignEstimate
import WWCore
import WWDecode
@testable import WWDerived
import WWPersistence
import WWRender
import WWTimeMap
@testable import WWAlignPipeline

/// Relative RMS error of `samples` (output frames from `firstFrame` at `rate`) against `expected(t)`, over
/// the output times inside `interval`. `nil` when no sample falls inside it.
func relativeError(_ samples: [Float], firstFrame: Int64, rate: Int, interval: ClosedRange<Double>, expected: (Double) -> Float) -> (error: Double, count: Int)? {
    var signal = 0.0
    var error = 0.0
    var count = 0
    for (i, sample) in samples.enumerated() {
        let t = Double(firstFrame + Int64(i)) / Double(rate)
        guard interval.contains(t) else { continue }
        let e = Double(expected(t))
        signal += e * e
        error += (Double(sample) - e) * (Double(sample) - e)
        count += 1
    }
    guard count > 0, signal > 0 else { return nil }
    return ((error / signal).squareRoot(), count)
}

/// The two-recorder synthetic episode: `ref` hears the scene on the timeline clock; `tgt` runs 100 ppm fast
/// and starts 1.25 s into the scene (aligned = 1.0001·source + 1.25).
enum TwoRecorder {
    static let seed: UInt64 = 0xA11C_E5ED
    static let rate = 1.0001
    static let offset = 1.25

    static func groups(targetSignal: Signal? = nil, referenceSeconds: Double = 30, targetSeconds: Double = 24, target: (inout SourceSpec) -> Void = { _ in }) -> [GroupSpec] {
        var targetSpec = SourceSpec(name: "tgt", seconds: targetSeconds, signal: targetSignal ?? .scene(seed: seed, rate: rate, offset: offset))
        target(&targetSpec)
        return [
            GroupSpec(name: "Reference recorder", sources: [SourceSpec(name: "ref", seconds: referenceSeconds, signal: .scene(seed: seed))]),
            GroupSpec(name: "Field recorder", sources: [targetSpec]),
        ]
    }
}

@Suite("End to end: decode → propose → accept → render → invalidate")
struct EndToEndTests {
    @Test("A synthetic episode is proposed, accepted, rendered, re-timed and re-rendered; nothing on the main thread")
    @MainActor
    func endToEnd() async throws {
        let fixture = try await PipelineFixture(TwoRecorder.groups())
        let ref = fixture.id("ref")
        let tgt = fixture.id("tgt")
        let (referenceEpoch, targetEpoch) = (fixture.epochs[0], fixture.epochs[1])

        // Analyse.
        let report = try await fixture.analyse(preferredReference: "ref")
        #expect(report.plan.reference?.source == ref)
        #expect(report.sourceFailures.isEmpty)
        #expect(report.epochFailures.isEmpty)
        #expect(report.facts[tgt]?.frameCount == Int64(24 * 48_000))
        #expect(report.facts[tgt]?.channelCount == 2)
        let analysis = try #require(report.analyses[targetEpoch])
        #expect(analysis.outcome == .published(analysis.key))
        // Keyed by every M2-C5 component the analysis depends on.
        #expect(analysis.key.asset == AlignmentAssetKinds.analysis)
        #expect(Set(analysis.key.sources.map(\.source)) == [ref, tgt])
        #expect(analysis.key.sources.allSatisfy { $0.token.hasPrefix("metadata:") })
        #expect(analysis.key.format == .current)
        #expect(analysis.key.epoch == targetEpoch)
        #expect(analysis.key.occurrence == alignmentOccurrenceID(for: tgt))
        #expect(analysis.key.recipe?.name.contains(AlignmentAssetKinds.estimatorIdentifier) == true)
        #expect(analysis.key.map == nil)

        let states = await fixture.states(report)
        #expect(states[referenceEpoch]?.status == .reference)
        let proposed = try #require(states[targetEpoch])
        let proposal = try #require(proposed.status.proposal)
        #expect(proposed.remedies == [.acceptAsManual, .reject, .editNumerically, .placeAnchors, .audition])
        #expect(abs(proposal.ppm - 100) < 25, "ppm \(proposal.ppm)")
        #expect(abs(proposal.segment.alignedOffset.approximateDouble - TwoRecorder.offset) < 0.002, "offset \(proposal.segment.alignedOffset.approximateDouble)")
        #expect(proposal.acousticResidualP95Milliseconds < 1)
        let record = try #require(proposed.analysis)
        #expect(record.abstention == nil)
        #expect(record.windows.count >= 5)
        #expect(record.target.excerptEndFrame - record.target.excerptStartFrame == 20 * 48_000)

        // Accept → a document revision; the coordinator is untouched until activation.
        let accepted = try await fixture.pipeline.accept(model: fixture.model, episode: fixture.episodeID, report: report, decisions: [targetEpoch: .acceptProposal(note: "looks right")])
        #expect(accepted.revision == MapRevisionReference(episode: fixture.episodeID, revision: 1))
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == nil)
        fixture.model = accepted.model
        await #expect(throws: AlignedAssetRefusal.acceptedMapNotActive(document: 1, coordinator: nil)) { try await fixture.render() }
        let targetMapping = try #require(accepted.map.groups.flatMap(\.epochs).first { $0.epoch == targetEpoch }?.mapping)
        guard case let .mapped(_, provenance) = targetMapping, case let .manual(correction) = provenance else {
            Issue.record("expected a manual mapping, got \(targetMapping)")
            return
        }
        #expect(correction.basis == .acceptedAcousticProposal)
        try await fixture.pipeline.activate(accepted)
        #expect(await fixture.coordinator.inputs.acceptedMaps[fixture.episodeID] == 1)
        let acceptedStates = await fixture.states(report)
        #expect(acceptedStates[targetEpoch]?.status == .manual(.acceptedAcousticProposal, revision: 1))
        #expect(acceptedStates[targetEpoch]?.remedies.contains(.revertToProposal) == true)

        // Render revision 1.
        let opensBeforeRender = fixture.content.total.opens
        let first = try await fixture.render()
        #expect(first.isComplete)
        #expect(first.notRendered.isEmpty)
        #expect(first.outputRate == 48_000)
        #expect(first.groups.count == 2)
        #expect(fixture.content.total.opens == opensBeforeRender + 2, "one cursor per source for the whole group render")
        let firstSegments = try alignedSegments(first, store: fixture.store)
        try checkCoverage(first, firstSegments, fixture: fixture, revision: 1)
        // The reference group is identity on the timeline.
        for entry in firstSegments where entry.segment.header.source == ref {
            let c = entry.segment.header.decodedChannel
            if let check = relativeError(entry.segment.samples, firstFrame: entry.segment.header.firstOutputFrame, rate: 48_000, interval: 0.2 ... 29.8, expected: { channelGain(c) * Signal.scene(TwoRecorder.seed, $0) }) {
                #expect(check.error < 1e-3, "reference segment \(entry.segment.header.segmentIndex) ch\(c): \(check.error)")
            }
        }

        // Re-time numerically (the truth) → revision 2, derived from 1. Revision-1 assets go stale.
        let retimed = try await fixture.acceptAndActivate(report, [targetEpoch: .numeric(ppm: 100, offsetMilliseconds: 1250, note: "measured")])
        #expect(retimed.revision.revision == 2)
        #expect(fixture.model.episode(fixture.episodeID)?.alignment?.acceptedMap?.derivedFrom == 1)
        for result in first.groups.flatMap({ $0.results }) {
            #expect(await fixture.coordinator.staleReasons(for: result.key).contains(.mapChanged(fixture.episodeID)))
        }
        #expect(await fixture.coordinator.staleReasons(for: analysis.key).isEmpty, "a map change does not stale the analysis")
        #expect(await fixture.states(report)[targetEpoch]?.status == .manual(.numericEntry, revision: 2))

        let second = try await fixture.render()
        #expect(second.isComplete)
        #expect(second.revision.revision == 2)
        #expect(second.groups.allSatisfy { $0.segmentsRendered == $0.segments && $0.segmentsReused == 0 })
        let secondSegments = try alignedSegments(second, store: fixture.store)
        try checkCoverage(second, secondSegments, fixture: fixture, revision: 2)
        let end = TwoRecorder.rate * 24 + TwoRecorder.offset
        var checked = 0
        for entry in secondSegments where entry.segment.header.source == tgt {
            let c = entry.segment.header.decodedChannel
            if let check = relativeError(entry.segment.samples, firstFrame: entry.segment.header.firstOutputFrame, rate: 48_000, interval: (TwoRecorder.offset + 0.2) ... (end - 0.2), expected: { channelGain(c) * Signal.scene(TwoRecorder.seed, $0) }) {
                #expect(check.error < 0.02, "target segment \(entry.segment.header.segmentIndex) ch\(c): \(check.error)")
                checked += check.count
            }
        }
        #expect(checked > 2 * 20 * 48_000)

        // Rendering the same revision again reuses everything and opens nothing.
        let opensBeforeReuse = fixture.content.total.opens
        let third = try await fixture.render()
        #expect(third.isComplete)
        #expect(third.groups.allSatisfy { $0.segmentsReused == $0.segments && $0.segmentsRendered == 0 })
        #expect(fixture.content.total.opens == opensBeforeReuse)

        // Content was only ever read off the main thread, and every reader was closed.
        #expect(fixture.content.total.readsOnMainThread == 0)
        #expect(fixture.content.openReaders == 0)
        #expect(fixture.content.total.opens == fixture.content.total.closes)
        #expect(fixture.content.peakOpenReaders <= AlignmentPipelineConfiguration.maximumConcurrency * 2)
        let gate = await fixture.pipeline.gate.snapshot
        #expect(gate.active == 0 && gate.activeBytes == 0 && gate.waiting == 0)
        #expect(gate.peakActive <= fixture.pipeline.configuration.concurrency)
    }

    /// Every channel of every placed source has contiguous segments covering its group's output range,
    /// each tagged with the map revision and the renderer/recipe/asset versions.
    func checkCoverage(_ report: AlignedAssetReport, _ segments: [(key: DerivedAssetKey, segment: AlignedAudioSegment)], fixture: PipelineFixture, revision: Int) throws {
        for group in report.groups {
            #expect(group.failure == nil)
            #expect(group.results.allSatisfy { $0.isAvailable })
            let inGroup = segments.filter { $0.segment.header.group == group.group }
            let channels = Set(inGroup.map { "\($0.segment.header.source)/\($0.segment.header.decodedChannel)" })
            #expect(channels.count == 2)
            for channel in channels {
                let ordered = inGroup.filter { "\($0.segment.header.source)/\($0.segment.header.decodedChannel)" == channel }.sorted { $0.segment.header.firstOutputFrame < $1.segment.header.firstOutputFrame }
                var next = group.outputFrames.lowerBound
                for entry in ordered {
                    let header = entry.segment.header
                    #expect(header.firstOutputFrame == next)
                    next += Int64(header.frameCount)
                    #expect(header.map == MapRevisionReference(episode: fixture.episodeID, revision: revision))
                    #expect(entry.key.map == header.map)
                    #expect(entry.key.channel == header.decodedChannel)
                    #expect(entry.key.asset == AlignmentAssetKinds.alignedAudio)
                    #expect(header.outputRate == 48_000)
                    #expect(header.rendererVersion == RenderVersions.renderer)
                    #expect(header.renderRecipeVersion == RenderRecipe.currentVersion)
                    #expect(header.outputAssetFormatVersion == RenderVersions.outputAssetFormat)
                    #expect(header.frameCount <= 2 * 48_000)
                }
                #expect(next == group.outputFrames.upperBound)
            }
        }
    }
}
