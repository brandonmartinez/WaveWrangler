import Foundation

/// Version of the persisted time-map representation. Stored under the key `timeMapSchemaVersion` in
/// every top-level map. Decoding refuses any other version: a newer one is never partially read.
public enum TimeMapSchema {
    public static let currentVersion = 1
    static let versionKey = "timeMapSchemaVersion"
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension Decoder {
    /// A keyed container that refuses keys it does not know (a newer writer's data is never dropped).
    func strictContainer<K: CodingKey & CaseIterable>(keyedBy type: K.Type, typeName: String) throws -> KeyedDecodingContainer<K> {
        let dynamic = try container(keyedBy: DynamicCodingKey.self)
        let known = Set(K.allCases.map(\.stringValue))
        let unknown = dynamic.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        guard unknown.isEmpty else { throw TimeMapDecodingError.unknownKeys(type: typeName, keys: unknown) }
        return try container(keyedBy: K.self)
    }

    /// Reads and checks `timeMapSchemaVersion` *before* anything else, so a newer document is refused as
    /// newer rather than as malformed.
    func checkTimeMapSchemaVersion() throws {
        let dynamic = try container(keyedBy: DynamicCodingKey.self)
        let version = try dynamic.decode(Int.self, forKey: DynamicCodingKey(stringValue: TimeMapSchema.versionKey))
        if version > TimeMapSchema.currentVersion {
            throw TimeMapDecodingError.unknownNewerSchemaVersion(found: version, supported: TimeMapSchema.currentVersion)
        }
        guard version == TimeMapSchema.currentVersion else { throw TimeMapDecodingError.unsupportedSchemaVersion(version) }
    }
}
