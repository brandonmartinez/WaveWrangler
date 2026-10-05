import Foundation

/// A value that may not have been observed yet.
///
/// M1 never decodes or inspects audio, so recorded facts such as duration, channel count and sample rate
/// start as `.unknown` and stay that way until a later, explicitly permitted inspection observes them.
/// `.unknown` is deliberately distinct from any sentinel value (0, nil-as-default, etc.).
public enum Knowledge<Value: Sendable & Codable & Equatable>: Sendable, Equatable, Codable {
    case unknown
    case known(Value)

    public var value: Value? {
        if case let .known(value) = self { return value }
        return nil
    }

    public var isKnown: Bool { value != nil }

    private enum CodingKeys: String, CodingKey {
        case state
        case value
    }

    private enum State: String, Codable {
        case unknown
        case known
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(State.self, forKey: .state) {
        case .unknown:
            self = .unknown
        case .known:
            self = .known(try container.decode(Value.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unknown:
            try container.encode(State.unknown, forKey: .state)
        case let .known(value):
            try container.encode(State.known, forKey: .state)
            try container.encode(value, forKey: .value)
        }
    }
}

/// Whether a human has confirmed a fact or it is still a provisional suggestion.
public enum Confirmation: String, Sendable, Codable, Equatable, CaseIterable {
    case provisional
    case userConfirmed
}

/// A timezone-free calendar day (`YYYY-MM-DD`) for episode recording/publication dates.
public struct CalendarDay: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = year
        components.month = month
        components.day = day
        guard (1...9999).contains(year), components.isValidDate else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let day = CalendarDay(isoString: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid calendar day \(string)")
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
