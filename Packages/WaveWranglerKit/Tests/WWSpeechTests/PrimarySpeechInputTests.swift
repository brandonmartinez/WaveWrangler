import Darwin
import Foundation
import Testing
import WWCore
import WWDecode
import WWDerived
import WWSources
import WWTimeMap
@testable import WWSpeech

private struct SpeechFixtureIO: SourceIO {
    let url: URL
    private let system = SystemSourceIO()

    var provenance: ObservationProvenance { .simulated }
    func metadata(at url: URL) -> MetadataResult { system.metadata(at: url) }
    func listItems(under directory: URL) -> DirectoryListing { system.listItems(under: directory) }
    func makeReadOnlyBookmark(for url: URL) throws -> Data { Data("fixture".utf8) }
    func resolveBookmark(_ data: Data) -> BookmarkResolution { .resolved(url, isStale: false) }
    func startAccessingSecurityScope(_ url: URL) -> Bool { false }
    func stopAccessingSecurityScope(_ url: URL) {}
    func requestDownload(of url: URL) throws {}
    func downloadFraction(of url: URL) async -> Knowledge<Double> { .unknown }
}

private actor SpeechSnapshot {
    var value: PrimarySpeechInputState
    var replacement: PrimarySpeechInputState?
    var calls = 0

    init(_ value: PrimarySpeechInputState) { self.value = value }
    func read() -> PrimarySpeechInputState {
        calls += 1
        return calls > 1 ? replacement ?? value : value
    }
    func change(_ next: PrimarySpeechInputState) { replacement = next }
}

private actor SpeechSwapSnapshot {
    let value: PrimarySpeechInputState
    let url: URL
    var calls = 0

    init(_ value: PrimarySpeechInputState, url: URL) { self.value = value; self.url = url }
    func read() throws -> PrimarySpeechInputState {
        calls += 1
        if calls == 2 {
            try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("old.wav"))
            try Data(repeating: 0, count: 300).write(to: url)
        }
        return value
    }
}

@Suite("Selected primary source bytes")
struct PrimarySpeechInputTests {
    private func wav(channel0: Int16 = 100, channel1: Int16 = -200, frames: Int = 64) -> Data {
        var data = Data()
        func ascii(_ text: String) { data.append(Data(text.utf8)) }
        func u16(_ value: UInt16) { data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        ascii("RIFF"); u32(UInt32(36 + frames * 4)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(2); u32(16_000); u32(64_000); u16(4); u16(16)
        ascii("data"); u32(UInt32(frames * 4))
        for _ in 0..<frames { u16(UInt16(bitPattern: channel0)); u16(UInt16(bitPattern: channel1)) }
        return data
    }

    private func fixture() throws -> (URL, URL, SourceAccessContext, PrimarySpeechInputState, EpisodeID, SpeakerID) {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ww-speech-input-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("source.wav")
        try wav().write(to: url)
        let io = SpeechFixtureIO(url: url)
        guard case let .success(metadata) = io.metadata(at: url) else {
            throw SpeechAdmissionRefusal.sourceIdentityNotConfirmed
        }
        let source = SourceRecord(displayNameHint: "synthetic", observations: SourceObservations(channelCount: .known(2)),
                                  placement: SourcePlacement(channelLabels: [ChannelLabel(channel: 1, label: "speech")]),
                                  role: .primary, roleConfirmation: .userConfirmed)
        let speaker = SpeakerID()
        let episode = Episode(title: "synthetic", sources: [source], speakerAssignments: [
            SpeakerAssignment(speakerID: speaker,
                              primary: ChannelReference(sourceID: source.id, statedChannel: 1),
                              primaryConfirmation: .userConfirmed)
        ])
        let show = ShowDocumentModel(show: Show(title: "synthetic"), speakers: [Speaker(id: speaker, name: "speaker")],
                                      episodes: [episode])
        let record = DeviceAccessRecord(
            showID: show.show.id, sourceID: source.id, bookmark: Data("fixture".utf8),
            lastKnownPath: url.path, recordedIdentity: RecordedIdentity(
                fingerprint: metadata.fingerprint, confirmation: .userConfirmed, recordedAt: Date()
            ), createdAt: Date()
        )
        let snapshot = PrimarySpeechInputState(
            show: show, showRevision: 1, accessRecords: [record],
            sourceRevision: SourceRevision.metadata(source.id, fingerprint: metadata.fingerprint),
            inputAssetRevision: PrimarySpeechInputAdapter.inputAssetRevision
        )
        return (directory, url, SourceAccessContext(io: io), snapshot, episode.id, speaker)
    }

    @Test func onlySelectedChannelDecodesAndCannotLaunchCallerWAV() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = try await PrimarySpeechInputAdapter(access: access).prepare(
            episodeID: episode, speakerID: speaker,
            authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
            availability: .on, current: { snapshot }
        )
        #expect(input.selection.channel == 1)
        #expect(input.frameCount == 64)
        #expect(input.interpretation.channelCount == 2)
        #expect(input.samples.allSatisfy { abs($0 - Float(-200) / 32768) < 0.000_01 })
        #expect(input.samples.allSatisfy { abs($0 - Float(100) / 32768) > 0.001 })
        #expect(throws: SpeechAdmissionRefusal.primaryProxyNotProven) {
            try input.offlinePlan(stage: directory, scratch: directory)
        }
    }

    @Test func absentConsentBackupUnknownChannelAndRevisionRefuseBeforeDecode() async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let adapter = PrimarySpeechInputAdapter(access: access)
        let grant = PrimarySpeechAuthorization.explicitUserRequest(episodeID: episode, speakerID: speaker)
        func denied(_ value: PrimarySpeechInputState, authorization: PrimarySpeechAuthorization? = grant)
            async -> SpeechAdmissionRefusal?
        {
            do {
                _ = try await adapter.prepare(episodeID: episode, speakerID: speaker,
                                              authorization: authorization, availability: .on, current: { value })
                return nil
            } catch { return error }
        }
        #expect(await denied(snapshot, authorization: nil) == .sourceIdentityNotConfirmed)
        #expect(await denied(snapshot, authorization: .explicitUserRequest(
            episodeID: episode, speakerID: SpeakerID()
        )) == .sourceIdentityNotConfirmed)
        do {
            _ = try await adapter.prepare(episodeID: episode, speakerID: speaker, authorization: grant,
                                          availability: .off, current: { snapshot })
            Issue.record("unavailable source was decoded")
        } catch {
            #expect(error == .sourceIdentityNotConfirmed)
        }
        var show = snapshot.show
        show.episodes[0].sources[0].role = .backup
        #expect(await denied(.init(show: show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
                == .primaryNotConfirmed)
        show = snapshot.show
        show.episodes[0].speakerAssignments[0].primary?.channel = .unknown
        #expect(await denied(.init(show: show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
                == .primaryNotConfirmed)
        show = snapshot.show
        show.episodes[0].sources[0].placement.channelLabels[0].channel = 0
        #expect(await denied(.init(show: show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
                == .primaryNotConfirmed)
        #expect(await denied(.init(show: snapshot.show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                   sourceRevision: nil, inputAssetRevision: snapshot.inputAssetRevision))
                == .sourceRevisionChanged)
        #expect(await denied(.init(show: snapshot.show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: nil))
                == .sourceRevisionChanged)
        #expect(await denied(.init(show: snapshot.show, showRevision: 1, accessRecords: [],
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
                == .sourceIdentityNotConfirmed)
        var alias = snapshot.accessRecords[0]
        alias.sourceID = SourceID()
        #expect(await denied(.init(show: snapshot.show, showRevision: 1, accessRecords: snapshot.accessRecords + [alias],
                                   sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
                == .sourceAliasOrChanged)
    }

    @Test func stalePrimaryAndAliasesDoNotPublishDecodedInput() async throws {
        let (directory, url, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = PrimarySpeechAuthorization.explicitUserRequest(episodeID: episode, speakerID: speaker)
        let adapter = PrimarySpeechInputAdapter(access: access)
        let state = SpeechSnapshot(snapshot)
        var changed = snapshot.show
        changed.episodes[0].speakerAssignments[0].primaryConfirmation = .provisional
        await state.change(.init(show: changed, showRevision: 2, accessRecords: snapshot.accessRecords,
                                 sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
        do {
            _ = try await adapter.prepare(episodeID: episode, speakerID: speaker, authorization: grant,
                                          availability: .on, current: { await state.read() })
            Issue.record("stale primary was published")
        } catch {
            #expect(error == .sourceRevisionChanged)
        }
        let restored = SpeechSnapshot(snapshot)
        await restored.change(.init(show: snapshot.show, showRevision: 2, accessRecords: snapshot.accessRecords,
                                    sourceRevision: snapshot.sourceRevision, inputAssetRevision: snapshot.inputAssetRevision))
        do {
            _ = try await adapter.prepare(episodeID: episode, speakerID: speaker, authorization: grant,
                                          availability: .on, current: { await restored.read() })
            Issue.record("primary switched away and back was published")
        } catch {
            #expect(error == .sourceRevisionChanged)
        }
        let alias = directory.appendingPathComponent("hardlink.wav")
        try FileManager.default.linkItem(at: url, to: alias)
        defer { try? FileManager.default.removeItem(at: alias) }
        do {
            _ = try await adapter.prepare(episodeID: episode, speakerID: speaker, authorization: grant,
                                          availability: .on, current: { snapshot })
            Issue.record("hardlinked source was published")
        } catch {
            #expect(error == .sourceAliasOrChanged)
        }
    }

    @Test func truncatedContainerCannotBecomeSpeechInput() async throws {
        let (directory, url, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var damaged = wav()
        damaged[40] = 0xFF
        try damaged.write(to: url)
        guard case let .success(metadata) = access.io.metadata(at: url) else {
            Issue.record("source metadata unavailable")
            return
        }
        var record = snapshot.accessRecords[0]
        record.recordedIdentity = RecordedIdentity(fingerprint: metadata.fingerprint,
                                                   confirmation: .userConfirmed, recordedAt: Date())
        let current = PrimarySpeechInputState(
            show: snapshot.show, showRevision: 1, accessRecords: [record],
            sourceRevision: SourceRevision.metadata(snapshot.show.episodes[0].sources[0].id, fingerprint: metadata.fingerprint),
            inputAssetRevision: PrimarySpeechInputAdapter.inputAssetRevision
        )
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).prepare(
                episodeID: episode, speakerID: speaker,
                authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                availability: .on, current: { current }
            )
            Issue.record("truncated source was published")
        } catch {
            guard case .decode = error else { Issue.record("unexpected refusal: \(error)"); return }
        }
    }

    @Test func pathSwapAndSymlinkedParentRefuse() async throws {
        let (directory, url, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let grant = PrimarySpeechAuthorization.explicitUserRequest(episodeID: episode, speakerID: speaker)
        let swapped = SpeechSwapSnapshot(snapshot, url: url)
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).prepare(
                episodeID: episode, speakerID: speaker, authorization: grant, availability: .on,
                current: { try await swapped.read() }
            )
            Issue.record("replaced path was published")
        } catch {
            #expect(error == .sourceAliasOrChanged)
        }
        let parent = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("ww-speech-link-\(UUID())")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: parent) }
        var record = snapshot.accessRecords[0]
        record.lastKnownPath = parent.appendingPathComponent("old.wav").path
        let symlinked = PrimarySpeechInputState(show: snapshot.show, showRevision: 1, accessRecords: [record],
                                                 sourceRevision: snapshot.sourceRevision,
                                                 inputAssetRevision: snapshot.inputAssetRevision)
        do {
            _ = try await PrimarySpeechInputAdapter(access: SourceAccessContext(
                io: SpeechFixtureIO(url: parent.appendingPathComponent("old.wav"))
            )).prepare(episodeID: episode, speakerID: speaker, authorization: grant, availability: .on,
                       current: { symlinked })
            Issue.record("symlinked parent was published")
        } catch {
            #expect(error == .sourceAliasOrChanged)
        }
    }

    @Test(arguments: ["continuous", "gap", "duplicate"])
    func occurrenceValidation(_ scenario: String) async throws {
        let (directory, _, access, snapshot, episode, speaker) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let duplicate = scenario == "duplicate"
        let gap = scenario == "gap"
        func time(_ frames: Int64) throws -> ExactRational {
            try ExactRational(numerator: Int128(frames), denominator: Int128(16_000))
        }
        func segment(_ start: Int64, _ end: Int64) throws -> AffineClockSegment {
            try AffineClockSegment(groupClockStart: time(start), groupClockEnd: time(end),
                                   rateRatio: .one, alignedOffset: .zero)
        }
        let rate = try NominalRate(16_000)
        let reference = try SourceOccurrence(source: SourceID(), nominalRate: rate, frameCount: 64)
        let refGroup = RecorderGroupID(), refEpoch = RecordingEpochID()
        let timeline = TimelineReference(group: refGroup, epoch: refEpoch, occurrence: reference.id)
        let refMap = try GroupTimeMap(
            group: refGroup, reference: timeline,
            epochs: [EpochClockMap(epoch: refEpoch,
                                   mapping: .mapped(segments: [segment(0, 64)], provenance: .timelineReference))],
            placements: [OccurrencePlacement(
                occurrence: reference, spans: [EpochSpan(startFrame: 0, endFrame: 64,
                                                          epoch: refEpoch, groupClockOffset: .zero)]
            )]
        )
        let source = snapshot.show.episodes[0].sources[0].id
        let chosen = try SourceOccurrence(source: source, nominalRate: rate, frameCount: 64)
        let first = RecordingEpochID(), second = RecordingEpochID()
        let spans = gap
            ? [EpochSpan(startFrame: 0, endFrame: 20, epoch: first, groupClockOffset: .zero),
               EpochSpan(startFrame: 40, endFrame: 64, epoch: second, groupClockOffset: try time(24))]
            : [EpochSpan(startFrame: 0, endFrame: 64, epoch: first, groupClockOffset: .zero)]
        let mapped = MapProvenance.manual(ManualCorrection(basis: .numericEntry))
        let targetGroupID = RecorderGroupID()
        let target = try GroupTimeMap(
            group: targetGroupID, reference: timeline,
            epochs: [EpochClockMap(epoch: first, mapping: .mapped(segments: [segment(0, 64)],
                                                                   provenance: mapped))]
                + (gap ? [EpochClockMap(epoch: second,
                                       mapping: .mapped(segments: [segment(64, 128)], provenance: mapped))] : []),
            placements: [OccurrencePlacement(occurrence: chosen, spans: spans)]
                + (duplicate ? [OccurrencePlacement(
                    occurrence: try SourceOccurrence(source: source, nominalRate: rate, frameCount: 64), spans: spans
                )] : [])
        )
        let map = try AlignedTimelineMap(reference: timeline, groups: [refMap, target])
        let embedded = try JSONDecoder().decode(EmbeddedJSON.self, from: JSONEncoder().encode(map))
        var show = snapshot.show
        show.episodes[0].sources[0].placement.recorderGroupID = targetGroupID
        show.episodes[0].sources[0].placement.epochID = first
        show.episodes[0].alignment = EpisodeAlignment(maps: [
            TimeMapVersion(revision: 1, inputs: TimeMapInputs(sources: []), map: embedded)
        ], acceptedRevision: 1)
        let current = PrimarySpeechInputState(show: show, showRevision: 1, accessRecords: snapshot.accessRecords,
                                               sourceRevision: snapshot.sourceRevision,
                                               inputAssetRevision: snapshot.inputAssetRevision)
        if scenario == "continuous" {
            let input = try await PrimarySpeechInputAdapter(access: access).prepare(
                episodeID: episode, speakerID: speaker,
                authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                availability: .on, current: { current }
            )
            #expect(input.occurrence == chosen.id)
            return
        }
        do {
            _ = try await PrimarySpeechInputAdapter(access: access).prepare(
                episodeID: episode, speakerID: speaker,
                authorization: .explicitUserRequest(episodeID: episode, speakerID: speaker),
                availability: .on, current: { current }
            )
            Issue.record("ambiguous or gapped occurrence was published")
        } catch {
            #expect(error == .occurrenceNotContinuous)
        }
    }
}
