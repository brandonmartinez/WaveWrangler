import Foundation
import Testing
import WWCore
import WWDerived
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Adaptive source-local analysis integration", .serialized)
struct AdaptiveAnalysisTests {
    static func quietFixture(nativeAudio: Bool = false, otherChannelActive: Bool = false) async throws -> (PipelineFixture, SpeakerID) {
        let quiet = Signal.quietScene(seed: 132, offset: 0.83, stepAt: 48, stepBy: 0.04)
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "ref", seconds: 96,
                signal: .quietScene(seed: 132), sampleRate: 8000)]),
            .init(name: "Software backup", sources: [
                .init(name: "backup", channels: 2, seconds: 96, signal: quiet,
                    channelSignals: otherChannelActive ? [.scene(seed: 881), quiet] : nil, sampleRate: 8000),
                .init(name: "other file", seconds: 96, signal: .silence, sampleRate: 8000),
            ]),
        ], nativeAudio: nativeAudio)
        let speaker = SpeakerID()
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(speakerID: speaker,
                primary: ChannelReference(sourceID: fixture.id("ref"), statedChannel: 0),
                backups: [ChannelReference(sourceID: fixture.id("backup"), statedChannel: 1)])
        ]
        return (fixture, speaker)
    }

    static func fixture(_ signal: Signal = .scene(seed: 132, offset: 0.83, stepAt: 48, stepBy: 0.02),
                        nativeAudio: Bool = false, referenceChannels: Int = 2) async throws -> (PipelineFixture, SpeakerID) {
        let fixture = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "ref", channels: referenceChannels, seconds: 96,
                signal: .scene(seed: 132), sampleRate: 8000)]),
            .init(name: "Software backup", sources: [
                .init(name: "backup", channels: 2, seconds: 96, signal: signal, sampleRate: 8000),
                .init(name: "other file", seconds: 96, signal: .silence, sampleRate: 8000),
            ]),
        ], nativeAudio: nativeAudio)
        let speaker = SpeakerID()
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(speakerID: speaker,
                primary: ChannelReference(sourceID: fixture.id("ref"), statedChannel: 0),
                backups: [ChannelReference(sourceID: fixture.id("backup"), statedChannel: 1)])
        ]
        return (fixture, speaker)
    }

    static func run(
        _ fixture: PipelineFixture, _ speaker: SpeakerID,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> AdaptiveAnalysisRecord {
        try await fixture.pipeline.analyzeAdaptiveSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[1], speaker: speaker,
            referenceSource: fixture.id("ref"), targetSource: fixture.id("backup"), progress: progress
        )
    }

    @Test func changingDelaySupportsSeparateRunsWithoutChangingAnyChannelOrSiblingFile() async throws {
        let (fixture, speaker) = try await Self.fixture()
        let before = fixture.model
        let progress = Box<[Double]>([])
        let report = try await Self.run(fixture, speaker) { value in progress.update { $0.append(value) } }
        #expect(report.version == 14 && report.estimator == "ww-adaptive-align/14")
        #expect(report.analysisKey?.asset.revision == 14)
        #expect(report.analysisKey?.recipe?.name.contains("recovery=ww-anchor-guided-timing/1") == true)
        #expect(report.analysisKey?.recipe?.name.contains("quiet=ww-quiet-transition/1-all-target-channels") == true)
        #expect(report.analysisKey?.recipe?.name.contains("spectral=600Hz-complete-grid-broad-mid.6-lag-veto") == true)
        #expect(report.analysisKey?.recipe?.name.contains("short=1s-three-quarter.6-canonical-half.6") == true)
        #expect(report.analysisKey?.recipe?.name.contains("independence=earliest-finish") == true)
        #expect(report.analysisKey?.recipe?.name.contains("bounds=independent-or-local") == true)
        #expect(report.analysisKey?.recipe?.name.contains("shared-quiet=rms1e-4-rel30db-peak20db") == true)
        #expect(report.analysisKey?.recipe?.name.contains("support=local-before-ordinary") == true)
        #expect(report.analysisKey?.recipe?.name.contains("fit=bounded-affine-feasibility") == true)
        #expect(report.refusal == nil)
        #expect(report.timing.regions.count >= 2)
        #expect(report.timing.regions.contains { $0.sourceEnd < 48 })
        #expect(report.timing.regions.contains { $0.sourceStart > 48 })
        for region in report.timing.regions {
            for time in [region.sourceStart, (region.sourceStart + region.sourceEnd) / 2] {
                let truth = time + 0.83 + (time >= 48 ? 0.02 : 0)
                #expect(abs(try #require(report.alignedTime(at: time)) - truth) < 0.001)
            }
        }
        #expect(report.alignedTime(at: 48) == nil, "a transition window may not define a correction")
        #expect(report.target.source == fixture.id("backup"))
        #expect(report.target.channelCount == 2)
        #expect(fixture.model == before, "all channels and every sibling file stay unchanged during review")
        #expect(fixture.content.record(fixture.url("other file")).decodedFrames == 0)
        #expect(await fixture.coordinator.inputs.acceptedMaps.isEmpty)
        #expect(fixture.content.total.readsOnMainThread == 0)
        #expect(await fixture.pipeline.gate.snapshot.peakBytes <= fixture.configuration.analysisMemoryBudgetBytes)
        #expect(progress.value.first == 0 && progress.value.last == 1)
        #expect(zip(progress.value, progress.value.dropFirst()).allSatisfy { $0 <= $1 })
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func legacyWindowRecordsDoNotAcquireSpectralProofOnDecode() throws {
        let json = """
        {"index":0,"groupClockCenter":10,"status":"eligible","peakScore":0.9,
         "secondPeakScore":0.1,"periodicityScore":0,"offsetSeconds":-0.2}
        """
        let window = try JSONDecoder().decode(WindowRecord.self, from: Data(json.utf8))
        #expect(window.spectralWitness == nil)
        #expect(try JSONDecoder().decode(WindowRecord.self, from: JSONEncoder().encode(window)) == window)
    }

    @Test func cancellationDuringAnchorRecoveryPublishesNothingAndClosesReaders() async throws {
        let (fixture, speaker) = try await Self.fixture()
        let armed = Box(false), fired = Box(false)
        let slot = DerivedSlot("adaptive/\(fixture.id("backup"))")
        let coordinator = fixture.coordinator
        await #expect(throws: AlignmentWorkFailure.canceled) {
            try await Self.run(fixture, speaker) { progress in
                guard progress >= 0.94, !armed.update({ let old = $0; $0 = true; return old }) else { return }
                fixture.content.setOnRead { _, _ in
                    guard !fired.update({ let old = $0; $0 = true; return old }) else { return }
                    cancelSlotDuringRead(coordinator, slot)
                }
            }
        }
        #expect(fired.value)
        #expect(await coordinator.readyPayload(for: slot) == nil)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func longSharedQuietAddsSeparateContinuityButAnActiveOtherChannelVetoesIt() async throws {
        for active in [false, true] {
            let (fixture, speaker) = try await Self.quietFixture(otherChannelActive: active)
            let report = try await Self.run(fixture, speaker)
            #expect(report.refusal == nil)
            #expect(report.timing.regions.count >= 2)
            if active {
                #expect(report.timing.quietTransitions == nil && report.timing.quietSeconds == 0)
            } else {
                #expect(report.timing.quietSeconds > 30)
                #expect(report.timing.quietTransitions?.allSatisfy { $0.target.checkedChannels == 2 } == true)
            }
            #expect(fixture.model.episodes[0].alignment == nil)
            #expect(fixture.content.record(fixture.url("other file")).decodedFrames == 0)
            await ConcurrencyTests.expectQuiescent(fixture)
        }
    }

    @Test func cancellationDuringQuietVerificationPublishesNothingAndClosesReaders() async throws {
        let (fixture, speaker) = try await Self.quietFixture()
        let armed = Box(false), fired = Box(false)
        let slot = DerivedSlot("adaptive/\(fixture.id("backup"))")
        let coordinator = fixture.coordinator
        await #expect(throws: AlignmentWorkFailure.canceled) {
            try await Self.run(fixture, speaker) { progress in
                guard progress >= 0.86, !armed.update({ let old = $0; $0 = true; return old }) else { return }
                fixture.content.setOnRead { _, _ in
                    guard !fired.update({ let old = $0; $0 = true; return old }) else { return }
                    cancelSlotDuringRead(coordinator, slot)
                }
            }
        }
        #expect(fired.value)
        #expect(await coordinator.readyPayload(for: slot) == nil)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func referenceChangingAfterItsQuietPassIsStillRejectedBeforePublication() async throws {
        let (fixture, speaker) = try await Self.quietFixture()
        let armed = Box(false), changed = Box(false)
        let slot = DerivedSlot("adaptive/\(fixture.id("backup"))")
        await #expect(throws: AlignmentWorkFailure.self) {
            try await Self.run(fixture, speaker) { progress in
                guard progress > 0.91, !armed.update({ let old = $0; $0 = true; return old }) else { return }
                fixture.content.setOnRead { path, _ in
                    guard path == ProceduralContentIO.path(fixture.url("backup")),
                          !changed.update({ let old = $0; $0 = true; return old }) else { return }
                    do {
                        let handle = try FileHandle(forWritingTo: fixture.url("ref"))
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data([0]))
                        try handle.close()
                    } catch {
                        Issue.record("Failed to mutate synthetic reference fixture: \(error)")
                    }
                }
            }
        }
        #expect(changed.value)
        #expect(await fixture.coordinator.readyPayload(for: slot) == nil)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func weakPeriodicAndUnrelatedSignalsNeverProduceAnAdaptiveCurve() async throws {
        for signal: Signal in [.silence, .sine(hz: 440), .scene(seed: 881), .echo(seed: 132, delay: 1.2)] {
            let (fixture, speaker) = try await Self.fixture(signal)
            let report = try await Self.run(fixture, speaker)
            #expect(report.timing.regions.isEmpty)
            #expect(report.refusal != nil)
            #expect(fixture.model.episodes[0].alignment == nil)
            await ConcurrencyTests.expectQuiescent(fixture)
        }
    }

    @Test func adaptiveEvidenceProjectsThroughAnAcceptedReferenceWithoutRebasingTheTimeline() async throws {
        let (fixture, speaker) = try await Self.fixture(.scene(seed: 132, offset: 0.83))
        let manual = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: fixture.authorizations
        )
        let accepted = try await fixture.acceptAndActivate(manual, [:])
        let before = fixture.model
        let report = try await Self.run(fixture, speaker)
        #expect(!report.timing.regions.isEmpty)
        #expect(report.referenceRevision == accepted.revision.revision)
        #expect(fixture.model == before)
        let key = try #require(await fixture.coordinator.state(of: DerivedSlot("adaptive/\(fixture.id("backup"))")).key)
        let staleMap = try await fixture.pipeline.reviseAcceptedMap(
            model: fixture.model, episode: fixture.episodeID,
            decisions: [fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 100)]
        )
        try await fixture.pipeline.activate(staleMap)
        #expect(await fixture.coordinator.staleReasons(for: key).contains(.mapChanged(fixture.episodeID)))
    }

    @Test func referencePreferenceRanksStrongSourcesButDoesNotMoveAnAcceptedTimeline() async throws {
        let (fixture, speaker) = try await Self.fixture()
        fixture.model.episodes[0].recorderGroups[1].preferredAlignmentReference = true
        let first = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: fixture.authorizations
        )
        #expect(first.plan.reference?.source == fixture.id("backup"))
        let accepted = try await fixture.acceptAndActivate(first, [
            fixture.epochs[0]: .numeric(ppm: 0, offsetMilliseconds: 0)
        ])
        fixture.model.episodes[0].recorderGroups[0].preferredAlignmentReference = true
        fixture.model.episodes[0].recorderGroups[1].preferredAlignmentReference = nil
        let next = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: fixture.authorizations
        )
        #expect(next.plan.reference?.source == fixture.id("backup"))
        #expect(next.referenceRevision == accepted.revision.revision)
        #expect(fixture.model.episodes[0].assignment(for: speaker)?.primary?.sourceID == fixture.id("ref"))
    }

    @Test func cancellationDuringDenseDecodeClosesReadersAndPublishesNoAdaptiveResult() async throws {
        let (fixture, speaker) = try await Self.fixture()
        _ = try await fixture.pipeline.analyzeSpeaker(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources,
            authorizations: fixture.authorizations, targetEpoch: fixture.epochs[1], speaker: speaker
        )
        let slot = DerivedSlot("adaptive/\(fixture.id("backup"))")
        let coordinator = fixture.coordinator
        let fired = Box(false)
        fixture.content.setOnRead { _, _ in
            guard fired.update({ let first = !$0; $0 = true; return first }) else { return }
            cancelSlotDuringRead(coordinator, slot)
        }
        await #expect(throws: AlignmentWorkFailure.canceled) { try await Self.run(fixture, speaker) }
        #expect(fired.value)
        #expect(await coordinator.readyPayload(for: slot) == nil)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func changingAnAcceptedMapsSiblingSourceAtPublicationDiscardsAdaptiveEvidence() async throws {
        let (fixture, speaker) = try await Self.fixture()
        let manual = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: fixture.authorizations
        )
        _ = try await fixture.acceptAndActivate(manual, [:])
        let coordinator = fixture.coordinator, sibling = fixture.id("other file")
        let slot = DerivedSlot("adaptive/\(fixture.id("backup"))")
        let fired = Box(false)
        fixture.script.set { committing, _ in
            guard committing == slot else { return }
            fired.value = true
            await coordinator.updateSource(SourceRevision(source: sibling, token: "changed-at-publication"))
        }
        await #expect(throws: AlignmentWorkFailure.self) { try await Self.run(fixture, speaker) }
        #expect(fired.value)
        #expect(await coordinator.readyPayload(for: slot) == nil)
        await ConcurrencyTests.expectQuiescent(fixture)
    }

    @Test func preferredAlreadyTimedBackupOutranksSpeakerPrimaryWithoutRebasing() async throws {
        let fixture = try await PipelineFixture([
            .init(name: "Original", sources: [.init(name: "original", seconds: 20, signal: .silence)]),
            .init(name: "Strong alternative", sources: [.init(name: "strong", seconds: 20, signal: .silence)]),
            .init(name: "Backup", sources: [.init(name: "target", seconds: 20, signal: .silence)]),
        ])
        let speaker = SpeakerID()
        fixture.model.episodes[0].speakerAssignments = [
            SpeakerAssignment(speakerID: speaker,
                primary: ChannelReference(sourceID: fixture.id("original"), statedChannel: 0),
                backups: [ChannelReference(sourceID: fixture.id("strong"), statedChannel: 0),
                          ChannelReference(sourceID: fixture.id("target"), statedChannel: 0)])
        ]
        let initial = try await fixture.pipeline.prepareManual(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources, authorizations: fixture.authorizations
        )
        _ = try await fixture.acceptAndActivate(initial, [fixture.epochs[1]: .numeric(ppm: 0, offsetMilliseconds: 0)])
        fixture.model.episodes[0].recorderGroups[1].preferredAlignmentReference = true
        let snapshot = try #require(await fixture.pipeline.inspect(
            model: fixture.model, episode: fixture.episodeID, sources: fixture.sources
        ))
        #expect(snapshot.speakerMatches[fixture.epochs[2]]?.first?.reference.source == fixture.id("strong"))
        #expect(snapshot.plan.reference?.source == fixture.id("original"))
        #expect(fixture.content.total.decodedFrames == 0)
    }
}
