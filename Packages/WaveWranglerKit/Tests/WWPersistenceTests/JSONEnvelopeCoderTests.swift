import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("JSON envelope coder")
struct JSONEnvelopeCoderTests {
    let coder = JSONEnvelopeCoder<ShowDocumentModel>.show

    func sampleModel() -> ShowDocumentModel {
        let speaker = Speaker(name: "Host")
        let source = SourceRecord(displayNameHint: "synthetic", observations: SourceObservations(channelCount: .known(1)))
        let episode = Episode(
            title: "Episode 1",
            number: 1,
            recordedOn: CalendarDay(year: 2026, month: 10, day: 1),
            sources: [source],
            speakerAssignments: [SpeakerAssignment(speakerID: speaker.id, primary: ChannelReference(sourceID: source.id, channel: 0), primaryConfirmation: .userConfirmed)]
        )
        let history = EditHistory().recording(EditRecord(actionName: "Add Episode", timestamp: Date(timeIntervalSince1970: 1_790_000_000.123)))
        return ShowDocumentModel(show: Show(title: "Show / Title"), speakers: [speaker], episodes: [episode], history: history)
    }

    func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test func roundTripsWithRevisionAndEnvelopeFields() throws {
        let model = sampleModel()
        let encoded = try coder.encode(model, revision: 3)
        let decoded = try coder.decode(encoded)
        #expect(decoded.payload == model)
        #expect(decoded.revision == 3)

        let object = try json(encoded)
        #expect(object["format"] as? String == "com.brandonmartinez.wavewrangler.show")
        #expect(object["schemaVersion"] as? Int == SchemaVersion.show)
        #expect(object["revision"] as? Int == 3)
        #expect((object["checksum"] as? String)?.hasPrefix("sha256:") == true)
        #expect(object["payload"] is [String: Any])
    }

    @Test func encodingIsDeterministicForAGivenPublication() throws {
        let model = sampleModel()
        let id = UUID()
        #expect(try coder.encode(model, revision: 1, publicationID: id) == coder.encode(model, revision: 1, publicationID: id))
    }

    @Test func publicationIdentityDistinguishesSameRevisionWrites() throws {
        let model = sampleModel()
        let first = try coder.encodeDocument(model, revision: 4, publicationID: UUID())
        let second = try coder.encodeDocument(model, revision: 4, publicationID: UUID())
        #expect(first.publication.revision == second.publication.revision)
        #expect(first.publication.checksum == second.publication.checksum)
        #expect(first.publication != second.publication)

        let decoded = try coder.decode(first.data)
        #expect(decoded.publication == first.publication)
        #expect(decoded.revision == 4)
        #expect(try json(first.data)["publicationID"] as? String == first.publication.publicationID.uuidString)

        var edited = model
        edited.show.title = "Edited elsewhere"
        let divergent = try coder.encodeDocument(edited, revision: 4, publicationID: UUID())
        #expect(divergent.publication.checksum != first.publication.checksum)
    }

    @Test func refusesCurrentVersionWithoutPublicationID() throws {
        var object = try json(coder.encode(sampleModel(), revision: 1))
        object.removeValue(forKey: "publicationID")
        #expect {
            try coder.decode(data(object))
        } throws: { error in
            if case .malformed = error as? PersistenceError { return true }
            return false
        }
    }

    @Test func refusesUnknownNewerSchemaBeforeDecodingPayload() throws {
        var object = try json(coder.encode(sampleModel(), revision: 1))
        object["schemaVersion"] = SchemaVersion.show + 1
        object["payload"] = ["something": "from the future"]
        #expect(throws: PersistenceError.unknownNewerSchema(found: SchemaVersion.show + 1, supported: SchemaVersion.show)) {
            try coder.decode(data(object))
        }
    }

    @Test func reportsNewerVersionEvenWhenVersionSpecificHeaderShapeDiffers() throws {
        let future: [String: Any] = [
            "format": DocumentFormat.show.identifier,
            "schemaVersion": SchemaVersion.show + 1,
            "revision": ["lamport": 7, "device": "synthetic"],
            "integrity": ["algorithm": "blake3", "digest": "00"],
            "payload": ["shape": "unknown"],
        ]
        #expect(throws: PersistenceError.unknownNewerSchema(found: SchemaVersion.show + 1, supported: SchemaVersion.show)) {
            try coder.decode(data(future))
        }
    }

    @Test func refusesUnsupportedOlderSchema() throws {
        var object = try json(coder.encode(sampleModel(), revision: 1))
        object["schemaVersion"] = 0
        #expect(throws: PersistenceError.unsupportedOlderSchema(found: 0, minimum: 1)) { try coder.decode(data(object)) }
    }

    @Test func refusesOtherFormats() throws {
        let library = try JSONEnvelopeCoder<LibraryModel>.library.encode(LibraryModel(), revision: 1)
        #expect(throws: PersistenceError.formatMismatch(expected: DocumentFormat.show.identifier, found: DocumentFormat.library.identifier)) {
            try coder.decode(library)
        }
    }

    @Test func refusesTamperedPayload() throws {
        var object = try json(coder.encode(sampleModel(), revision: 1))
        var payload = try #require(object["payload"] as? [String: Any])
        var show = try #require(payload["show"] as? [String: Any])
        show["title"] = "Tampered"
        payload["show"] = show
        object["payload"] = payload
        #expect(throws: PersistenceError.checksumMismatch) { try coder.decode(data(object)) }
    }

    @Test func refusesUnknownExtraPayloadKeys() throws {
        var object = try json(coder.encode(sampleModel(), revision: 1))
        var payload = try #require(object["payload"] as? [String: Any])
        payload["futureField"] = true
        object["payload"] = payload
        #expect(throws: PersistenceError.unrecognizedContent) { try coder.decode(data(object)) }

        var nested = try json(coder.encode(sampleModel(), revision: 1))
        var nestedPayload = try #require(nested["payload"] as? [String: Any])
        var episodes = try #require(nestedPayload["episodes"] as? [[String: Any]])
        episodes[0]["transcript"] = ["from": "the future"]
        nestedPayload["episodes"] = episodes
        nested["payload"] = nestedPayload
        #expect(throws: PersistenceError.unrecognizedContent) { try coder.decode(data(nested)) }
    }

    @Test func refusesInvalidRevisions() throws {
        #expect(throws: PersistenceError.invalidRevision(0)) { try coder.encode(sampleModel(), revision: 0) }
        var object = try json(coder.encode(sampleModel(), revision: 1))
        object["revision"] = -4
        #expect(throws: PersistenceError.invalidRevision(-4)) { try coder.decode(data(object)) }
    }

    @Test(arguments: [Data(), Data("{}".utf8), Data("not json".utf8), Data("[1,2]".utf8)])
    func refusesMalformedInput(_ input: Data) {
        #expect {
            try coder.decode(input)
        } throws: { error in
            if case .malformed = error as? PersistenceError { return true }
            return false
        }
    }

    @Test func refusesSemanticallyInvalidPayloadOnBothPaths() throws {
        var model = sampleModel()
        model.episodes.append(model.episodes[0])
        #expect {
            try coder.encode(model, revision: 1)
        } throws: { error in
            if case .invalidPayload = error as? PersistenceError { return true }
            return false
        }
    }

    @Test func timestampsRoundTripAtMillisecondPrecision() throws {
        let decoded = try coder.decode(coder.encode(sampleModel(), revision: 1))
        let timestamp = try #require(decoded.payload.history.entries.first?.timestamp)
        #expect(abs(timestamp.timeIntervalSince1970 - 1_790_000_000.123) < 0.0005)
    }

    @Test func libraryRoundTrips() throws {
        let show = ShowID()
        let library = LibraryModel(
            entries: [LibraryShowEntry(showID: show, alias: "Main", lastKnownTitle: "Show",
                                       lastKnownPublication: PublicationStamp(revision: 2, publicationID: UUID(), checksum: "sha256:00"),
                                       unavailable: UnavailableRecord(note: "Folder offline", recordedAt: Date(timeIntervalSince1970: 1_000)))],
            collections: [LibraryCollection(name: "Active", showIDs: [show])],
            recentShowIDs: [show]
        )
        let coder = JSONEnvelopeCoder<LibraryModel>.library
        let decoded = try coder.decode(coder.encode(library, revision: 5)).payload
        #expect(decoded == library)
        #expect(decoded.entries.first?.lastKnownRevision == 2)
    }

    @Test func errorsAreUserPresentable() {
        let error = PersistenceError.unknownNewerSchema(found: 2, supported: 1)
        #expect(error.errorDescription?.contains("newer version") == true)
        #expect(error.recoverySuggestion?.contains("will not edit or save") == true)
    }
}

@Suite("Canonical timestamps")
struct CanonicalDateTests {
    @Test(arguments: [0.0, 0.001, 1_790_000_000.123, 1_790_000_000.9996, -1.5, 1_234_567_890.5])
    func formatIsStableAcrossDecodeEncode(_ seconds: Double) throws {
        let string = CanonicalDate.string(from: Date(timeIntervalSince1970: seconds))
        let decoded = try #require(CanonicalDate.date(from: string))
        #expect(CanonicalDate.string(from: decoded) == string)
        #expect(abs(decoded.timeIntervalSince1970 - seconds) <= 0.0005)
    }

    @Test func formatsExpectedShape() {
        #expect(CanonicalDate.string(from: Date(timeIntervalSince1970: 1.5)) == "1970-01-01T00:00:01.500Z")
        #expect(CanonicalDate.string(from: Date(timeIntervalSince1970: -1.5)) == "1969-12-31T23:59:58.500Z")
    }

    @Test(arguments: ["1970-01-01T00:00:01Z", "1970-01-01T00:00:01.5Z", "1970-01-01T00:00:01.500", "garbage", "1970-01-01T00:00:01.-50Z"])
    func rejectsNonCanonicalStrings(_ string: String) {
        #expect(CanonicalDate.date(from: string) == nil)
    }
}
