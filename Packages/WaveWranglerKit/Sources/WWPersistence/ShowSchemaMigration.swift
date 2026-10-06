import Foundation
import WWCore

/// Show schema 1 → 2 (C5 migration, issue #63).
///
/// Schema 1 stored each speaker channel reference as a bare zero-based index and used index 0 as a
/// placeholder when the user had not stated a channel. Schema 2 stores an explicit `Knowledge<Int>`.
/// The upgrade rule, per reference `(source S, index n)` within its episode:
///
/// - `.known(n)` when S's `placement.channelLabels` states channel `n` (a user-stated channel, including a
///   stated channel 0, is kept);
/// - `.unknown` when `n == 0` and channel 0 is not stated for S (the schema 1 placeholder);
/// - otherwise `.known(n)`: an explicit nonzero index recorded through the generic API is kept as written.
///
/// Nothing is invented or dropped: every other byte of the payload is carried over unchanged, and the
/// mapping is one-to-one per source, so it cannot create a duplicate or conflicting reference.
///
/// A schema 1 show is never upgraded silently on open: `DocumentOpener` reports `.needsMigration(1)` and the
/// canonical file changes only through `DocumentMigrator.show(publisher:)` (C5: non-overwriting backup
/// first, independent expectations, then the ordinary C3 publication with the original bytes as the
/// expected base). The in-memory upgrade below is also used, read-only, to keep schema 1 recovery records
/// (retained checkpoints, unpublished edit checkpoints) offerable as whole values.
public enum ShowSchemaMigration {
    /// Older show schemas this build can migrate.
    public static let migratableSchemas: Set<Int> = [1]

    /// The registered migration steps (schema 1 → current).
    public static var steps: [MigrationStep<ShowDocumentModel>] {
        [MigrationStep(
            fromSchema: 1,
            migrate: { data in
                let decoded = try decodeSchema1(data)
                return (decoded.payload, decoded.revision)
            },
            expectations: { original, migrated in expectationFailures(original: original, migrated: migrated) }
        )]
    }

    /// Decodes a current show, or — read-only, for recovery offers only — a supported older show upgraded in
    /// memory. Never use this to open the canonical file for editing (that requires the consented migration).
    public static func decodeUpgradingOlder(_ data: Data) throws(PersistenceError) -> DecodedDocument<ShowDocumentModel> {
        do {
            return try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(data)
        } catch .unsupportedOlderSchema(found: 1, minimum: _) {
            return try decodeSchema1(data)
        }
    }

    // MARK: - Schema 1 reader

    static let schema1Format = DocumentFormat(
        identifier: DocumentFormat.show.identifier,
        filenameExtension: DocumentFormat.show.filenameExtension,
        currentSchemaVersion: 1,
        minimumReadableSchemaVersion: 1
    )

    /// Strictly decodes a schema 1 show (format, checksum, no unrecognized content, schema 1 payload version)
    /// and upgrades it; the upgraded value must pass full current validation.
    static func decodeSchema1(_ data: Data) throws(PersistenceError) -> DecodedDocument<ShowDocumentModel> {
        let v1 = JSONEnvelopeCoder<ShowDocumentModelV1>(format: schema1Format) { payload, schema in
            payload.schemaVersion == schema ? [] : [ValidationIssue(.schemaVersionMismatch, "payload \(payload.schemaVersion) != expected \(schema)")]
        }
        let decoded = try v1.decode(data)
        let upgraded = upgrade(decoded.payload)
        let issues = upgraded.validationIssues()
        guard issues.isEmpty else { throw .invalidPayload(issues) }
        return DecodedDocument(payload: upgraded, publication: decoded.publication)
    }

    static func upgrade(_ v1: ShowDocumentModelV1) -> ShowDocumentModel {
        ShowDocumentModel(
            schemaVersion: SchemaVersion.show,
            show: v1.show,
            speakers: v1.speakers,
            episodes: v1.episodes.map { episode in
                Episode(
                    id: episode.id,
                    title: episode.title,
                    number: episode.number,
                    recordedOn: episode.recordedOn,
                    publishedOn: episode.publishedOn,
                    notes: episode.notes,
                    status: episode.status,
                    recorderGroups: episode.recorderGroups,
                    sources: episode.sources,
                    speakerAssignments: episode.speakerAssignments.map { assignment in
                        SpeakerAssignment(
                            speakerID: assignment.speakerID,
                            primary: assignment.primary.map { upgrade($0, in: episode.sources) },
                            primaryConfirmation: assignment.primaryConfirmation,
                            backups: assignment.backups.map { upgrade($0, in: episode.sources) }
                        )
                    }
                )
            },
            history: v1.history
        )
    }

    static func upgrade(_ reference: ChannelReferenceV1, in sources: [SourceRecord]) -> ChannelReference {
        let stated = sources.first { $0.id == reference.sourceID }?.placement.channelLabels.contains { $0.channel == reference.channel } ?? false
        let isPlaceholder = reference.channel == 0 && !stated
        return ChannelReference(sourceID: reference.sourceID, channel: isPlaceholder ? .unknown : .known(reference.channel))
    }

    // MARK: - Independent expectations

    /// Specified on the raw JSON, independently of the typed upgrade: the migrated payload must equal the
    /// original payload with only `schemaVersion` set to 2 and each speaker reference's integer `channel`
    /// replaced by `{"state":"unknown"}` (index 0 not stated for that source) or `{"state":"known","value":n}`.
    static func expectationFailures(original: Data, migrated: ShowDocumentModel) -> [String] {
        guard let envelope = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
              var payload = envelope["payload"] as? [String: Any],
              let episodes = payload["episodes"] as? [[String: Any]]
        else { return ["original payload is not a JSON object with episodes"] }
        var failures: [String] = []
        func converted(_ reference: Any?, stated: [String: Set<Int>]) -> [String: Any]? {
            guard var object = reference as? [String: Any], let source = object["sourceID"] as? String,
                  let number = object["channel"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
            else {
                failures.append("schema 1 reference is not {sourceID, integer channel}")
                return nil
            }
            let index = number.intValue
            object["channel"] = index == 0 && !(stated[source]?.contains(0) ?? false)
                ? ["state": "unknown"] as [String: Any]
                : ["state": "known", "value": index] as [String: Any]
            return object
        }
        payload["episodes"] = episodes.map { episode -> [String: Any] in
            var episode = episode
            var stated: [String: Set<Int>] = [:]
            for source in episode["sources"] as? [[String: Any]] ?? [] {
                guard let id = source["id"] as? String else { continue }
                let labels = (source["placement"] as? [String: Any])?["channelLabels"] as? [[String: Any]] ?? []
                stated[id] = Set(labels.compactMap { ($0["channel"] as? NSNumber)?.intValue })
            }
            episode["speakerAssignments"] = (episode["speakerAssignments"] as? [[String: Any]] ?? []).map { assignment in
                var assignment = assignment
                if let primary = assignment["primary"] { assignment["primary"] = converted(primary, stated: stated) }
                assignment["backups"] = (assignment["backups"] as? [Any] ?? []).compactMap { converted($0, stated: stated) }
                return assignment
            }
            return episode
        }
        payload["schemaVersion"] = SchemaVersion.show
        guard failures.isEmpty else { return failures }
        guard let migratedBytes = try? JSONEnvelopeCoder<ShowDocumentModel>.canonicalBytes(of: migrated),
              let actual = try? JSONSerialization.jsonObject(with: migratedBytes) as? [String: Any]
        else { return ["migrated payload could not be encoded"] }
        if !NSDictionary(dictionary: payload).isEqual(to: actual) {
            failures.append("migrated payload differs from the schema 1 payload beyond the stated-channel conversion")
        }
        return failures
    }

    // MARK: - Schema 1 payload (mirror of the M1 types; only channel references differ from schema 2)

    struct ShowDocumentModelV1: Sendable, Codable {
        var schemaVersion: Int
        var show: Show
        var speakers: [Speaker]
        var episodes: [EpisodeV1]
        var history: EditHistory
    }

    struct EpisodeV1: Sendable, Codable {
        var id: EpisodeID
        var title: String
        var number: Int?
        var recordedOn: CalendarDay?
        var publishedOn: CalendarDay?
        var notes: String
        var status: EpisodeStatus
        var recorderGroups: [RecorderGroup]
        var sources: [SourceRecord]
        var speakerAssignments: [SpeakerAssignmentV1]
    }

    struct SpeakerAssignmentV1: Sendable, Codable {
        var speakerID: SpeakerID
        var primary: ChannelReferenceV1?
        var primaryConfirmation: Confirmation
        var backups: [ChannelReferenceV1]
    }

    struct ChannelReferenceV1: Sendable, Codable {
        var sourceID: SourceID
        /// Schema 1: a bare zero-based index; 0 doubled as the "not stated" placeholder.
        var channel: Int
    }
}

extension DocumentMigrator where Coder == JSONEnvelopeCoder<ShowDocumentModel> {
    /// The show migrator (C5): schema 1 → current through `publisher` (which must have a recovery store for
    /// the non-overwriting backup).
    public static func show(publisher: DocumentPublisher<JSONEnvelopeCoder<ShowDocumentModel>>) -> DocumentMigrator<JSONEnvelopeCoder<ShowDocumentModel>> {
        DocumentMigrator(publisher: publisher, steps: ShowSchemaMigration.steps)
    }
}
