import Foundation
import Testing
import WWCore
@testable import WWDerived
import WWPersistence
import WWSources
import WWTimeMap

@Suite("Map history and applicability")
struct MapHistoryTests {
    let fixture = AlignmentFixture()

    @Test func recordsAppendOnlyRevisionsAndAcceptsOne() throws {
        let first = try fixture.map(guestOffset: 1)
        let second = try fixture.map(guestOffset: 2)
        var (model, r1) = try fixture.show.recordingMap(first, in: fixture.episodeID, recipe: RecipeReference(name: "manual", revision: 1))
        let original = model.episode(fixture.episodeID)?.alignment?.maps.first
        let (next, r2) = try model.recordingMap(second, in: fixture.episodeID, derivedFrom: r1.revision)
        model = try next.acceptingMap(revision: r2.revision, in: fixture.episodeID)

        #expect(r1 == MapRevisionReference(episode: fixture.episodeID, revision: 1))
        #expect(r2.revision == 2)
        let alignment = try #require(model.episode(fixture.episodeID)?.alignment)
        #expect(alignment.maps.first == original, "recording a revision never rewrites an earlier one")
        #expect(alignment.maps[1].derivedFrom == 1)
        #expect(alignment.acceptedRevision == 2)
        #expect(try model.timeMap(revision: 1, in: fixture.episodeID) == first)
        #expect(try model.timeMap(revision: 2, in: fixture.episodeID) == second)
        #expect(Set(alignment.maps[0].inputs.sources.map(\.sourceID)) == [fixture.host, fixture.guest])

        // Re-accepting an earlier revision changes only the pointer.
        let back = try model.acceptingMap(revision: 1, in: fixture.episodeID)
        #expect(back.episode(fixture.episodeID)?.alignment?.maps == alignment.maps)
        #expect(back.episode(fixture.episodeID)?.alignment?.acceptedRevision == 1)
        let cleared = try back.clearingAcceptedMap(in: fixture.episodeID)
        #expect(cleared.episode(fixture.episodeID)?.alignment?.maps == alignment.maps)
        #expect(cleared.episode(fixture.episodeID)?.alignment?.acceptedRevision == nil)
        #expect(back.episode(fixture.episodeID)?.alignment?.acceptedRevision == 1)
        let (restarted, r3) = try cleared.recordingMap(first, in: fixture.episodeID)
        #expect(r3.revision == 3)
        #expect(restarted.episode(fixture.episodeID)?.alignment?.maps.prefix(2) == alignment.maps.prefix(2))
        #expect(try restarted.acceptingMap(revision: r3.revision, in: fixture.episodeID)
            .episode(fixture.episodeID)?.alignment?.acceptedRevision == 3)

        // The recorded show round-trips through the strict show coder.
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(try coder.decode(try coder.encode(model, revision: 1)).payload == model)
    }

    @Test func refusesWithoutMutating() throws {
        let show = fixture.show
        let map = try fixture.map()
        #expect(throws: MapHistoryError.episodeNotFound(EpisodeID(UUID(uuid: UUID_NULL)))) {
            try show.recordingMap(map, in: EpisodeID(UUID(uuid: UUID_NULL)))
        }
        #expect(throws: MapHistoryError.inputsDoNotMatchPlacedSources) {
            try show.recordingMap(map, in: fixture.episodeID, inputs: [TimeMapSourceInput(sourceID: fixture.host)])
        }
        #expect(throws: MapHistoryError.mapNotFound(revision: 7)) {
            try show.recordingMap(map, in: fixture.episodeID, derivedFrom: 7)
        }
        #expect(throws: MapHistoryError.mapNotFound(revision: 1)) {
            try show.acceptingMap(revision: 1, in: fixture.episodeID)
        }
        #expect(show.episode(fixture.episodeID)?.alignment == nil)
    }

    @Test func alignmentResetRetiresAllActiveTimingAndWorkWithoutRewritingHistory() throws {
        let speaker = Speaker(name: "Synthetic")
        let correction = SourceTimingCorrection(
            source: fixture.guest, group: fixture.group, epoch: fixture.epoch, reference: fixture.host,
            sourceRate: 48_000, sourceFrames: 96_000, channelCount: 1,
            analysisDigest: String(repeating: "a", count: 64),
            processing: "ww-native-time-pitch-multichannel/1",
            segments: [.init(sourceStart: 0, sourceEnd: 2, alignedStart: 0.5, rateRatio: 1.0001)]
        )
        let (recorded, revision) = try fixture.show.recordingMap(
            fixture.map(guestOffset: 3), in: fixture.episodeID, sourceCorrections: [correction]
        )
        var original = try recorded.acceptingMap(revision: revision.revision, in: fixture.episodeID)
        original.speakers = [speaker]
        original.episodes[0].recorderGroups[0].preferredAlignmentReference = true
        original.episodes[0].workspace = .init(positionLocks: [.init(group: fixture.group, isLocked: true)])
        let transcript = SpeakerTranscript(
            speaker: speaker.id, primary: .init(sourceID: fixture.host, statedChannel: 0),
            sourceRate: 48_000, sourceIdentity: String(repeating: "b", count: 64),
            alignmentRevision: revision.revision, model: "synthetic",
            workingRange: nil, words: [.init(text: "um", sourceStartFrame: 48_000,
                sourceEndFrame: 60_000, alignedStart: 1, alignedEnd: 1.25)]
        )
        original.episodes[0].cleanup = EpisodeCleanup(
            workingRange: .init(alignmentRevision: revision.revision, tracksIn: 0.5, tracksOut: 9),
            transcripts: [transcript],
            manualCuts: [.init(alignmentRevision: revision.revision, startFrame: 240_000, endFrame: 288_000)]
        ).proposingFillers()
        let reset = try original.resettingAlignment(in: fixture.episodeID)
        let episode = try #require(reset.episode(fixture.episodeID))
        #expect(episode.alignment?.acceptedRevision == nil && episode.alignment?.acceptedMap == nil)
        #expect(episode.alignment?.maps == original.episodes[0].alignment?.maps)
        #expect(episode.cleanup?.transcripts.isEmpty == true && episode.cleanup?.workingRange == nil)
        #expect(episode.cleanup?.transcriptHistory == [transcript])
        #expect(episode.cleanup?.fillerReviews == original.episodes[0].cleanup?.fillerReviews)
        #expect(episode.cleanup?.manualCuts == original.episodes[0].cleanup?.manualCuts)
        #expect(episode.activeManualCuts.isEmpty)
        var expected = original
        expected.episodes[0].alignment?.acceptedRevision = nil
        expected.episodes[0].cleanup = try original.episodes[0].cleanup?.resettingForReplacementAlignment()
        #expect(reset == expected, "Grouping, reference, locks, assignments, sources and other metadata stay exact")
        #expect(try reset.resettingAlignment(in: fixture.episodeID) == reset)
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(try coder.decode(try coder.encode(reset, revision: 1)).payload == reset)
        let (next, nextRevision) = try reset.recordingMap(fixture.map(), in: fixture.episodeID)
        #expect(nextRevision.revision > revision.revision)
        #expect(try next.acceptingMap(revision: nextRevision.revision, in: fixture.episodeID)
            .episode(fixture.episodeID)?.activeManualCuts.isEmpty == true)
        #expect(original.episodes[0].alignment?.acceptedRevision == revision.revision)
    }

    @Test func alignmentResetRefusesAMissingEpisodeAndLeavesAnUnalignedShowAlone() throws {
        let missing = EpisodeID()
        let original = fixture.show
        #expect(throws: MapHistoryError.episodeNotFound(missing)) {
            try original.resettingAlignment(in: missing)
        }
        #expect(try original.resettingAlignment(in: fixture.episodeID) == original)
    }

    @Test func currentMapIsApplicable() throws {
        let (model, _) = try fixture.show.recordingMap(try fixture.map(), in: fixture.episodeID)
        let applicability = try #require(model.episode(fixture.episodeID)).applicability(ofMapRevision: 1)
        #expect(applicability.isCurrent)
    }

    @Test func removedSourceGroupOrEpochMakesTheMapStale() throws {
        let (model, _) = try fixture.show.recordingMap(try fixture.map(), in: fixture.episodeID)
        let episode = try #require(model.episode(fixture.episodeID))

        var withoutGuest = episode
        withoutGuest.sources.removeAll { $0.id == fixture.guest }
        #expect(try withoutGuest.applicability(ofMapRevision: 1).staleness == [.sourceMissing(fixture.guest)])

        var regrouped = episode
        let elsewhere = RecorderGroup(name: "Other")
        regrouped.recorderGroups.append(elsewhere)
        regrouped.sources[1].placement = SourcePlacement(recorderGroupID: elsewhere.id)
        #expect(try regrouped.applicability(ofMapRevision: 1).staleness == [.sourceRegrouped(fixture.guest, mapGroup: fixture.group, currentGroup: elsewhere.id)])

        var withoutEpoch = episode
        withoutEpoch.recorderGroups[0].epochs = []
        withoutEpoch.sources = withoutEpoch.sources.map { var s = $0; s.placement.epochID = nil; return s }
        #expect(try withoutEpoch.applicability(ofMapRevision: 1).staleness == [.epochMissing(fixture.epoch)])

        var withoutGroup = episode
        withoutGroup.recorderGroups = []
        withoutGroup.sources = withoutGroup.sources.map { var s = $0; s.placement = SourcePlacement(); return s }
        #expect(try withoutGroup.applicability(ofMapRevision: 1).staleness == [.recorderGroupMissing(fixture.group)])

        // Stale maps are still valid, openable documents.
        var staleShow = model
        staleShow.episodes[0] = withoutGroup
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        #expect(try coder.decode(try coder.encode(staleShow, revision: 1)).payload == staleShow)
    }
}

@Suite("Derived asset keys")
struct DerivedAssetKeyTests {
    let source = SourceID()
    let other = SourceID()

    @Test func metadataRevisionUsesVerifiedBaselineAcrossTimestampPrecisionNoise() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let recorded = FileSystemFingerprint(
            fileSize: .known(4_096), creationDate: .known(date),
            contentModificationDate: .known(date), fileIdentifier: .known(42),
            volumeUUID: .known("volume"), contentType: .known("public.audio")
        )
        var observed = recorded
        observed.contentModificationDate = .known(date.addingTimeInterval(0.0002))
        #expect(recorded.compare(to: observed) == .matches)
        #expect(SourceRevision.metadata(source, fingerprint: recorded)
            != SourceRevision.metadata(source, fingerprint: observed))
        #expect(SourceRevision.verifiedMetadata(source, recorded: recorded, observed: observed)
            == SourceRevision.metadata(source, fingerprint: recorded))
        observed.fileSize = .known(4_097)
        #expect(SourceRevision.verifiedMetadata(source, recorded: recorded, observed: observed) == nil)
    }

    var base: DerivedAssetKey {
        .sample(
            sources: [SourceRevision(source: source, token: "t1")],
            epoch: RecordingEpochID(UUID(uuid: UUID_NULL)),
            occurrence: SourceOccurrenceID(UUID(uuid: UUID_NULL)),
            channel: 0,
            map: MapRevisionReference(episode: EpisodeID(UUID(uuid: UUID_NULL)), revision: 1),
            recipe: RecipeReference(name: "align", revision: 1)
        )
    }

    /// Every M2-C5 component participates in the key: changing any one changes the key and its digest.
    @Test func everyComponentChangesTheKey() {
        let reference = base
        var variants: [String: DerivedAssetKey] = [:]
        var k = reference; k.asset.kind = "spectrogram"; variants["asset kind"] = k
        k = reference; k.asset.revision = 2; variants["asset revision"] = k
        k = reference; k.setSources([SourceRevision(source: source, token: "t2")]); variants["source revision"] = k
        k = reference; k.setSources([SourceRevision(source: other, token: "t1")]); variants["source identity"] = k
        k = reference; k.format = FormatRevision(interpretationVersion: 2, envelopeVersion: 1); variants["format interpretation"] = k
        k = reference; k.format = FormatRevision(interpretationVersion: 1, envelopeVersion: 2); variants["format envelope"] = k
        k = reference; k.epoch = RecordingEpochID(); variants["epoch"] = k
        k = reference; k.occurrence = SourceOccurrenceID(); variants["occurrence"] = k
        k = reference; k.channel = 1; variants["channel"] = k
        k = reference; k.channel = nil; variants["all channels"] = k
        k = reference; k.map?.revision = 2; variants["map revision"] = k
        k = reference; k.recipe?.revision = 2; variants["recipe revision"] = k
        k = reference; k.setUpstream([.sample(kind: "envelope")]); variants["upstream"] = k
        for (name, variant) in variants {
            #expect(variant != reference, "\(name)")
            #expect(variant.digest != reference.digest, "\(name)")
        }
        #expect(Set(variants.values.map(\.digest)).count == variants.count)
    }

    @Test func keysAreCanonical() throws {
        let a = SourceRevision(source: source, token: "a")
        let b = SourceRevision(source: other, token: "b")
        let up1 = DerivedAssetKey.sample(kind: "x")
        let up2 = DerivedAssetKey.sample(kind: "y")
        let first = DerivedAssetKey.sample(sources: [a, b], upstream: [up1, up2, up1])
        let second = DerivedAssetKey.sample(sources: [b, a], upstream: [up2, up1])
        #expect(first == second)
        #expect(first.digest == second.digest)
        #expect(CanonicalDigest.isDigest(first.digest))
        let decoded = try JSONDecoder().decode(DerivedAssetKey.self, from: try JSONEncoder().encode(first))
        #expect(decoded == first)
        #expect(decoded.digest == first.digest)
    }

    @Test func metadataAndDecodedContentRevisionsAreDistinct() {
        var fingerprint = FileSystemFingerprint()
        let metadata = SourceRevision.metadata(source, fingerprint: fingerprint)
        #expect(metadata.token.hasPrefix("metadata:"))
        fingerprint.fileSize = .known(12)
        #expect(SourceRevision.metadata(source, fingerprint: fingerprint) != metadata)
        let content = SourceRevision.decodedContent(DecodedContentDigest(
            source: source, value: DecodedContentDigest.scheme + String(repeating: "0", count: 64), format: .current, frameCount: 1
        ))
        #expect(content.token.hasPrefix("decoded-content:"))
        #expect(content != metadata)
    }
}
