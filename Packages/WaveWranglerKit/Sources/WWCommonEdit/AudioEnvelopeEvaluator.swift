import WWCore
import WWTimeMap

public enum AudioEnvelopeError: Error, Sendable, Equatable {
    case invalidDuration(Int64)
    case invalidEnvelope
    case invalidAmplitude
    case outsideClip(Int64)
    case outsideClipCoordinate(AudioEnvelopeCoordinate)
    case invalidSlice(Range<Int64>)
    case invalidNativeTrim
    case coordinate(AudioEnvelopeCoordinateError)
    case arithmetic(TimeMapError)
}

public struct AudioEnvelopeSplit: Sendable, Equatable {
    public let leading: AudioClipEnvelope
    public let trailing: AudioClipEnvelope
}

/// Seek-independent linear amplitude. Exact curve coordinates precede the final Double gain.
public struct AudioEnvelopeEvaluator: Sendable, Equatable {
    public let envelope: AudioClipEnvelope
    public let durationFrames: Int64
    private let coordinates: [AudioEnvelopeCoordinate]

    public init(envelope: AudioClipEnvelope, durationFrames: Int64) throws(AudioEnvelopeError) {
        guard durationFrames > 0, durationFrames <= AudioArrangement.frameLimit else {
            throw .invalidDuration(durationFrames)
        }
        guard envelope.isValid(durationFrames: durationFrames) else { throw .invalidEnvelope }
        var coordinates: [AudioEnvelopeCoordinate] = []
        do {
            for point in envelope.points { coordinates.append(try point.coordinate()) }
        } catch { throw .coordinate(error) }
        self.coordinates = coordinates
        self.envelope = envelope
        self.durationFrames = durationFrames
    }

    /// The closed endpoint is for boundary/curve evaluation, never an extra audio sample.
    public func amplitude(atLocalFrame frame: Int64) throws(AudioEnvelopeError) -> Double {
        guard frame >= 0, frame <= durationFrames else { throw .outsideClip(frame) }
        let local: AudioEnvelopeCoordinate
        do { local = try AudioEnvelopeCoordinate(numerator: frame) } catch { throw .coordinate(error) }
        return try amplitude(atLocalCoordinate: local)
    }

    /// Continuous evaluation also makes fractional native trim phases inspectable without quantization.
    public func amplitude(atLocalCoordinate local: AudioEnvelopeCoordinate) throws(AudioEnvelopeError) -> Double {
        let end: AudioEnvelopeCoordinate
        let position: AudioEnvelopeCoordinate
        do { end = try .init(numerator: durationFrames) } catch { throw .coordinate(error) }
        guard local >= .zero, local <= end else { throw .outsideClipCoordinate(local) }
        do { position = try (envelope.window?.offset ?? .zero).adding(local) } catch { throw .coordinate(error) }
        let points = envelope.points
        guard let first = coordinates.first, let last = coordinates.last else { return 1 }
        if position <= first { return points[0].amplitude }
        if position >= last { return points[points.count - 1].amplitude }
        var lo = 1
        var hi = coordinates.count - 1
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if coordinates[mid] < position { lo = mid + 1 } else { hi = mid }
        }
        if position == coordinates[lo] { return points[lo].amplitude }
        let a = coordinates[lo - 1]
        let b = coordinates[lo]
        // All operands are bounded by two days and 192 kHz; these Int128 products fit exactly.
        let left =
            Int128(position.numerator) * Int128(a.denominator) - Int128(a.numerator) * Int128(position.denominator)
        let right = Int128(b.numerator) * Int128(a.denominator) - Int128(a.numerator) * Int128(b.denominator)
        let fraction: Double
        do {
            fraction = try ExactRational(
                numerator: left * Int128(b.denominator),
                denominator: right * Int128(position.denominator)
            ).approximateDouble
        } catch { throw .arithmetic(error) }
        return points[lo - 1].amplitude + (points[lo].amplitude - points[lo - 1].amplitude) * fraction
    }

    /// Retain bracketing knots instead of rounding/materializing a new boundary amplitude. Repeated
    /// slices therefore preserve the continuous curve, not merely a previous slice's sampled gains.
    public func sliced(to frames: Range<Int64>) throws(AudioEnvelopeError) -> AudioClipEnvelope {
        guard !frames.isEmpty, frames.lowerBound >= 0, frames.upperBound <= durationFrames else {
            throw .invalidSlice(frames)
        }
        let delta: AudioEnvelopeCoordinate
        do { delta = try .init(numerator: frames.lowerBound) } catch { throw .coordinate(error) }
        return try retained(offsetBy: delta, duration: frames.upperBound - frames.lowerBound)
    }

    public func split(atLocalFrame frame: Int64) throws(AudioEnvelopeError) -> AudioEnvelopeSplit {
        guard frame > 0, frame < durationFrames else { throw .outsideClip(frame) }
        return try AudioEnvelopeSplit(leading: sliced(to: 0..<frame), trailing: sliced(to: frame..<durationFrames))
    }

    /// Add/replace a fade at the CURRENT local playhead or exclusive endpoint, including after trims.
    public func settingPoint(atLocalFrame frame: Int64, amplitude: Double) throws(AudioEnvelopeError)
        -> AudioClipEnvelope
    {
        guard frame >= 0, frame <= durationFrames else { throw .outsideClip(frame) }
        guard amplitude.isFinite, (0...1).contains(amplitude) else { throw .invalidAmplitude }
        let coordinate: AudioEnvelopeCoordinate
        do {
            coordinate = try (envelope.window?.offset ?? .zero).adding(AudioEnvelopeCoordinate(numerator: frame))
        } catch { throw .coordinate(error) }
        let point = AudioEnvelopePoint(
            frame: coordinate.floorFrame, amplitude: amplitude, fraction: coordinate.fractionalPart)
        var points = zip(envelope.points, coordinates).filter { $0.1 != coordinate }.map(\.0)
        let index = coordinates.filter { $0 < coordinate }.count
        points.insert(point, at: index)
        let result = AudioClipEnvelope(points: points, window: envelope.window)
        guard result.isValid(durationFrames: durationFrames) else { throw .invalidEnvelope }
        return result
    }

    public static func trimmedEnvelope(
        of clip: AudioClip, asset: AudioAsset,
        to trim: AudioSourceTrim
    ) throws(AudioEnvelopeError) -> AudioClipEnvelope {
        guard let originalDuration = clip.durationFrames(asset: asset),
            trim.startFrame >= clip.trim.startFrame, trim.endFrame <= clip.trim.endFrame,
            trim.endFrame > trim.startFrame
        else { throw .invalidNativeTrim }
        var retained = clip
        retained.trim = trim
        guard let duration = retained.durationFrames(asset: asset) else { throw .invalidNativeTrim }
        let delta: AudioEnvelopeCoordinate
        do throws(AudioEnvelopeCoordinateError) {
            let nativeDelta = trim.startFrame - clip.trim.startFrame
            let (scaled, overflow) = nativeDelta.multipliedReportingOverflow(by: AudioArrangement.frameRate)
            guard !overflow else { throw AudioEnvelopeCoordinateError.outsideEnvelope }
            delta = try .init(numerator: scaled, denominator: Int64(asset.sampleRate))
        } catch { throw .coordinate(error) }
        return try Self(envelope: clip.envelope, durationFrames: originalDuration).retained(
            offsetBy: delta, duration: duration)
    }

    public static func splitEnvelope(
        of clip: AudioClip, asset: AudioAsset,
        atNativeFrame frame: Int64
    ) throws(AudioEnvelopeError) -> AudioEnvelopeSplit {
        guard frame > clip.trim.startFrame, frame < clip.trim.endFrame else { throw .invalidNativeTrim }
        return try .init(
            leading: trimmedEnvelope(
                of: clip, asset: asset, to: .init(startFrame: clip.trim.startFrame, endFrame: frame)),
            trailing: trimmedEnvelope(
                of: clip, asset: asset, to: .init(startFrame: frame, endFrame: clip.trim.endFrame)))
    }

    private func retained(offsetBy delta: AudioEnvelopeCoordinate, duration: Int64) throws(AudioEnvelopeError)
        -> AudioClipEnvelope
    {
        guard !envelope.points.isEmpty else { return .init() }
        let start: AudioEnvelopeCoordinate
        let end: AudioEnvelopeCoordinate
        do {
            start = try (envelope.window?.offset ?? .zero).adding(delta)
            end = try start.adding(AudioEnvelopeCoordinate(numerator: duration))
        } catch { throw .coordinate(error) }
        let before = coordinates.lastIndex(where: { $0 < start })
        let after = coordinates.firstIndex(where: { $0 > end })
        let kept = envelope.points.indices.filter {
            $0 == before || $0 == after || (coordinates[$0] >= start && coordinates[$0] <= end)
        }.map { envelope.points[$0] }
        let result = AudioClipEnvelope(points: kept, window: .init(offset: start))
        guard result.isValid(durationFrames: duration) else { throw .invalidEnvelope }
        return result
    }
}
