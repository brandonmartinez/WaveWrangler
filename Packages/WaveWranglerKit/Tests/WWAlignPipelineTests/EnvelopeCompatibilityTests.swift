import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWDerived
import WWPersistence
import WWSources
import WWTimeMap
@testable import WWAlignPipeline

@Suite("Persisted recording-map decode-envelope compatibility", .serialized)
struct EnvelopeCompatibilityTests {
    private static let legacyFormat = FormatRevision(interpretationVersion: 1, envelopeVersion: 1)

    /// Builds a legacy accepted version directly with envelope-1 dependencies. No current-envelope
    /// analysis, acceptance, probe, or source facts generate this persisted map.
    private func persistLegacyMap(_ f: PipelineFixture, corrected: Bool) async throws -> URL {
        let rate = try NominalRate(8000)
        let referenceOccurrence = alignmentOccurrenceID(for: f.id("ref"))
        let reference = TimelineReference(group: f.groups[0], epoch: f.epochs[0], occurrence: referenceOccurrence)
        let groups = try ["ref", "dynamic"].enumerated().map { index, name in
            let mapping = try AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(12),
                rateRatio: .one, alignedOffset: .zero)
            return try GroupTimeMap(group: f.groups[index], reference: reference, epochs: [
                EpochClockMap(epoch: f.epochs[index], mapping: .mapped(
                    segments: [mapping],
                    provenance: index == 0 ? .timelineReference
                        : .manual(ManualCorrection(basis: .acceptedAcousticProposal))))
            ], placements: [
                OccurrencePlacement(
                    occurrence: try SourceOccurrence(id: alignmentOccurrenceID(for: f.id(name)),
                        source: f.id(name), nominalRate: rate, frameCount: 96_000),
                    spans: [EpochSpan(startFrame: 0, endFrame: 96_000, epoch: f.epochs[index], groupClockOffset: .zero)])
            ])
        }
        let map = try AlignedTimelineMap(reference: reference, groups: groups)
        let corrections: [SourceTimingCorrection] = corrected ? [
            SourceTimingCorrection(source: f.id("dynamic"), group: f.groups[1], epoch: f.epochs[1],
                reference: f.id("ref"), sourceRate: 8000, sourceFrames: 96_000, channelCount: 2,
                analysisDigest: String(repeating: "a", count: 64), processing: "ww-native-time-pitch-multichannel/1",
                segments: [.init(sourceStart: 0, sourceEnd: 12, alignedStart: 0.125, rateRatio: 1.0001)])
        ] : []
        let inputs = await f.coordinator.inputs
        // Freeze the actual pre-F3 dependency encoding and recipe revision independently of the
        // current acceptance writer, so a new recipe cannot silently regenerate this fixture.
        let legacySources = ["ref", "dynamic"].enumerated().map { index, name in
            SourceRevision(source: f.id(name), token:
                "\(inputs.sources[f.id(name)]!)|fiv=1|env=1|group=\(f.groups[index])|epochs=\(f.epochs[index])")
        }
        let oldDigest = DerivedAssetKey(asset: AssetSpec(kind: "ww.alignment-dependencies", revision: 1),
                                        sources: legacySources).digest
        #expect(oldDigest == MapDependencies.digest(map: map, tokens: inputs.sources,
            format: Self.legacyFormat, corrections: corrections))
        #expect(oldDigest != MapDependencies.digest(map: map, tokens: inputs.sources,
            format: .current, corrections: corrections))
        let recorded = try f.model.recordingMap(map, in: f.episodeID,
            inputs: ["ref", "dynamic"].map { TimeMapSourceInput(sourceID: f.id($0), formatInterpretationVersion: 1) },
            recipe: RecipeReference(name: "ww.alignment-acceptance;deps=" + oldDigest
                + ";accepted=\(f.epochs[1]):" + String(repeating: "b", count: 64), revision: 2),
            sourceCorrections: corrections.isEmpty ? nil : corrections)
        f.model = try recorded.model.acceptingMap(revision: recorded.revision.revision, in: f.episodeID)
        for index in f.model.episodes[0].sources.indices {
            f.model.episodes[0].sources[index].observations.channelCount = .known(2)
        }
        await f.coordinator.setFormat(Self.legacyFormat)
        try await f.pipeline.activate(model: f.model, episode: f.episodeID)
        #expect(try await f.pipeline.verifiedAcceptedMap(model: f.model, episode: f.episodeID) == map)

        let encoded = try ShowPackageCoder().encodeDocument(f.model, revision: 1, publicationID: UUID())
        let url = f.directory.url.appendingPathComponent("persisted-envelope-1.wwshow")
        try encoded.data.write(to: url)
        return url
    }

    @Test("Persisted envelope-1 timing and correction bytes reopen unchanged under v2; PCM stays stale",
          arguments: [false, true])
    func persistedLegacyTimingSurvivesOnlyTheEvidencedExpansion(corrected: Bool) async throws {
        let f = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "ref", seconds: 12, signal: .sine(hz: 211), sampleRate: 8000)]),
            .init(name: "Dynamic", sources: [.init(name: "dynamic", seconds: 12, signal: .sine(hz: 223), sampleRate: 8000)])
        ], label: "persisted-envelope-1")
        let url = try await persistLegacyMap(f, corrected: corrected)
        let bytes = try Data(contentsOf: url)
        let prior = try #require(f.model.episodes[0].alignment?.acceptedMap)
        let opener = DocumentOpener(coder: ShowPackageCoder(), recovery: nil,
                                    identityOf: { .show($0.show.id) })
        guard case let .editable(decoded, _) = opener.open(url, key: .show(f.model.show.id)) else {
            Issue.record("legacy show could not reopen"); return
        }
        #expect(decoded.payload == f.model)
        #expect(decoded.payload.episodes[0].alignment?.acceptedMap == prior)
        #expect((prior.sourceCorrections?.count ?? 0) == (corrected ? 1 : 0))

        let io = SystemSourceIO()
        var records: [DeviceAccessRecord] = []
        for name in ["ref", "dynamic"] {
            guard case let .success(metadata) = io.metadata(at: f.url(name)) else { throw POSIXError(.ENOENT) }
            records.append(DeviceAccessRecord(showID: f.model.show.id, sourceID: f.id(name),
                bookmark: try io.makeReadOnlyBookmark(for: f.url(name)), lastKnownPath: f.url(name).path,
                recordedIdentity: RecordedIdentity(fingerprint: metadata.fingerprint, confirmation: .userConfirmed,
                                                 recordedAt: Date()), createdAt: Date()))
        }
        let accessStore = InMemoryDeviceAccessStore(records)
        let legacySurvey = EpisodeSourceAccessVerifier(showID: f.model.show.id, coordinator: f.coordinator,
            accessStore: accessStore, access: SourceAccessContext(io: io))
        let inventory = try await legacySurvey.survey(episode: f.episodeID) {
            EpisodeSourceDocument(model: decoded.payload, publication: decoded.publication)
        }
        #expect(inventory.lanes.count == 4)
        #expect(inventory.completeCutPreparation == .refused([
            .protectionSurveyAbsent, .fadeNotCertified, .atomicPublicationNotCertified
        ]))
        let oldCacheKey = DerivedAssetKey(asset: AssetSpec(kind: "legacy-pcm-control", revision: 1), format: Self.legacyFormat)
        await f.coordinator.setAssetRevision(oldCacheKey.asset)
        let oldCache = await f.coordinator.run(DerivedSlot("legacy-pcm"), key: oldCacheKey) { Data([1]) }
        #expect(oldCache.isAvailable)
        await f.pipeline.shutdown()

        let currentCoordinator = DerivedJobCoordinator(store: f.store)
        for revision in await f.coordinator.inputs.sources {
            await currentCoordinator.updateSource(SourceRevision(source: revision.key, token: revision.value))
        }
        let currentPipeline = AlignmentPipeline(coordinator: currentCoordinator, decoder: f.decoder, configuration: f.configuration)
        #expect(await currentCoordinator.inputs.format == .current)
        #expect(await currentCoordinator.staleReasons(for: oldCacheKey).contains(.formatChanged),
                "disposable envelope-1 PCM is expected to be stale")
        await currentCoordinator.setAssetRevision(oldCacheKey.asset)
        let reusedPCM = await currentCoordinator.run(DerivedSlot("legacy-pcm"), key: oldCacheKey) {
            Issue.record("obsolete PCM must never be rebuilt or returned under its old key")
            return Data([2])
        }
        #expect(reusedPCM.outcome == .discardedStale([.formatChanged]))
        try await currentPipeline.activate(model: decoded.payload, episode: f.episodeID)
        let currentMap = try await currentPipeline.verifiedAcceptedMap(model: decoded.payload, episode: f.episodeID)
        #expect(currentMap == (try decoded.payload.timeMap(revision: prior.revision, in: f.episodeID)))
        let currentSurvey = EpisodeSourceAccessVerifier(showID: f.model.show.id, coordinator: currentCoordinator,
            accessStore: accessStore, access: SourceAccessContext(io: io))
        let reopenedInventory = try await currentSurvey.survey(episode: f.episodeID) {
            EpisodeSourceDocument(model: decoded.payload, publication: decoded.publication)
        }
        #expect(reopenedInventory.lanes == inventory.lanes)
        #expect(reopenedInventory.completeCutPreparation == inventory.completeCutPreparation,
                "reopening preserves the source/cleanup gate; it does not invent cut certification")
        #expect(decoded.payload.episodes[0].alignment?.acceptedMap == prior)
        #expect(MapDependencies.acceptedProposals(prior) == [f.epochs[1].description: String(repeating: "b", count: 64)])
        #expect(try Data(contentsOf: url) == bytes, "compatibility must not rewrite accepted timing or corrections")
        let canonical = try AcceptedMapIdentity(revision: MapRevisionReference(episode: f.episodeID, revision: prior.revision),
            version: prior, map: currentMap, registered: await currentCoordinator.inputs.sources)
        #expect(await currentCoordinator.state(of: canonical.slot) == .ready(canonical.key))

        let fresh = try await currentPipeline.prepareManual(model: decoded.payload, episode: f.episodeID,
            sources: f.sources, authorizations: f.authorizations)
        #expect(fresh.facts.count == 2 && fresh.facts.values.allSatisfy { $0.envelopeVersion == 2 })
        let currentFact = try #require(fresh.facts[f.id("dynamic")])
        var oldInterpretation = currentFact.interpretation
        oldInterpretation.envelopeVersion = 1
        #expect(throws: AlignmentWorkFailure.formatRevisionMismatch(interpretation: 1, envelope: 1)) {
            try SourceProbe.verify(oldInterpretation, source: currentFact.source, token: currentFact.revisionToken)
        }
        var oldFacts = fresh.facts
        oldFacts[currentFact.source]?.interpretation = oldInterpretation
        let analysisChanges = MapDependencies.analysisChanges(plan: fresh.plan, facts: oldFacts,
            episode: decoded.payload.episodes[0], registered: await currentCoordinator.inputs.sources, format: .current)
        #expect(analysisChanges == [.formatChanged(currentFact.source)],
                "timing compatibility must not make envelope-1 analysis/probe facts current")
        let accepted = try await currentPipeline.accept(model: decoded.payload, episode: f.episodeID,
            report: fresh, decisions: [:])
        #expect(accepted.model.episodes[0].alignment?.acceptedMap?.inputs.recipe?.revision == 3)
        #expect(accepted.model.episodes[0].alignment?.acceptedMap?.sourceCorrections == prior.sourceCorrections)
        try await currentPipeline.activate(accepted)
        let revised = try await currentPipeline.reviseAcceptedMap(model: accepted.model, episode: f.episodeID, decisions: [:])
        let forward = try #require(revised.model.episodes[0].alignment?.acceptedMap)
        #expect(forward.inputs.recipe?.revision == 3)
        #expect(forward.inputs.recipe?.name.contains(";frames=ww.decode-audible-source/1;fiv=1;env=2") == true)
        #expect(revised.map == currentMap && forward.sourceCorrections == prior.sourceCorrections)
        #expect(MapDependencies.acceptedProposals(forward) == MapDependencies.acceptedProposals(prior))
        #expect(revised.model.episodes[0].alignment?.map(revision: prior.revision) == prior)
        try await currentPipeline.activate(revised)
        let forwardURL = f.directory.url.appendingPathComponent("persisted-recipe-3.wwshow")
        let saved = try ShowPackageCoder().encodeDocument(revised.model, revision: 2, publicationID: UUID())
        try saved.data.write(to: forwardURL)
        guard case let .editable(forwardDecoded, _) = opener.open(forwardURL, key: .show(f.model.show.id)) else {
            Issue.record("forward show could not reopen"); return
        }
        let reopenedPipeline = AlignmentPipeline(coordinator: currentCoordinator, decoder: f.decoder, configuration: f.configuration)
        try await reopenedPipeline.activate(model: forwardDecoded.payload, episode: f.episodeID)
        #expect(try await reopenedPipeline.verifiedAcceptedMap(model: forwardDecoded.payload, episode: f.episodeID) == currentMap)
        #expect(forwardDecoded.payload.episodes[0].alignment?.acceptedMap == forward)
        print("PERSISTED v1 corrected=\(corrected): v2 timing/corrections/canonical identity/survey unchanged; v1 PCM stale; forward recipe3 persisted")
        await reopenedPipeline.shutdown()
        await currentPipeline.shutdown()
    }

    @Test(arguments: [
        "source", "placement", "correction-placement", "unknown-envelope", "unknown-interpretation",
        "unknown-recipe", "experimental-recipe2-env2", "unknown-frame-contract", "source-input-version"
    ])
    func compatibilityDoesNotAdmitChangedDependenciesOrUnknownContracts(_ change: String) async throws {
        let f = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "ref", seconds: 12, signal: .sine(hz: 211), sampleRate: 8000)]),
            .init(name: "Dynamic", sources: [.init(name: "dynamic", seconds: 12, signal: .sine(hz: 223), sampleRate: 8000)])
        ], label: "legacy-refusal-\(change)")
        let url = try await persistLegacyMap(f, corrected: true)
        let opener = DocumentOpener(coder: ShowPackageCoder(), recovery: nil,
                                    identityOf: { .show($0.show.id) })
        guard case let .editable(decoded, _) = opener.open(url, key: .show(f.model.show.id)) else {
            Issue.record("legacy show could not reopen"); return
        }
        var changed = decoded.payload
        await f.coordinator.setFormat(.current)
        let current = AlignmentPipeline(coordinator: f.coordinator, decoder: f.decoder, configuration: f.configuration)
        switch change {
        case "source":
            await f.coordinator.updateSource(SourceRevision(source: f.id("dynamic"), token: "changed-live-original"))
        case "placement":
            changed.episodes[0].sources[1].placement = SourcePlacement(recorderGroupID: f.groups[0], epochID: f.epochs[0])
        case "correction-placement":
            changed.episodes[0].alignment?.maps[0].sourceCorrections?[0].group = f.groups[0]
        case "unknown-envelope":
            await f.coordinator.setFormat(FormatRevision(interpretationVersion: 1, envelopeVersion: 3))
        case "unknown-interpretation":
            await f.coordinator.setFormat(FormatRevision(interpretationVersion: 2, envelopeVersion: 2))
        case "unknown-recipe":
            changed.episodes[0].alignment?.maps[0].inputs.recipe?.revision = 4
        case "experimental-recipe2-env2":
            let map = try changed.timeMap(revision: 1, in: f.episodeID)
            let digest = try #require(MapDependencies.digest(map: map, tokens: await f.coordinator.inputs.sources,
                format: .current, corrections: changed.episodes[0].alignment?.acceptedMap?.sourceCorrections ?? []))
            changed.episodes[0].alignment?.maps[0].inputs.recipe = RecipeReference(
                name: "ww.alignment-acceptance;deps=" + digest, revision: 2)
        case "unknown-frame-contract":
            let version = try #require(changed.episodes[0].alignment?.acceptedMap)
            let digest = try #require(MapDependencies.persistedDigest(version))
            changed.episodes[0].alignment?.maps[0].inputs.recipe = RecipeReference(
                name: "ww.alignment-acceptance;deps=" + digest + ";frames=unknown/2;fiv=1;env=1", revision: 3)
        case "source-input-version":
            changed.episodes[0].alignment?.maps[0].inputs.sources[0].formatInterpretationVersion = 2
        default:
            Issue.record("unknown negative control")
        }
        await #expect(throws: AlignmentAcceptanceError.self) {
            try await current.activate(model: changed, episode: f.episodeID)
        }
        await current.shutdown()
    }

    @Test func legacyCompatibilityNeverReplacesLiveCanonicalPublicationOrShutdownChecks() async throws {
        let f = try await PipelineFixture([
            .init(name: "Reference", sources: [.init(name: "ref", seconds: 12, signal: .sine(hz: 211), sampleRate: 8000)]),
            .init(name: "Dynamic", sources: [.init(name: "dynamic", seconds: 12, signal: .sine(hz: 223), sampleRate: 8000)])
        ], label: "legacy-live-canonical")
        _ = try await persistLegacyMap(f, corrected: true)
        let persisted = f.model
        await f.coordinator.setFormat(.current)
        f.reopenPipeline()
        try await f.pipeline.activate(model: persisted, episode: f.episodeID)
        let map = try await f.pipeline.verifiedAcceptedMap(model: persisted, episode: f.episodeID)
        let prior = try #require(persisted.episodes[0].alignment?.acceptedMap)
        let identity = try AcceptedMapIdentity(revision: MapRevisionReference(episode: f.episodeID, revision: prior.revision),
            version: prior, map: map, registered: await f.coordinator.inputs.sources)
        var different = persisted
        different.episodes[0].alignment?.maps[0].sourceCorrections?[0].segments[0].alignedStart += 0.125
        await #expect(throws: AlignedAssetRefusal.acceptedMapContentNotActive) {
            try await f.pipeline.verifiedAcceptedMap(model: different, episode: f.episodeID)
        }
        #expect(await f.coordinator.state(of: identity.slot) == .ready(identity.key))
        await f.coordinator.invalidate(identity.slot)
        await #expect(throws: AlignedAssetRefusal.acceptedMapContentNotActive) {
            try await f.pipeline.verifiedAcceptedMap(model: persisted, episode: f.episodeID)
        }
        try await f.pipeline.activate(model: persisted, episode: f.episodeID)
        await f.pipeline.shutdown()
        await #expect(throws: AlignedAssetRefusal.coordinatorShutDown) {
            try await f.pipeline.verifiedAcceptedMap(model: persisted, episode: f.episodeID)
        }
    }
}
