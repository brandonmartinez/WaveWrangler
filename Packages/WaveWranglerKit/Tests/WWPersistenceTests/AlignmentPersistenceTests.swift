import Foundation
import Testing
import WWCore
@testable import WWPersistence
import WWTimeMap

/// Synthetic episode for map persistence: one recorder group with one epoch and two sources. The map places
/// the host as the timeline reference and the guest `guestOffset` seconds later on the same clock.
struct AlignmentPersistenceFixture {
    let group = RecorderGroupID()
    let epoch = RecordingEpochID()
    let host = SourceID()
    let guest = SourceID()
    let hostOccurrence = SourceOccurrenceID()
    let guestOccurrence = SourceOccurrenceID()
    let episodeID = EpisodeID()

    var episode: Episode {
        Episode(
            id: episodeID,
            title: "Episode",
            recorderGroups: [RecorderGroup(id: group, name: "Recorder", epochs: [RecordingEpoch(id: epoch, label: "Take 1")])],
            sources: [
                SourceRecord(id: host, displayNameHint: "host.wav", placement: SourcePlacement(recorderGroupID: group, epochID: epoch)),
                SourceRecord(id: guest, displayNameHint: "guest.wav", placement: SourcePlacement(recorderGroupID: group, epochID: epoch)),
            ]
        )
    }

    var show: ShowDocumentModel { ShowDocumentModel(show: Show(title: "Show"), episodes: [episode]) }

    func map(guestOffset: Int64 = 1, repeatGuestAt second: Int64? = nil) throws -> AlignedTimelineMap {
        let rate = try NominalRate(48000)
        let reference = TimelineReference(group: group, epoch: epoch, occurrence: hostOccurrence)
        let epochMap = EpochClockMap(
            epoch: epoch,
            mapping: .mapped(
                segments: [try AffineClockSegment(groupClockStart: .zero, groupClockEnd: ExactRational(10), rateRatio: .one, alignedOffset: .zero)],
                provenance: .timelineReference
            )
        )
        var placements = [
            OccurrencePlacement(
                occurrence: try SourceOccurrence(id: hostOccurrence, source: host, nominalRate: rate, frameCount: 480_000),
                spans: [EpochSpan(startFrame: 0, endFrame: 480_000, epoch: epoch, groupClockOffset: .zero)]
            ),
            OccurrencePlacement(
                occurrence: try SourceOccurrence(id: guestOccurrence, source: guest, nominalRate: rate, frameCount: 96_000),
                spans: [EpochSpan(startFrame: 0, endFrame: 96_000, epoch: epoch, groupClockOffset: ExactRational(guestOffset))]
            ),
        ]
        if let second {
            // The same logical source used a second time (a distinct occurrence of the same file).
            placements.append(OccurrencePlacement(
                occurrence: try SourceOccurrence(id: SourceOccurrenceID(), source: guest, nominalRate: rate, frameCount: 96_000),
                spans: [EpochSpan(startFrame: 0, endFrame: 96_000, epoch: epoch, groupClockOffset: ExactRational(second))]
            ))
        }
        let groupMap = try GroupTimeMap(group: group, reference: reference, epochs: [epochMap], placements: placements)
        return try AlignedTimelineMap(reference: reference, groups: [groupMap])
    }

    func version(_ revision: Int, map: AlignedTimelineMap, sources: [SourceID]? = nil) throws -> TimeMapVersion {
        TimeMapVersion(
            revision: revision,
            inputs: TimeMapInputs(sources: (sources ?? [host, guest]).map { TimeMapSourceInput(sourceID: $0) }),
            map: try EmbeddedTimeMapCodec.encode(map)
        )
    }

    func show(with alignment: EpisodeAlignment) -> ShowDocumentModel {
        var model = show
        model.episodes[0].alignment = alignment
        return model
    }
}

@Suite("Versioned map persistence")
struct AlignmentPersistenceTests {
    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
    /// Encodes without validation, to build documents the real coder must refuse on open.
    let unchecked = JSONEnvelopeCoder<ShowDocumentModel>(format: .show) { _, _ in [] }
    let fixture = AlignmentPersistenceFixture()

    func invalidPayloadCodes(_ error: any Error) -> [ValidationIssue.Code]? {
        if case let .invalidPayload(issues)? = error as? PersistenceError { issues.map(\.code) } else { nil }
    }

    /// Schema bump discipline: WW-020 is show schema 3 (`Episode.alignment`, migrated from 1 and 2 by C5); the
    /// embedded map format is WWTimeMap schema 1, which is part of show schema 3. A time-map schema bump requires a
    /// show schema bump (so an older build refuses the show as unknown-newer at the envelope), a C5 migration step
    /// and frozen golden fixtures of the previous show schema — update both pins together, never one alone.
    @Test func schemaVersionsArePinned() {
        #expect(SchemaVersion.show == 4, "a show schema bump needs a C5 step and frozen goldens of the previous schema")
        #expect(TimeMapSchema.currentVersion == 1, "a time-map schema bump requires a show schema bump (see this test's doc comment)")
    }

    @Test func mapsRoundTripThroughTheShowDocument() throws {
        let first = try fixture.map(guestOffset: 1)
        let second = try fixture.map(guestOffset: 3)
        var revised = try fixture.version(2, map: second)
        revised.derivedFrom = 1
        revised.inputs.recipe = RecipeReference(name: "manual-offset", revision: 1)
        revised.inputs.sources[0].formatInterpretationVersion = 1
        revised.inputs.sources[0].contentDigest = "decoded-pcm-sha256:" + String(repeating: "a", count: 64)
        let alignment = EpisodeAlignment(
            maps: [try fixture.version(1, map: first), revised],
            acceptedRevision: 2
        )
        let model = fixture.show(with: alignment)
        let decoded = try coder.decode(try coder.encode(model, revision: 1)).payload
        #expect(decoded == model)
        let restored = try #require(decoded.episodes.first?.alignment)
        #expect(try EmbeddedTimeMapCodec.decode(restored.maps[0].map) == first)
        #expect(try EmbeddedTimeMapCodec.decode(restored.maps[1].map) == second)
        #expect(restored.acceptedMap?.revision == 2)
    }

    @Test func showWithoutAlignmentOmitsTheField() throws {
        let model = fixture.show
        let data = try coder.encode(model, revision: 1)
        #expect(!String(decoding: data, as: UTF8.self).contains("alignment"))
        #expect(RevisionFingerprint(of: data).schemaVersion == 4)
        #expect(try coder.decode(data).payload == model)
    }

    @Test func aSourceUsedTwiceIsOneInputWithTwoOccurrences() throws {
        let map = try fixture.map(guestOffset: 1, repeatGuestAt: 6)
        #expect(EmbeddedTimeMapCodec.placedSources(map) == [fixture.host, fixture.guest])
        let model = fixture.show(with: EpisodeAlignment(maps: [try fixture.version(1, map: map)]))
        #expect(try coder.decode(try coder.encode(model, revision: 1)).payload == model)
    }

    /// A show whose first map is written with a newer time-map schema, at the top level or inside a group.
    func showWithNewerMap(nested: Bool) throws -> ShowDocumentModel {
        var version = try fixture.version(1, map: try fixture.map())
        guard case var .object(fields) = version.map else { throw PersistenceError.malformed("map is not an object") }
        let newer = EmbeddedJSON.integer(Int64(TimeMapSchema.currentVersion + 1))
        if nested {
            guard case var .array(groups)? = fields["groups"], case var .object(group)? = groups.first else {
                throw PersistenceError.malformed("map has no group")
            }
            group["timeMapSchemaVersion"] = newer
            groups[0] = .object(group)
            fields["groups"] = .array(groups)
        } else {
            fields["timeMapSchemaVersion"] = newer
        }
        version.map = .object(fields)
        return fixture.show(with: EpisodeAlignment(maps: [version]))
    }

    /// Review #182 (1): a newer embedded map is refused as unknown-newer — C5's refusal, which no damaged/recovery
    /// fallback may bypass — never as damaged content.
    @Test(arguments: [false, true])
    func refusesAMapFromANewerTimeMapSchemaOnOpen(nested: Bool) throws {
        let found = TimeMapSchema.currentVersion + 1, supported = TimeMapSchema.currentVersion
        let model = try showWithNewerMap(nested: nested)
        let data = try unchecked.encode(model, revision: 2)
        #expect(throws: PersistenceError.unknownNewerSchema(found: found, supported: supported)) { try coder.decode(data) }
        #expect(throws: PersistenceError.unknownNewerSchema(found: found, supported: supported)) { try ShowSchemaMigration.decodeUpgradingOlder(data) }

        // Opened by the app's opener with an older recovery checkpoint available: refused, nothing offered.
        let rig = Rig()
        let url = rig.url()
        try data.write(to: url)
        let key = DocumentKey.show(model.show.id)
        try rig.recovery.retainCheckpoint(try coder.encode(fixture.show, revision: 1), for: key)
        try rig.recovery.recordLocation(url, for: key)
        let opener = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: rig.recovery)
        guard case .refusedNewerFormat(found: found, supported: supported, _) = opener.open(url, key: key) else {
            Issue.record("a newer embedded map must be refused as unknown-newer, got \(opener.open(url, key: key))")
            return
        }
        guard case .refusedNewerFormat = opener.open(url) else {
            Issue.record("refused when opened by location too")
            return
        }
        #expect(throws: PublicationError.self) { try DocumentMigrator.show(publisher: rig.publisher).migrate(url, key: key) }
        #expect(try Data(contentsOf: url) == data, "never migrated, repaired or downsaved")
        // …and this build never publishes such a value.
        do { _ = try coder.encode(model, revision: 3); Issue.record("save must refuse") } catch { #expect(invalidPayloadCodes(error) == [.invalidAlignment]) }
    }

    /// The newer-map refusal happens before the checksum, like the envelope's schema check: a newer writer's bytes
    /// that this build's checksum disagrees with are still refused as newer, never as damaged.
    @Test func aNewerMapIsRefusedAsNewerEvenWhenTheChecksumDisagrees() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: unchecked.encode(try showWithNewerMap(nested: false), revision: 2)) as? [String: Any])
        object["checksum"] = "sha256:" + String(repeating: "0", count: 64)
        let data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        #expect(throws: PersistenceError.unknownNewerSchema(found: TimeMapSchema.currentVersion + 1, supported: TimeMapSchema.currentVersion)) {
            try coder.decode(data)
        }
        let rig = Rig()
        let url = rig.url()
        try data.write(to: url)
        guard case .refusedNewerFormat = DocumentOpener<JSONEnvelopeCoder<ShowDocumentModel>>.show(recovery: rig.recovery).open(url) else {
            Issue.record("expected unknown-newer refusal")
            return
        }
    }

    @Test func refusesUnknownKeysInsideAMap() throws {
        var version = try fixture.version(1, map: try fixture.map())
        guard case var .object(fields) = version.map else { Issue.record("map is not an object"); return }
        fields["futureField"] = .string("x")
        version.map = .object(fields)
        let data = try unchecked.encode(fixture.show(with: EpisodeAlignment(maps: [version])), revision: 1)
        do {
            _ = try coder.decode(data)
            Issue.record("opened a map with an unknown key")
        } catch {
            #expect(invalidPayloadCodes(error) == [.invalidAlignment])
        }
    }

    @Test func refusesMapsThatViolateTimeMapInvariants() throws {
        var version = try fixture.version(1, map: try fixture.map())
        // Drop the guest's spans: an occurrence with no spans is not a valid placement.
        version.map = Self.replacing(key: "spans", in: version.map, with: .array([]))
        let data = try unchecked.encode(fixture.show(with: EpisodeAlignment(maps: [version])), revision: 1)
        do {
            _ = try coder.decode(data)
            Issue.record("opened an invalid map")
        } catch {
            #expect(invalidPayloadCodes(error)?.contains(.invalidAlignment) == true)
        }
    }

    @Test func refusesNonCanonicalMapRepresentations() throws {
        var version = try fixture.version(1, map: try fixture.map())
        // A frame count written as a floating-point number decodes, but is not the canonical encoding.
        version.map = Self.replacing(key: "frameCount", in: version.map, with: .number(480_000))
        let model = fixture.show(with: EpisodeAlignment(maps: [version]))
        #expect(model.embeddedMapIssues().map(\.code) == [.invalidAlignment])
        do {
            _ = try coder.encode(model, revision: 1)
            Issue.record("published a non-canonical map")
        } catch {
            #expect(invalidPayloadCodes(error) == [.invalidAlignment])
        }
    }

    @Test func refusesInputsThatDoNotNameThePlacedSources() throws {
        let missingGuest = try fixture.version(1, map: try fixture.map(), sources: [fixture.host])
        let extra = try fixture.version(1, map: try fixture.map(), sources: [fixture.host, fixture.guest, SourceID()])
        for version in [missingGuest, extra] {
            let model = fixture.show(with: EpisodeAlignment(maps: [version]))
            do {
                _ = try coder.encode(model, revision: 1)
                Issue.record("published mismatched inputs")
            } catch {
                #expect(invalidPayloadCodes(error) == [.invalidAlignment])
            }
        }
    }

    @Test func refusesAnExplicitNullAlignment() throws {
        let data = try coder.encode(fixture.show, revision: 1)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var payload = try #require(object["payload"] as? [String: Any])
        var episodes = try #require(payload["episodes"] as? [[String: Any]])
        episodes[0]["alignment"] = NSNull()
        payload["episodes"] = episodes
        object["payload"] = payload
        let tampered = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: PersistenceError.unrecognizedContent) { try coder.decode(tampered) }
    }

    /// Removing a source the accepted map places leaves the map stale (computed elsewhere), never unopenable.
    @Test func removingAPlacedSourceKeepsTheShowOpenable() throws {
        var model = fixture.show(with: EpisodeAlignment(maps: [try fixture.version(1, map: try fixture.map())], acceptedRevision: 1))
        model.episodes[0].sources.removeAll { $0.id == fixture.guest }
        model.episodes[0].recorderGroups = []
        model.episodes[0].sources = model.episodes[0].sources.map {
            var s = $0
            s.placement = SourcePlacement()
            return s
        }
        #expect(try coder.decode(try coder.encode(model, revision: 1)).payload == model)
    }

    static func replacing(key: String, in json: EmbeddedJSON, with value: EmbeddedJSON) -> EmbeddedJSON {
        var replaced = false
        func walk(_ node: EmbeddedJSON) -> EmbeddedJSON {
            switch node {
            case var .object(fields):
                if !replaced, fields[key] != nil {
                    fields[key] = value
                    replaced = true
                    return .object(fields)
                }
                for name in fields.keys.sorted() { fields[name] = walk(fields[name]!) }
                return .object(fields)
            case let .array(items):
                return .array(items.map(walk))
            default:
                return node
            }
        }
        return walk(json)
    }
}
