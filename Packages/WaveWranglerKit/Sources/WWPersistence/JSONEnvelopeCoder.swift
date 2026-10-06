import CryptoKit
import Foundation
import WWCore

/// Versioned single-value JSON envelope:
///
/// ```json
/// {"checksum":"sha256:…","format":"com.brandonmartinez.wavewrangler.show","payload":{…},
///  "publicationID":"…UUID…","revision":3,"schemaVersion":1}
/// ```
///
/// Read order: strict JSON structure (well-formed, no duplicate keys anywhere) → version header `{format, schemaVersion}` only → format → schema range (unknown-newer
/// refusal happens before any version-specific field or the payload is decoded) → version-specific header
/// `{checksum, publicationID, revision}` → revision → payload decode → checksum → no unrecognized content
/// → semantic validation. `{format, schemaVersion}` is the only envelope shape frozen across versions.
///
/// `revision` is an ordering hint; `publicationID` (fresh per write) and `checksum` identify a publication. The checksum is SHA-256 over
/// the canonical encoding of the payload (sorted keys); it is integrity bookkeeping, not authenticity.
///
/// This coder only maps values to bytes. Publication (staging, prior-checkpoint retention, coordinated
/// replacement, acknowledgement) and recovery are separate responsibilities owned by persistence.
public struct JSONEnvelopeCoder<Payload: Codable & Sendable>: CanonicalDocumentCoding {
    public typealias Validator = @Sendable (_ payload: Payload, _ schemaVersion: Int) -> [ValidationIssue]

    public let format: DocumentFormat
    private let validate: Validator

    public init(format: DocumentFormat, validate: @escaping Validator) {
        self.format = format
        self.validate = validate
    }

    public func decode(_ data: Data) throws(PersistenceError) -> DecodedDocument<Payload> {
        // Strict structure first: duplicate keys would make envelope fields (revision, schemaVersion) ambiguous.
        do {
            try StrictJSON.validate(data)
        } catch let .duplicateKey(key) {
            throw .malformed("Duplicate key \"\(key)\"")
        } catch {
            throw .malformed("Malformed JSON")
        }
        let decoder = Self.makeDecoder()
        let version: VersionHeader
        do {
            version = try decoder.decode(VersionHeader.self, from: data)
        } catch {
            throw .malformed("Unreadable envelope header: \(error.localizedDescription)")
        }
        guard version.format == format.identifier else {
            throw .formatMismatch(expected: format.identifier, found: version.format)
        }
        guard version.schemaVersion <= format.currentSchemaVersion else {
            throw .unknownNewerSchema(found: version.schemaVersion, supported: format.currentSchemaVersion)
        }
        guard version.schemaVersion >= format.minimumReadableSchemaVersion else {
            throw .unsupportedOlderSchema(found: version.schemaVersion, minimum: format.minimumReadableSchemaVersion)
        }

        let header: PublicationHeader
        do {
            header = try decoder.decode(PublicationHeader.self, from: data)
        } catch {
            throw .malformed("Unreadable envelope header: \(error.localizedDescription)")
        }
        guard header.revision >= 1 else { throw .invalidRevision(header.revision) }

        let payload: Payload
        let rawPayload: JSONValue
        do {
            payload = try decoder.decode(PayloadBox<Payload>.self, from: data).payload
            rawPayload = try decoder.decode(PayloadBox<JSONValue>.self, from: data).payload
        } catch {
            throw .malformed("Unreadable payload: \(error.localizedDescription)")
        }
        let canonicalBytes = try Self.canonicalBytes(of: payload)
        guard Self.checksum(of: canonicalBytes) == header.checksum else { throw .checksumMismatch }
        // The typed decode ignores unrecognized keys; refuse rather than silently dropping them on next save.
        guard (try? decoder.decode(JSONValue.self, from: canonicalBytes)) == rawPayload else {
            throw .unrecognizedContent
        }

        let issues = validate(payload, version.schemaVersion)
        guard issues.isEmpty else { throw .invalidPayload(issues) }
        return DecodedDocument(
            payload: payload,
            publication: PublicationStamp(revision: header.revision, publicationID: header.publicationID, checksum: header.checksum)
        )
    }

    public func encodeDocument(_ payload: Payload, revision: Int, publicationID: UUID) throws(PersistenceError) -> EncodedDocument {
        guard revision >= 1 else { throw .invalidRevision(revision) }
        let issues = validate(payload, format.currentSchemaVersion)
        guard issues.isEmpty else { throw .invalidPayload(issues) }
        let publication = PublicationStamp(
            revision: revision,
            publicationID: publicationID,
            checksum: Self.checksum(of: try Self.canonicalBytes(of: payload))
        )
        let envelope = Envelope(
            checksum: publication.checksum,
            format: format.identifier,
            payload: payload,
            publicationID: publicationID,
            revision: revision,
            schemaVersion: format.currentSchemaVersion
        )
        do {
            return EncodedDocument(data: try Self.makeEncoder().encode(envelope), publication: publication)
        } catch {
            throw .encodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Canonical encoding

    static func canonicalBytes(of payload: Payload) throws(PersistenceError) -> Data {
        do {
            return try makeEncoder().encode(payload)
        } catch {
            throw .encodingFailed(error.localizedDescription)
        }
    }

    static func checksum(of canonicalBytes: Data) -> String {
        "sha256:" + SHA256.hash(data: canonicalBytes).map { String(format: "%02x", $0) }.joined()
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CanonicalDate.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = CanonicalDate.date(from: string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp \(string)")
            }
            return date
        }
        return decoder
    }

    /// The only envelope fields whose shape is frozen across schema versions.
    private struct VersionHeader: Decodable {
        let format: String
        let schemaVersion: Int
    }

    /// Version-specific publication fields, decoded only after the schema version is supported.
    private struct PublicationHeader: Decodable {
        let checksum: String
        let publicationID: UUID
        let revision: Int
    }

    private struct PayloadBox<Value: Decodable>: Decodable {
        let payload: Value
    }

    private struct Envelope: Encodable {
        let checksum: String
        let format: String
        let payload: Payload
        let publicationID: UUID
        let revision: Int
        let schemaVersion: Int
    }
}

/// Untyped JSON tree used to detect content the typed model would silently drop.
enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !array.isAtEnd { values.append(try array.decode(JSONValue.self)) }
            self = .array(values)
            return
        }
        if let object = try? decoder.container(keyedBy: AnyKey.self) {
            var values: [String: JSONValue] = [:]
            for key in object.allKeys { values[key.stringValue] = try object.decode(JSONValue.self, forKey: key) }
            self = .object(values)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Canonical timestamps are ISO-8601 UTC with exactly three fractional digits (`2026-10-04T12:00:00.123Z`).
///
/// Values are rounded to whole milliseconds with integer arithmetic so that decode → encode is byte-stable
/// (Foundation's fractional formatting truncates binary floating-point values, which would break checksums).
enum CanonicalDate {
    private static let wholeSeconds = Date.ISO8601FormatStyle()

    static func string(from date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = milliseconds.quotientAndRemainder(dividingBy: 1000)
        let (wholeSeconds, millis) = seconds.remainder < 0
            ? (seconds.quotient - 1, seconds.remainder + 1000)
            : (seconds.quotient, seconds.remainder)
        let base = Date(timeIntervalSince1970: TimeInterval(wholeSeconds)).formatted(Self.wholeSeconds)
        return String(base.dropLast()) + "." + String(format: "%03lld", millis) + "Z"
    }

    static func date(from string: String) -> Date? {
        guard string.hasSuffix("Z"), let dot = string.lastIndex(of: ".") else { return nil }
        let fraction = string[string.index(after: dot)..<string.index(before: string.endIndex)]
        guard fraction.count == 3, fraction.allSatisfy(\.isASCII), let millis = Int64(fraction), millis >= 0,
              let base = try? Self.wholeSeconds.parse(String(string[..<dot]) + "Z")
        else { return nil }
        let whole = Int64(base.timeIntervalSince1970)
        return Date(timeIntervalSince1970: TimeInterval(whole * 1000 + millis) / 1000)
    }
}

extension JSONEnvelopeCoder where Payload == ShowDocumentModel {
    public static var show: JSONEnvelopeCoder<ShowDocumentModel> {
        JSONEnvelopeCoder(format: .show) { $0.validationIssues(expectedSchemaVersion: $1) + $0.embeddedMapIssues() }
    }
}

extension JSONEnvelopeCoder where Payload == LibraryModel {
    public static var library: JSONEnvelopeCoder<LibraryModel> {
        JSONEnvelopeCoder(format: .library) { $0.validationIssues(expectedSchemaVersion: $1) }
    }
}
