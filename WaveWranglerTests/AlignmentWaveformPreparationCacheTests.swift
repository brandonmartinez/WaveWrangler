import Foundation
import Testing
import WWAlignPipeline
import WWCore
import WWDerived
import WWTimeMap

@Suite("Persistent waveform presentation cache", .serialized)
struct AlignmentWaveformPreparationCacheTests {
    private struct Fixture {
        let folder: URL
        let store: DerivedAssetStore
        let episode = EpisodeID()
        let group = RecorderGroupID()
        let epoch = RecordingEpochID()
        let source = SourceID()
        let referenceGroup = RecorderGroupID()
        let referenceEpoch = RecordingEpochID()
        let referenceOccurrence = SourceOccurrenceID()
        let track: AlignmentWaveformTrack
        let overviewKey: DerivedAssetKey

        init(bins: Int = 128) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("WW-waveform-\(UUID())")
            store = try DerivedAssetStore(root: folder, sourceLocations: [])
            overviewKey = DerivedAssetKey(asset: AssetSpec(kind: "ww.waveform.overview", revision: 3),
                sources: [SourceRevision(source: source, token: "metadata:synthetic")], format: .current)
            track = AlignmentWaveformTrack(group: group, epoch: epoch, name: "Generated", groupName: "Recorder",
                envelope: WaveformEnvelope(source: source, sampleRate: 1000, channelCount: 1,
                    totalFrames: Int64(bins * 100), bins: (0..<bins).map {
                        WaveformBin(firstFrame: Int64($0 * 100), endFrame: Int64(($0 + 1) * 100),
                            minimum: -0.2, maximum: 0.4)
                    }), overviewCacheKey: overviewKey)
        }

        func map(offset: Int64 = 0) throws -> AlignedTimelineMap {
            let occurrence = try SourceOccurrence(id: SourceOccurrenceID(source.rawValue), source: source,
                nominalRate: NominalRate(1000), frameCount: track.envelope.totalFrames)
            let reference = TimelineReference(group: referenceGroup, epoch: referenceEpoch, occurrence: referenceOccurrence)
            let referenceSource = try SourceOccurrence(id: referenceOccurrence,
                source: SourceID(referenceOccurrence.rawValue), nominalRate: NominalRate(1000),
                frameCount: track.envelope.totalFrames)
            let end = try ExactRational(track.envelope.totalFrames, 1000)
            return try AlignedTimelineMap(reference: reference, groups: [
                GroupTimeMap(group: referenceGroup, reference: reference, epochs: [
                    EpochClockMap(epoch: referenceEpoch, mapping: .mapped(segments: [
                        AffineClockSegment(groupClockStart: .zero, groupClockEnd: end,
                            rateRatio: .one, alignedOffset: .zero)
                    ], provenance: .timelineReference))
                ], placements: [OccurrencePlacement(occurrence: referenceSource, spans: [
                    EpochSpan(startFrame: 0, endFrame: track.envelope.totalFrames,
                        epoch: referenceEpoch, groupClockOffset: .zero)
                ])]),
                GroupTimeMap(group: group, reference: reference, epochs: [
                    EpochClockMap(epoch: epoch, mapping: .mapped(segments: [
                        AffineClockSegment(groupClockStart: .zero,
                            groupClockEnd: end,
                            rateRatio: .one, alignedOffset: ExactRational(offset))
                    ], provenance: .manual(ManualCorrection(basis: .numericEntry))))
                ], placements: [OccurrencePlacement(occurrence: occurrence, spans: [
                    EpochSpan(startFrame: 0, endFrame: track.envelope.totalFrames,
                        epoch: epoch, groupClockOffset: .zero)
                ])])
            ])
        }

        func coordinator() async -> DerivedJobCoordinator {
            var inputs = DerivedInputs()
            inputs.sources[source] = overviewKey.sources[0].token
            inputs.assets[overviewKey.asset.kind] = overviewKey.asset.revision
            let coordinator = DerivedJobCoordinator(store: store, inputs: inputs)
            let job = await coordinator.submit(DerivedSlot("measured"), key: overviewKey) {
                Data("synthetic measured overview".utf8)
            }
            let outcome = await job.outcome
            #expect(outcome == .published(overviewKey) || outcome == .reused(overviewKey))
            return coordinator
        }

        func prepare(_ coordinator: DerivedJobCoordinator, offset: Int64 = 0,
                     cuts: ManualCutTimeline = .unedited) async throws -> AlignmentWaveformPreparationCache.Result {
            try await AlignmentWaveformPreparationCache(coordinator: coordinator).prepare(
                track: track, overviewKey: overviewKey, episode: episode, map: map(offset: offset),
                correction: nil, cuts: cuts)
        }
    }

    @Test func reopenRestoresTheExactPreparedIndexWithoutReprojection() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let first = await f.coordinator()
        let built = try await f.prepare(first)
        #expect(!built.reused && !built.repaired)
        #expect(built.index.count == f.track.envelope.bins.count)
        #expect(built.index.strokes == (try AlignmentWaveformProjection.strokes(track: f.track, map: f.map())))
        await first.shutdown()

        let reopened = await f.coordinator()
        let restored = try await f.prepare(reopened)
        #expect(restored.reused && !restored.repaired)
        #expect(restored.index.id != built.index.id)
        #expect(restored.index.strokes == built.index.strokes)
        #expect(restored.index.displayExtent == built.index.displayExtent)
        #expect(restored.index.normalizedGain == built.index.normalizedGain)
        for start in stride(from: -1.0, through: 13, by: 0.25) {
            #expect(restored.index.visible(start: start, duration: 0.5)
                == built.index.visible(start: start, duration: 0.5))
            #expect(restored.index.visible(start: start, duration: 0.5,
                draftEpoch: f.epoch, ratePPM: 1000, offsetMilliseconds: 250)
                == built.index.visible(start: start, duration: 0.5,
                    draftEpoch: f.epoch, ratePPM: 1000, offsetMilliseconds: 250))
        }
        await reopened.shutdown()
    }

    @Test func timingAndCutChangesRebuildAndUndoRestoresThePriorCache() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let coordinator = await f.coordinator()
        let original = try await f.prepare(coordinator)
        let shifted = try await f.prepare(coordinator, offset: 1)
        #expect(!shifted.reused && shifted.index.strokes != original.index.strokes)
        let cuts = try ManualCutTimeline(cuts: [
            ManualEpisodeCut(alignmentRevision: 1, startFrame: 48_000, endFrame: 96_000)
        ])
        let shortened = try await f.prepare(coordinator, cuts: cuts)
        #expect(!shortened.reused && shortened.index.strokes != original.index.strokes)
        #expect(shortened.index.strokes == (try AlignmentWaveformProjection.strokes(
            track: f.track, map: f.map(), cuts: cuts)))
        let undone = try await f.prepare(coordinator)
        #expect(undone.reused && undone.index.strokes == original.index.strokes)
        await coordinator.shutdown()
    }

    @Test func cacheKeyCoversSourceChannelRecipeEpochAndFileLocalTimingButNotNames() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        func key(_ track: AlignmentWaveformTrack, _ overview: DerivedAssetKey,
                 correction: SourceTimingCorrection? = nil) throws -> DerivedAssetKey {
            try AlignmentWaveformPreparationCache.key(track: track, overviewKey: overview,
                map: f.map(), correction: correction, cuts: .unedited)
        }
        let original = try key(f.track, f.overviewKey)
        #expect(try AlignmentWaveformPreparationCache.key(track: f.track, overviewKey: f.overviewKey,
            map: f.map(), correction: nil, cuts: .unedited, mappedOnly: true) != original)
        for change in 0..<4 {
            var overview = f.overviewKey
            switch change {
            case 0: overview.setSources([SourceRevision(source: f.source, token: "metadata:changed")])
            case 1: overview.asset.kind += ".channel.1"
            case 2: overview.asset.revision += 1
            default: overview.coverage = "different covered source frames"
            }
            #expect(try key(f.track, overview) != original)
        }
        let renamed = AlignmentWaveformTrack(group: f.group, epoch: f.epoch, name: "Renamed",
            groupName: "Another display name", envelope: f.track.envelope)
        #expect(try key(renamed, f.overviewKey) == original)
        let replacedEpoch = AlignmentWaveformTrack(group: f.group, epoch: RecordingEpochID(), name: "Generated",
            groupName: "Recorder", envelope: f.track.envelope)
        #expect(try key(replacedEpoch, f.overviewKey) != original)
        let correction = SourceTimingCorrection(source: f.source, group: f.group, epoch: f.epoch,
            reference: SourceID(), sourceRate: 1000, sourceFrames: f.track.envelope.totalFrames, channelCount: 1,
            analysisDigest: String(repeating: "a", count: 64), processing: "synthetic",
            segments: [SourceTimingSegment(sourceStart: 0, sourceEnd: 10, alignedStart: 1, rateRatio: 1)])
        #expect(try key(f.track, f.overviewKey, correction: correction) != original)
    }

    @Test(arguments: [false, true])
    func damagedOrInconsistentPayloadIsRebuiltRatherThanUsed(inconsistent: Bool) async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let coordinator = await f.coordinator()
        let original = try await f.prepare(coordinator)
        let key = try AlignmentWaveformPreparationCache.key(track: f.track, overviewKey: f.overviewKey,
            map: f.map(), correction: nil, cuts: .unedited)
        let states = await coordinator.states()
        let slot = try #require(states.first { $0.value.key == key }?.key)
        let invalid: Data
        if inconsistent {
            var plist = try #require(PropertyListSerialization.propertyList(
                from: original.index.cachedPayload(), format: nil) as? [String: Any])
            var order = try #require(plist["displayOrder"] as? Data)
            let invalidIndex = [UInt32.max.littleEndian].withUnsafeBytes { Data($0) }
            order.replaceSubrange(0..<4, with: invalidIndex)
            plist["displayOrder"] = order
            invalid = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        } else {
            invalid = Data("not a waveform index".utf8)
        }
        await coordinator.invalidate(slot)
        #expect(await coordinator.submit(slot, key: key) { invalid }.outcome == .published(key))
        let repaired = try await f.prepare(coordinator)
        #expect(repaired.repaired && !repaired.reused)
        #expect(repaired.index.strokes == original.index.strokes)
        #expect(try await f.prepare(coordinator).reused)
        await coordinator.shutdown()
    }

    @Test func staleSourceAndCanceledRequestCannotRestoreAnIndex() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let coordinator = await f.coordinator()
        _ = try await f.prepare(coordinator)
        await coordinator.updateSource(SourceRevision(source: f.source, token: "metadata:changed"))
        await #expect(throws: AlignmentWaveformPreparationCache.Failure.self) { try await f.prepare(coordinator) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.prepare(coordinator)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        await coordinator.shutdown()
    }

    @Test func compactIndexPreservesEmptyOverlappingUnmappedAndMultiEpochQueries() throws {
        let epochs = [RecordingEpochID(), RecordingEpochID()]
        let strokes = (0..<24).map { index in
            let start = Double(index - 8) / 2
            return AlignmentWaveformStroke(sourceSeconds: Double(index) / 10,
                groupSeconds: start, displaySeconds: start + 0.25,
                low: -Float(index) / 10, high: Float(index) / 20, mapped: index.isMultiple(of: 3),
                epoch: epochs[index % 2], displayRange: start...(start + 0.5), groupRange: (start - 1)...start)
        }
        for strokes in [[], strokes] {
            let original = AlignmentWaveformStrokeIndex(strokes: strokes)
            let restored = try AlignmentWaveformStrokeIndex(cachedPayload: original.cachedPayload())
            #expect(restored.strokes == strokes)
            #expect(restored.displayExtent == original.displayExtent)
            #expect(restored.mappedDisplayExtent == original.mappedDisplayExtent)
            for time in stride(from: -5.0, through: 10, by: 0.25) {
                #expect(restored.visible(start: time, duration: 0.5,
                    draftEpoch: epochs[0], ratePPM: 10_000, offsetMilliseconds: -200)
                    == original.visible(start: time, duration: 0.5,
                        draftEpoch: epochs[0], ratePPM: 10_000, offsetMilliseconds: -200))
            }
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func invalidCompactCoordinatesOrdersAndEpochsRefuse(change: Int) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let index = AlignmentWaveformStrokeIndex(strokes: try AlignmentWaveformProjection.strokes(track: f.track, map: nil))
        var plist = try #require(PropertyListSerialization.propertyList(
            from: index.cachedPayload(), format: nil) as? [String: Any])
        if change == 1 {
            var order = try #require(plist["displayOrder"] as? Data)
            order.replaceSubrange(4..<8, with: order.prefix(4))
            plist["displayOrder"] = order
        } else {
            var strokes = try #require(plist["strokes"] as? Data)
            if change == 2 {
                strokes.removeLast()
            } else {
                let field = change == 0 ? 0 : 8
                let bits = change == 0 ? Double.nan.bitPattern : UInt64.max
                strokes.replaceSubrange((field * 8)..<(field * 8 + 8),
                    with: [bits.littleEndian].withUnsafeBytes { Data($0) })
            }
            plist["strokes"] = strokes
        }
        let invalid = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        #expect(throws: AlignmentWaveformStrokeIndex.CacheError.self) {
            try AlignmentWaveformStrokeIndex(cachedPayload: invalid)
        }
    }

    @Test func fullResolutionOverviewUsesPersistentPreparationOnASecondOpen() async throws {
        let f = try Fixture(bins: WaveformWindowReader.maximumOverviewBins)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let maps: [AlignedTimelineMap?] = [nil, try f.map()]
        for map in maps {
            let start = ContinuousClock.now
            let expected = try AlignmentWaveformProjection.strokes(track: f.track, map: map)
            let expectedIndex = AlignmentWaveformStrokeIndex(strokes: expected)
            let projected = ContinuousClock.now - start
            let first = await f.coordinator()
            _ = try await AlignmentWaveformPreparationCache(coordinator: first).prepare(track: f.track,
                overviewKey: f.overviewKey, episode: f.episode, map: map, correction: nil, cuts: .unedited)
            await first.shutdown()
            let reopened = await f.coordinator()
            let restoreStart = ContinuousClock.now
            let restored = try await AlignmentWaveformPreparationCache(coordinator: reopened).prepare(
                track: f.track, overviewKey: f.overviewKey, episode: f.episode, map: map, correction: nil, cuts: .unedited)
            let restoreTime = ContinuousClock.now - restoreStart
            #expect(restored.reused && restored.index.count == expected.count)
            #expect(restored.index.visible(start: 600, duration: 30) == expectedIndex.visible(start: 600, duration: 30))
            print("65,536-bin \(map == nil ? "source-origin" : "aligned") presentation: project/index \(projected), restore \(restoreTime)")
            await reopened.shutdown()
        }
    }
}
