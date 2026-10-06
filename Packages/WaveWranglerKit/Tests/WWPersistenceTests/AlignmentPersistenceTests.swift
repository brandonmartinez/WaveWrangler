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

    /// Schema bump discipline: WW-020 extends show schema 2 additively (an omitted optional field); the embedded
    /// map format is WWTimeMap schema 1. Changing either requires a C5 migration and new golden fixtures.
    @Test func schemaVersionsArePinned() {
        #expect(SchemaVersion.show == 2)
        #expect(TimeMapSchema.currentVersion == 1)
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

    @Test func showWithoutAlignmentKeepsItsSchema2Bytes() throws {
        let model = fixture.show
        let data = try coder.encode(model, revision: 1)
        #expect(!String(decoding: data, as: UTF8.self).contains("alignment"))
        #expect(try coder.decode(data).payload == model)
    }

    @Test func aSourceUsedTwiceIsOneInputWithTwoOccurrences() throws {
        let map = try fixture.map(guestOffset: 1, repeatGuestAt: 6)
        #expect(EmbeddedTimeMapCodec.placedSources(map) == [fixture.host, fixture.guest])
        let model = fixture.show(with: EpisodeAlignment(maps: [try fixture.version(1, map: map)]))
        #expect(try coder.decode(try coder.encode(model, revision: 1)).payload == model)
    }

    @Test func refusesAMapFromANewerTimeMapSchemaOnOpen() throws {
        var version = try fixture.version(1, map: try fixture.map())
        guard case var .object(fields) = version.map else { Issue.record("map is not an object"); return }
        fields["timeMapSchemaVersion"] = .integer(Int64(TimeMapSchema.currentVersion + 1))
        version.map = .object(fields)
        let model = fixture.show(with: EpisodeAlignment(maps: [version]))
        let data = try unchecked.encode(model, revision: 1)
        #expect(throws: PersistenceError.self) { try coder.decode(data) }
        do { _ = try coder.decode(data); Issue.record("open must refuse") } catch { #expect(invalidPayloadCodes(error) == [.invalidAlignment]) }
        // …and the same value is never published.
        do { _ = try coder.encode(model, revision: 2); Issue.record("save must refuse") } catch { #expect(invalidPayloadCodes(error) == [.invalidAlignment]) }
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
