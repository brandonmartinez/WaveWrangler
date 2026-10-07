import Foundation
import Testing
@testable import WWCore

/// Structural rules for persisted map history (WW-020). Map bytes are opaque to WWCore; WWPersistence
/// validates them with WWTimeMap.
@Suite("Episode alignment structure")
struct EpisodeAlignmentValidationTests {
    let source = SourceID()

    func version(_ revision: Int, derivedFrom: Int? = nil, inputs: [TimeMapSourceInput]? = nil, recipe: RecipeReference? = nil) -> TimeMapVersion {
        TimeMapVersion(
            revision: revision,
            derivedFrom: derivedFrom,
            inputs: TimeMapInputs(sources: inputs ?? [TimeMapSourceInput(sourceID: source)], recipe: recipe),
            map: .object(["placeholder": .integer(Int64(revision))])
        )
    }

    func issues(_ alignment: EpisodeAlignment) -> [ValidationIssue] {
        let model = ShowDocumentModel(show: Show(title: "S"), episodes: [Episode(title: "E", alignment: alignment)])
        return model.validationIssues()
    }

    @Test func wellFormedHistoryHasNoIssues() {
        let alignment = EpisodeAlignment(
            maps: [
                version(1, recipe: RecipeReference(name: "manual", revision: 1)),
                version(2, derivedFrom: 1, inputs: [TimeMapSourceInput(sourceID: source, formatInterpretationVersion: 1, contentDigest: "decoded-pcm-sha256:ab")]),
                version(5, derivedFrom: 2),
            ],
            acceptedRevision: 2
        )
        #expect(issues(alignment).isEmpty)
        #expect(alignment.acceptedMap?.revision == 2)
        #expect(alignment.latestRevision == 5)
    }

    @Test func noAlignmentIsOmittedNotEmpty() throws {
        #expect(issues(EpisodeAlignment()).map(\.code) == [.invalidAlignment])
        let encoded = try JSONEncoder().encode(Episode(title: "E"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("alignment"))
    }

    @Test(arguments: [
        ("non-increasing revisions", EpisodeAlignment(maps: [TimeMapVersion(revision: 2, inputs: TimeMapInputs(sources: []), map: .null), TimeMapVersion(revision: 2, inputs: TimeMapInputs(sources: []), map: .null)])),
        ("revision zero", EpisodeAlignment(maps: [TimeMapVersion(revision: 0, inputs: TimeMapInputs(sources: []), map: .null)])),
        ("derived from later", EpisodeAlignment(maps: [TimeMapVersion(revision: 1, derivedFrom: 2, inputs: TimeMapInputs(sources: []), map: .null), TimeMapVersion(revision: 2, inputs: TimeMapInputs(sources: []), map: .null)])),
        ("derived from missing", EpisodeAlignment(maps: [TimeMapVersion(revision: 3, derivedFrom: 2, inputs: TimeMapInputs(sources: []), map: .null)])),
        ("accepted missing", EpisodeAlignment(maps: [TimeMapVersion(revision: 1, inputs: TimeMapInputs(sources: []), map: .null)], acceptedRevision: 4)),
        ("bad recipe revision", EpisodeAlignment(maps: [TimeMapVersion(revision: 1, inputs: TimeMapInputs(sources: [], recipe: RecipeReference(name: "x", revision: 0)), map: .null)])),
        ("blank recipe name", EpisodeAlignment(maps: [TimeMapVersion(revision: 1, inputs: TimeMapInputs(sources: [], recipe: RecipeReference(name: " ", revision: 1)), map: .null)])),
    ])
    func refusesInconsistentHistory(_ name: String, _ alignment: EpisodeAlignment) {
        #expect(issues(alignment).map(\.code) == [.invalidAlignment], "\(name)")
    }

    @Test func refusesBadInputs() {
        let repeated = EpisodeAlignment(maps: [version(1, inputs: [TimeMapSourceInput(sourceID: source), TimeMapSourceInput(sourceID: source)])])
        let badFormat = EpisodeAlignment(maps: [version(1, inputs: [TimeMapSourceInput(sourceID: source, formatInterpretationVersion: 0)])])
        let emptyDigest = EpisodeAlignment(maps: [version(1, inputs: [TimeMapSourceInput(sourceID: source, contentDigest: "")])])
        for alignment in [repeated, badFormat, emptyDigest] {
            #expect(issues(alignment).map(\.code) == [.invalidAlignment])
        }
    }

    /// A map that names a source, group or epoch the episode no longer has is *stale*, not invalid: the show
    /// must stay openable after the user removes a source (staleness is computed by WWDerived).
    @Test func mapsReferencingRemovedStructureStayValid() {
        let alignment = EpisodeAlignment(maps: [version(1, inputs: [TimeMapSourceInput(sourceID: SourceID())])], acceptedRevision: 1)
        #expect(issues(alignment).isEmpty)
    }

    @Test func embeddedJSONRoundTripsDistinguishingIntegersAndNumbers() throws {
        let value = EmbeddedJSON.object([
            "a": .array([.integer(5), .number(0.25), .string("1/3"), .bool(true), .null]),
            "b": .integer(Int64.max),
            "c": .integer(-48000),
        ])
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(EmbeddedJSON.self, from: data) == value)
    }
}
