import CryptoKit
import Foundation

/// Qualified decoded-source geometry, not an access grant or a second media registry.
/// `source` is the canonical asset identity in this episode's existing source ledger.
public struct AudioAsset: Sendable, Equatable, Codable {
    public var source: SourceID
    public var frameCount: Int64
    public var sampleRate: Int
    public var channelCount: Int

    public init(source: SourceID, frameCount: Int64, sampleRate: Int, channelCount: Int) {
        self.source = source
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var isValid: Bool {
        (8_000...192_000).contains(sampleRate) && (1...64).contains(channelCount)
            && frameCount > 0 && frameCount <= Int64(sampleRate) * 86_400
    }
}

public struct AudioTrack: Sendable, Equatable, Codable, Identifiable {
    public var id: AudioTrackID
    public var name: String

    public init(id: AudioTrackID = AudioTrackID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Half-open trim in the asset's real decoded-source grid, never the program grid.
public struct AudioSourceTrim: Sendable, Equatable, Codable {
    public var startFrame: Int64
    public var endFrame: Int64

    public init(startFrame: Int64, endFrame: Int64) {
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

/// Integer frame plus an optional exact proper fraction on the envelope's 48 kHz curve grid.
/// Without a retained window that grid is clip-local. Zero amplitude is exact silence.
public struct AudioEnvelopePoint: Sendable, Equatable, Codable {
    public var frame: Int64
    public var amplitude: Double
    public var fraction: AudioEnvelopeCoordinate?

    public init(frame: Int64, amplitude: Double, fraction: AudioEnvelopeCoordinate? = nil) {
        self.frame = frame
        self.amplitude = amplitude
        self.fraction = fraction == .zero ? nil : fraction
    }

    public func coordinate() throws(AudioEnvelopeCoordinateError) -> AudioEnvelopeCoordinate {
        guard fraction?.isProperFraction != false else { throw .invalidFraction }
        let whole = try AudioEnvelopeCoordinate(numerator: frame)
        if let fraction { return try whole.adding(fraction) }
        return whole
    }
}

public struct AudioClipEnvelope: Sendable, Equatable, Codable {
    /// Empty is unity. Between points amplitude is linear; outside points the endpoint value holds.
    public var points: [AudioEnvelopePoint]
    /// Retain the original curve and exact origin phase when trimming/splitting, without rounded gains.
    public var window: AudioEnvelopeWindow?

    public init(points: [AudioEnvelopePoint] = [], window: AudioEnvelopeWindow? = nil) {
        self.points = points
        self.window = window
    }

    public func isValid(durationFrames: Int64) -> Bool {
        guard durationFrames > 0, durationFrames <= AudioArrangement.frameLimit else { return false }
        do {
            let offset = window?.offset ?? .zero
            guard offset >= .zero,
                  offset <= (try AudioEnvelopeCoordinate(numerator: AudioArrangement.frameLimit)),
                  !points.isEmpty || window == nil else { return false }
            let end = try offset.adding(AudioEnvelopeCoordinate(numerator: durationFrames))
            var previous: AudioEnvelopeCoordinate?
            var before = 0, after = 0
            for point in points {
                let coordinate = try point.coordinate()
                guard coordinate >= .zero, previous.map({ coordinate > $0 }) != false,
                      point.amplitude.isFinite, (0...1).contains(point.amplitude) else { return false }
                if coordinate < offset { before += 1 }
                if coordinate > end { after += 1 }
                previous = coordinate
            }
            // Windowed curves retain only the nearest support on each side. Ordinary legacy curves
            // still require every point inside [0, duration], including the exclusive ramp endpoint.
            return window == nil ? before == 0 && after == 0 : before <= 1 && after <= 1
        } catch { return false }
    }
}

/// The exact canonical map version whose original-aligned grid a follow anchor names.
/// A changed/replaced map requires placement review, even if its revision number is reused.
public struct AudioDialogueAnchor: Sendable, Equatable, Codable {
    public var alignmentRevision: Int
    public var mapIdentity: String
    public var frame: Int64

    public init(alignmentRevision: Int, mapIdentity: String, frame: Int64) {
        self.alignmentRevision = alignmentRevision
        self.mapIdentity = mapIdentity
        self.frame = frame
    }

    public init(map: TimeMapVersion, frame: Int64) throws {
        self.init(alignmentRevision: map.revision, mapIdentity: try Self.identity(of: map), frame: frame)
    }

    public static func identity(of map: TimeMapVersion) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(map)).map { String(format: "%02x", $0) }.joined()
    }

    public func isCurrent(in episode: Episode) throws -> Bool {
        guard let map = episode.alignment?.acceptedMap, map.revision == alignmentRevision else { return false }
        return try Self.identity(of: map) == mapIdentity
    }
}

public enum AudioPlacementAnchor: Sendable, Equatable, Codable {
    /// Unpinned program-origin placement before dialogue timing exists (including audio-only episodes).
    /// Later dialogue admission must preserve this position until explicitly reconciled.
    case programOrigin(frame: Int64)
    /// Follows dialogue edits; the frame is on the original aligned grid, before manual cuts.
    case dialogue(AudioDialogueAnchor)
    /// Pinned to absolute program time.
    case absolute(frame: Int64)
    /// Follows a named inserted-time region; the offset is inside that region.
    case insertion(region: AudioInsertionRegionID, offsetFrames: Int64)
}

/// Explicit program space, separate from ordinary overlay placement. Regions cannot nest.
public struct AudioInsertionRegion: Sendable, Equatable, Codable, Identifiable {
    public var id: AudioInsertionRegionID
    public var anchor: AudioPlacementAnchor
    public var durationFrames: Int64

    public init(id: AudioInsertionRegionID = AudioInsertionRegionID(), anchor: AudioPlacementAnchor,
                durationFrames: Int64) {
        self.id = id
        self.anchor = anchor
        self.durationFrames = durationFrames
    }
}

/// A selection on the retained trim's nominal 48 kHz sample grid, not a new native trim.
public struct AudioClipOutputWindow: Sendable, Equatable, Codable {
    public var offsetFrames: Int64
    public var countFrames: Int64

    public init(offsetFrames: Int64, countFrames: Int64) {
        self.offsetFrames = offsetFrames
        self.countFrames = countFrames
    }
}

public struct AudioClip: Sendable, Equatable, Codable, Identifiable {
    public var id: AudioClipID
    public var track: AudioTrackID
    public var source: SourceID
    public var trim: AudioSourceTrim
    /// Ordered source channels. Omitted means all channels in native order, preserving stereo.
    public var channels: [Int]?
    public var anchor: AudioPlacementAnchor
    public var envelope: AudioClipEnvelope
    /// When present, trim is retained SRC support; this window owns the actual output samples.
    public var outputWindow: AudioClipOutputWindow?

    public init(id: AudioClipID = AudioClipID(), track: AudioTrackID, source: SourceID,
                trim: AudioSourceTrim, channels: [Int]? = nil, anchor: AudioPlacementAnchor,
                envelope: AudioClipEnvelope = AudioClipEnvelope(), outputWindow: AudioClipOutputWindow? = nil) {
        self.id = id
        self.track = track
        self.source = source
        self.trim = trim
        self.channels = channels
        self.anchor = anchor
        self.envelope = envelope
        self.outputWindow = outputWindow
    }

    /// Round up the final fractional output frame. Validation bounds operands before multiplication.
    public func durationFrames(asset: AudioAsset) -> Int64? {
        guard let duration = nominalDurationFrames(asset: asset) else { return nil }
        guard let outputWindow else { return duration }
        guard outputWindow.offsetFrames >= 0, outputWindow.countFrames > 0,
              outputWindow.offsetFrames < duration,
              outputWindow.countFrames <= duration - outputWindow.offsetFrames else { return nil }
        return outputWindow.countFrames
    }

    public func ownedOutputFrames(asset: AudioAsset) -> Range<Int64>? {
        guard let duration = durationFrames(asset: asset) else { return nil }
        let start = outputWindow?.offsetFrames ?? 0
        return start..<(start + duration)
    }

    /// Ordinary integer-trim CEIL duration, before an optional nominal-output selection.
    public func nominalDurationFrames(asset: AudioAsset) -> Int64? {
        guard asset.isValid, trim.startFrame >= 0, trim.endFrame > trim.startFrame,
              trim.endFrame <= asset.frameCount else { return nil }
        let frames = trim.endFrame - trim.startFrame
        let (scaled, overflow) = frames.multipliedReportingOverflow(by: AudioArrangement.frameRate)
        guard !overflow else { return nil }
        let rate = Int64(asset.sampleRate)
        return scaled / rate + (scaled % rate == 0 ? 0 : 1)
    }
}

/// Optional schema-10 production state. Track order is visual order; clips may overlap and reuse assets.
/// No timeline projection, decoding, rendering, or recorder-clock mutation occurs in this value.
public struct AudioArrangement: Sendable, Equatable, Codable {
    public var assets: [AudioAsset]
    public var tracks: [AudioTrack]
    public var clips: [AudioClip]
    public var insertionRegions: [AudioInsertionRegion]

    public static let frameRate: Int64 = 48_000
    public static let frameLimit = ManualEpisodeCut.frameLimit

    public init(assets: [AudioAsset] = [], tracks: [AudioTrack] = [], clips: [AudioClip] = [],
                insertionRegions: [AudioInsertionRegion] = []) {
        self.assets = assets
        self.tracks = tracks
        self.clips = clips
        self.insertionRegions = insertionRegions
    }

    public func validationIssues(in episode: Episode) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func invalid(_ detail: String) { issues.append(.init(.invalidAudio, "episode \(episode.id): \(detail)")) }
        if Set(assets.map(\.source)).count != assets.count
            || Set(tracks.map(\.id)).count != tracks.count
            || Set(clips.map(\.id)).count != clips.count
            || Set(insertionRegions.map(\.id)).count != insertionRegions.count {
            invalid("asset, track, clip, and insertion IDs must each be unique")
        }
        for asset in assets {
            guard let source = episode.source(asset.source), !source.isRecording else {
                invalid("asset must reference supplemental media in this episode: \(asset.source)")
                continue
            }
            if !asset.isValid
                || source.observations.channelCount.value.map({ $0 != asset.channelCount }) == true
                || source.observations.sampleRate.value.map({ $0 != Double(asset.sampleRate) }) == true {
                invalid("invalid or inconsistent decoded asset geometry: \(asset.source)")
            }
            if let duration = source.observations.durationSeconds.value,
               !duration.isFinite || duration <= 0
                || duration != Double(asset.frameCount) / Double(max(1, asset.sampleRate)) {
                invalid("asset duration disagrees with known source bounds: \(asset.source)")
            }
        }
        if tracks.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            invalid("audio track names cannot be empty")
        }
        func anchorValid(_ anchor: AudioPlacementAnchor, allowsInsertion: Bool) -> Bool {
            switch anchor {
            case .absolute(let frame), .programOrigin(let frame):
                return (-Self.frameLimit...Self.frameLimit).contains(frame)
            case .dialogue(let anchor):
                return anchor.alignmentRevision > 0
                    && episode.alignment?.map(revision: anchor.alignmentRevision) != nil
                    && anchor.mapIdentity.utf8.count == 64
                    && anchor.mapIdentity.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                    && (-Self.frameLimit...Self.frameLimit).contains(anchor.frame)
            case .insertion(let id, let offset):
                return allowsInsertion && offset >= 0
                    && insertionRegions.contains { $0.id == id && offset < $0.durationFrames }
            }
        }
        func startFrame(_ anchor: AudioPlacementAnchor) -> Int64? {
            switch anchor {
            case .absolute(let frame), .programOrigin(let frame): return frame
            case .dialogue(let anchor): return anchor.frame
            case .insertion(let id, let offset):
                guard let region = insertionRegions.first(where: { $0.id == id }),
                      let start = startFrameWithoutInsertion(region.anchor) else { return nil }
                let (sum, overflow) = start.addingReportingOverflow(offset)
                return overflow ? nil : sum
            }
        }
        func startFrameWithoutInsertion(_ anchor: AudioPlacementAnchor) -> Int64? {
            switch anchor {
            case .absolute(let frame), .programOrigin(let frame): return frame
            case .dialogue(let anchor): return anchor.frame
            case .insertion: return nil
            }
        }
        func fits(_ anchor: AudioPlacementAnchor, duration: Int64) -> Bool {
            guard let start = startFrame(anchor) else { return false }
            let (end, overflow) = start.addingReportingOverflow(duration)
            return !overflow && end <= Self.frameLimit
        }
        var totalInsertion: Int64 = 0
        for region in insertionRegions {
            if !anchorValid(region.anchor, allowsInsertion: false) || region.durationFrames <= 0
                || region.durationFrames > Self.frameLimit || !fits(region.anchor, duration: region.durationFrames) {
                invalid("invalid insertion region \(region.id)")
            }
            let (sum, overflow) = totalInsertion.addingReportingOverflow(region.durationFrames)
            if overflow || sum > Self.frameLimit { invalid("inserted duration exceeds program bounds") }
            else { totalInsertion = sum }
        }
        let trackIDs = Set(tracks.map(\.id))
        for clip in clips {
            guard trackIDs.contains(clip.track), let asset = assets.first(where: { $0.source == clip.source }),
                  let duration = clip.durationFrames(asset: asset) else {
                invalid("clip \(clip.id) has a missing track/asset or invalid source trim")
                continue
            }
            if let channels = clip.channels,
               channels.isEmpty || Set(channels).count != channels.count
                || channels.contains(where: { $0 < 0 || $0 >= asset.channelCount }) {
                invalid("clip \(clip.id) has invalid source channels")
            }
            if !anchorValid(clip.anchor, allowsInsertion: true) || !fits(clip.anchor, duration: duration) {
                invalid("clip \(clip.id) has an invalid or dangling placement anchor")
            }
            if !clip.envelope.isValid(durationFrames: duration) { invalid("clip \(clip.id) has invalid envelope points/window") }
        }
        return issues
    }
}
