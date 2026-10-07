import Foundation

/// Persisted alignment state of one episode (WW-020, M2-C3/C4/C5): an append-only list of versioned
/// positive maps plus which revision the user accepted.
///
/// WWCore cannot depend on `WWTimeMap`, so each map is stored as the exact strict JSON that
/// `WWTimeMap.AlignedTimelineMap` encodes (`EmbeddedJSON`). WWPersistence strictly decodes every embedded
/// map when it opens or saves a show (unknown keys, unknown-newer `timeMapSchemaVersion` and violated map
/// invariants are refused), and `WWDerived` is the typed API over these values.
///
/// Maps refer to recorder groups, epochs, sources and occurrences by logical ID. Ordinary episode edits
/// (deleting a source, regrouping) never make a show unopenable: a map whose references no longer match the
/// episode is reported *stale* by `WWDerived`, never silently repaired or dropped.
public struct EpisodeAlignment: Sendable, Equatable, Codable {
    /// Strictly increasing by `revision`; never rewritten in place.
    public var maps: [TimeMapVersion]
    /// The revision the user accepted, if any. Accepting a different revision marks dependent derived work stale.
    public var acceptedRevision: Int?

    public init(maps: [TimeMapVersion] = [], acceptedRevision: Int? = nil) {
        self.maps = maps
        self.acceptedRevision = acceptedRevision
    }

    public func map(revision: Int) -> TimeMapVersion? {
        maps.first { $0.revision == revision }
    }

    public var acceptedMap: TimeMapVersion? {
        acceptedRevision.flatMap { map(revision: $0) }
    }

    public var latestRevision: Int? { maps.last?.revision }
}

/// One immutable map revision with the inputs it was built from.
public struct TimeMapVersion: Sendable, Equatable, Codable {
    /// 1-based, unique and increasing within the episode.
    public var revision: Int
    /// The earlier revision this one corrects, if any (e.g. a manual correction of a proposal).
    public var derivedFrom: Int?
    public var inputs: TimeMapInputs
    /// The strict `WWTimeMap.AlignedTimelineMap` encoding.
    public var map: EmbeddedJSON

    public init(revision: Int, derivedFrom: Int? = nil, inputs: TimeMapInputs, map: EmbeddedJSON) {
        self.revision = revision
        self.derivedFrom = derivedFrom
        self.inputs = inputs
        self.map = map
    }
}

/// What a map revision was computed from. Part of the M2-C5 key of anything derived from the map.
public struct TimeMapInputs: Sendable, Equatable, Codable {
    /// One entry per distinct source placed in the map, in the map's placement order.
    public var sources: [TimeMapSourceInput]
    /// The estimator/correction recipe; absent for maps entered entirely by hand.
    public var recipe: RecipeReference?

    public init(sources: [TimeMapSourceInput], recipe: RecipeReference? = nil) {
        self.sources = sources
        self.recipe = recipe
    }
}

public struct TimeMapSourceInput: Sendable, Equatable, Codable {
    public var sourceID: SourceID
    /// `WWDecode.FormatInterpretation.currentVersion` of the decode the map used; absent when no content was decoded.
    public var formatInterpretationVersion: Int?
    /// A consent-gated decoded-content digest (`WWDerived`), if one was computed. Never a file hash.
    public var contentDigest: String?

    public init(sourceID: SourceID, formatInterpretationVersion: Int? = nil, contentDigest: String? = nil) {
        self.sourceID = sourceID
        self.formatInterpretationVersion = formatInterpretationVersion
        self.contentDigest = contentDigest
    }
}

/// A named, versioned recipe (estimator or render). Bumping `revision` invalidates everything derived with it.
public struct RecipeReference: Sendable, Hashable, Codable {
    public var name: String
    public var revision: Int

    public init(name: String, revision: Int) {
        self.name = name
        self.revision = revision
    }
}

/// A JSON value stored verbatim inside the show document. Integers and non-integral numbers are kept apart so
/// exact integer fields (frame counts) never pass through `Double`; exact rationals and 128-bit values are
/// strings in the time-map encoding.
public enum EmbeddedJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([EmbeddedJSON])
    case object([String: EmbeddedJSON])

    public init(from decoder: any Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var values: [EmbeddedJSON] = []
            while !array.isAtEnd { values.append(try array.decode(EmbeddedJSON.self)) }
            self = .array(values)
            return
        }
        if let object = try? decoder.container(keyedBy: Key.self) {
            var values: [String: EmbeddedJSON] = [:]
            for key in object.allKeys { values[key.stringValue] = try object.decode(EmbeddedJSON.self, forKey: key) }
            self = .object(values)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var c = encoder.singleValueContainer()
            try c.encodeNil()
        case let .bool(value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case let .integer(value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case let .number(value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case let .string(value):
            var c = encoder.singleValueContainer()
            try c.encode(value)
        case let .array(values):
            var c = encoder.unkeyedContainer()
            for value in values { try c.encode(value) }
        case let .object(values):
            var c = encoder.container(keyedBy: Key.self)
            for (key, value) in values { try c.encode(value, forKey: Key(stringValue: key)) }
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
