import Foundation

/// Portable effect identity, independent of whether the component is installed on this device.
/// Four-character codes use their unsigned big-endian numeric representation.
public struct AudioUnitComponentIdentity: Sendable, Equatable, Codable {
    public var type: UInt32
    public var subtype: UInt32
    public var manufacturer: UInt32

    public init(type: UInt32, subtype: UInt32, manufacturer: UInt32) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
    }

    public var isValid: Bool {
        // Only effects ('aufx') and music effects ('aumf'); instruments and generators are not inserts.
        (type == 0x61756678 || type == 0x61756D66) && subtype != 0 && manufacturer != 0
    }
}

/// A stable insert slot. Missing units retain the entire value, including opaque document-state bytes.
public struct AudioUnitSlot: Sendable, Equatable, Codable, Identifiable {
    public var id: AudioUnitSlotID
    public var component: AudioUnitComponentIdentity
    public var bypassed: Bool
    public var productName: String?
    public var version: String?
    /// A serialized property-list dictionary from the unit's document state, not an object archive.
    /// `nil` requests the unit's default state; empty or malformed bytes are invalid.
    public var documentState: Data?

    public static let maximumDocumentStateBytes = 16 * 1024 * 1024

    public init(id: AudioUnitSlotID = AudioUnitSlotID(), component: AudioUnitComponentIdentity,
                bypassed: Bool = false, productName: String? = nil, version: String? = nil,
                documentState: Data? = nil) {
        self.id = id
        self.component = component
        self.bypassed = bypassed
        self.productName = productName
        self.version = version
        self.documentState = documentState
    }

    public var isValid: Bool {
        guard component.isValid,
              [productName, version].compactMap({ $0 }).allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1024
              }) else { return false }
        guard let documentState else { return true }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard !documentState.isEmpty, documentState.count <= Self.maximumDocumentStateBytes,
              let state = try? PropertyListSerialization.propertyList(from: documentState, options: [], format: &format),
              format == .binary || format == .xml,
              let dictionary = state as? [String: Any] else { return false }
        return Self.validPropertyList(dictionary, depth: 0)
    }

    private static func validPropertyList(_ value: Any, depth: Int) -> Bool {
        guard depth <= 64 else { return false }
        switch value {
        case let dictionary as [String: Any]:
            // Keyed object archives are not Audio Unit document-state dictionaries.
            return dictionary["$archiver"] == nil
                && dictionary.values.allSatisfy { validPropertyList($0, depth: depth + 1) }
        case let array as [Any]:
            return array.allSatisfy { validPropertyList($0, depth: depth + 1) }
        case let number as NSNumber: return number.doubleValue.isFinite
        case let date as Date: return date.timeIntervalSinceReferenceDate.isFinite
        case is String, is Data: return true
        default: return false
        }
    }
}

/// Whole-recording gain, applied exactly once before the selected speaker's insert chain.
/// The channel is always explicit; unresolved channel knowledge is never a gain key.
public struct RecordingInputGain: Sendable, Equatable, Codable {
    public var source: SourceID
    public var channel: Int
    public var gainDB: Double

    public init(source: SourceID, channel: Int, gainDB: Double = 0) {
        self.source = source
        self.channel = channel
        self.gainDB = gainDB
    }

    public var reference: ChannelReference { ChannelReference(sourceID: source, statedChannel: channel) }
    public var isValid: Bool { channel >= 0 && EpisodeMixState.isValidGain(gainDB) }
}

public struct SpeakerMixState: Sendable, Equatable, Codable {
    public var speaker: SpeakerID
    /// Post-insert fader gain. Zero dB is unity.
    public var gainDB: Double
    /// Center = 0, left = -1, right = 1. The processing layer owns the pan law.
    public var pan: Double
    public var inserts: [AudioUnitSlot]

    public init(speaker: SpeakerID, gainDB: Double = 0, pan: Double = 0, inserts: [AudioUnitSlot] = []) {
        self.speaker = speaker
        self.gainDB = gainDB
        self.pan = pan
        self.inserts = inserts
    }

    public var isValid: Bool {
        EpisodeMixState.isValidGain(gainDB) && pan.isFinite && (-1...1).contains(pan)
            && inserts.count <= EpisodeMixState.maximumInsertsPerBus && inserts.allSatisfy(\.isValid)
    }
}

public struct MasterMixState: Sendable, Equatable, Codable {
    /// Output gain after the Master inserts.
    public var gainDB: Double
    public var inserts: [AudioUnitSlot]

    public init(gainDB: Double = 0, inserts: [AudioUnitSlot] = []) {
        self.gainDB = gainDB
        self.inserts = inserts
    }

    public var isValid: Bool {
        EpisodeMixState.isValidGain(gainDB)
            && inserts.count <= EpisodeMixState.maximumInsertsPerBus && inserts.allSatisfy(\.isValid)
    }
}

/// Sparse controls, never an alternate routing table. Episode speaker assignments alone select Primaries.
public struct EpisodeMixState: Sendable, Equatable, Codable {
    public var inputGains: [RecordingInputGain]
    public var speakers: [SpeakerMixState]
    public var master: MasterMixState

    public static let gainRangeDB: ClosedRange<Double> = -96...24
    public static let maximumInsertsPerBus = 64
    public static let maximumDocumentStateBytes = 64 * 1024 * 1024

    public init(inputGains: [RecordingInputGain] = [], speakers: [SpeakerMixState] = [],
                master: MasterMixState = MasterMixState()) {
        self.inputGains = inputGains
        self.speakers = speakers
        self.master = master
    }

    public static func isValidGain(_ value: Double) -> Bool { value.isFinite && gainRangeDB.contains(value) }

    public func inputGainDB(for source: SourceID, channel: Int) -> Double {
        inputGains.first { $0.source == source && $0.channel == channel }?.gainDB ?? 0
    }

    public func state(for speaker: SpeakerID) -> SpeakerMixState {
        speakers.first { $0.speaker == speaker } ?? SpeakerMixState(speaker: speaker)
    }

    public func validationIssues(in episode: Episode) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func invalid(_ detail: String) { issues.append(.init(.invalidMix, "episode \(episode.id): \(detail)")) }
        if !master.isValid || !speakers.allSatisfy(\.isValid) || !inputGains.allSatisfy(\.isValid) {
            invalid("invalid gain, pan, insert identity, diagnostics, or document state")
        }
        if Set(inputGains.map(\.reference)).count != inputGains.count {
            invalid("recording/channel input gains must be unique")
        }
        if Set(speakers.map(\.speaker)).count != speakers.count {
            invalid("speaker strips must be unique")
        }
        let episodeSpeakers = Set(episode.speakerAssignments.map(\.speakerID))
        if !Set(speakers.map(\.speaker)).isSubset(of: episodeSpeakers) {
            invalid("speaker strips must refer to speakers listed in the episode")
        }
        for gain in inputGains {
            guard let source = episode.source(gain.source) else {
                invalid("input gain refers to a missing recording \(gain.source)")
                continue
            }
            if let count = source.observations.channelCount.value, gain.channel >= count {
                invalid("input gain channel \(gain.channel) is outside recording \(gain.source)")
            }
        }
        let slots = speakers.flatMap(\.inserts) + master.inserts
        if Set(slots.map(\.id)).count != slots.count {
            invalid("insert slot IDs must be unique across the episode's buses")
        }
        if slots.reduce(0, { $0 + ($1.documentState?.count ?? 0) }) > Self.maximumDocumentStateBytes {
            invalid("combined insert document state exceeds \(Self.maximumDocumentStateBytes) bytes")
        }
        return issues
    }
}
