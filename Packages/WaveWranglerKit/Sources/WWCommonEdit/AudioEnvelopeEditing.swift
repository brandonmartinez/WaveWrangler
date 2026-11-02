import WWCore

public enum AudioFadeDirection: Sendable, Equatable {
    case fadeIn, fadeOut
}

public enum AudioEnvelopeEditError: Error, Sendable, Equatable {
    case invalidInterval
    case invalidDirection
    case invalidSilenceStart
    case unknownPoint
    case retainedSupportIsReadOnly
    case replacementRequired
}

/// A reviewable whole-curve edit. Coordinates and original point values are retained in the review.
public struct AudioEnvelopeEditPreview: Sendable, Equatable {
    public let envelope: AudioClipEnvelope
    public let replacedPoints: [AudioEnvelopePoint]
    public let overlapsRamp: Bool
    /// A later ramp's start may need a new level so the new endpoint holds until that ramp.
    public let heldUntil: AudioEnvelopeCoordinate?

    public var requiresReplacement: Bool { !replacedPoints.isEmpty || overlapsRamp }

    public func confirmed(replacing: Bool) throws(AudioEnvelopeEditError) -> AudioClipEnvelope {
        guard replacing || !requiresReplacement else { throw .replacementRequired }
        return envelope
    }
}

/// Editor operations on the existing evaluator, not another interpolation or rendering path.
public struct AudioEnvelopeEditing: Sendable {
    public let evaluator: AudioEnvelopeEvaluator

    public init(envelope: AudioClipEnvelope, durationFrames: Int64) throws {
        evaluator = try AudioEnvelopeEvaluator(envelope: envelope, durationFrames: durationFrames)
    }

    public func localCoordinate(of point: AudioEnvelopePoint) throws -> AudioEnvelopeCoordinate {
        let offset = evaluator.envelope.window?.offset ?? .zero
        let negative = try AudioEnvelopeCoordinate(numerator: -offset.numerator, denominator: offset.denominator)
        return try point.coordinate().adding(negative)
    }

    public func fade(
        from start: Int64, to end: Int64, direction: AudioFadeDirection,
        target: Double, initializingSilence: Bool = false
    ) throws -> AudioEnvelopeEditPreview {
        guard start >= 0, start < end, end <= evaluator.durationFrames else {
            throw AudioEnvelopeEditError.invalidInterval
        }
        guard target.isFinite, (0...1).contains(target) else { throw AudioEnvelopeError.invalidAmplitude }
        guard !initializingSilence || start == 0 && direction == .fadeIn else {
            throw AudioEnvelopeEditError.invalidSilenceStart
        }
        let current = try evaluator.amplitude(atLocalFrame: start)
        let initial = initializingSilence ? 0 : current
        guard direction == .fadeIn ? target > initial : target < initial else {
            throw AudioEnvelopeEditError.invalidDirection
        }
        let lo = try AudioEnvelopeCoordinate(numerator: start)
        let hi = try AudioEnvelopeCoordinate(numerator: end)
        let points = evaluator.envelope.points
        let locals = try points.map { try localCoordinate(of: $0) }
        var replaced: [AudioEnvelopePoint] = []
        for (point, local) in zip(points, locals) {
            if local >= lo, local <= hi {
                if local != lo || point.amplitude != initial { replaced.append(point) }
            }
        }
        var overlapsRamp = false
        for index in points.indices.dropFirst() where
            locals[index - 1] < hi && locals[index] > lo
                && points[index - 1].amplitude != points[index].amplitude {
            overlapsRamp = true
        }
        // Skip the overwritten ramp's tail and following holds to find the next actual ramp.
        // Every level changed to establish that hold is included in the replacement review.
        let duration = try AudioEnvelopeCoordinate(numerator: evaluator.durationFrames)
        var heldUntil: AudioEnvelopeCoordinate?
        var result = try evaluator.settingPoint(atLocalFrame: start, amplitude: initial)
        result = try AudioEnvelopeEvaluator(envelope: result, durationFrames: evaluator.durationFrames)
            .settingPoint(atLocalFrame: end, amplitude: target)
        let keyed = try result.points.map { (try localCoordinate(of: $0), $0) }
        result.points = keyed.filter { $0.0 <= lo || $0.0 >= hi }.map(\.1)
        var heldCoordinates: Set<AudioEnvelopeCoordinate> = []
        for index in points.indices where locals[index] > hi && locals[index] <= duration {
            if points[index].amplitude != target {
                replaced.append(points[index])
                heldCoordinates.insert(locals[index])
            }
            if index + 1 < points.count, points[index].amplitude != points[index + 1].amplitude {
                heldUntil = locals[index]
                break
            }
        }
        for index in result.points.indices where heldCoordinates.contains(try localCoordinate(of: result.points[index])) {
            result.points[index].amplitude = target
        }
        if heldUntil == nil, locals.contains(where: { $0 > duration }), end < evaluator.durationFrames {
            result = try AudioEnvelopeEvaluator(envelope: result, durationFrames: evaluator.durationFrames)
                .settingPoint(atLocalFrame: evaluator.durationFrames, amplitude: target)
        }
        _ = try AudioEnvelopeEvaluator(envelope: result, durationFrames: evaluator.durationFrames)
        return .init(envelope: result, replacedPoints: replaced, overlapsRamp: overlapsRamp,
                     heldUntil: heldUntil)
    }

    public func editingPoint(
        at index: Int, to local: AudioEnvelopeCoordinate, amplitude: Double
    ) throws -> AudioEnvelopeEditPreview {
        try requireEditablePoint(index)
        guard amplitude.isFinite, (0...1).contains(amplitude) else { throw AudioEnvelopeError.invalidAmplitude }
        let end = try AudioEnvelopeCoordinate(numerator: evaluator.durationFrames)
        guard local >= .zero, local <= end else { throw AudioEnvelopeError.outsideClipCoordinate(local) }
        let coordinate = try (evaluator.envelope.window?.offset ?? .zero).adding(local)
        let original = evaluator.envelope.points[index]
        var kept: [AudioEnvelopePoint] = []
        var replaced = [original]
        for (otherIndex, point) in evaluator.envelope.points.enumerated() where otherIndex != index {
            if try point.coordinate() == coordinate { replaced.append(point) }
            else { kept.append(point) }
        }
        kept.append(.init(frame: coordinate.floorFrame, amplitude: amplitude, fraction: coordinate.fractionalPart))
        let keyed = try kept.map { (try $0.coordinate(), $0) }.sorted { $0.0 < $1.0 }
        let result = AudioClipEnvelope(points: keyed.map(\.1), window: evaluator.envelope.window)
        _ = try AudioEnvelopeEvaluator(envelope: result, durationFrames: evaluator.durationFrames)
        return .init(envelope: result, replacedPoints: result == evaluator.envelope ? [] : replaced,
                     overlapsRamp: false, heldUntil: nil)
    }

    /// Integer deltas retain a knot's exact fractional phase and never cross a neighboring knot.
    public func movingPointTime(at index: Int, byFrames delta: Int64) throws -> AudioClipEnvelope {
        try requireEditablePoint(index)
        let points = evaluator.envelope.points
        let local = try localCoordinate(of: points[index])
        func floorDifference(_ a: AudioEnvelopeCoordinate, _ b: AudioEnvelopeCoordinate) -> Int64 {
            let n = Int128(a.numerator) * Int128(b.denominator) - Int128(b.numerator) * Int128(a.denominator)
            let d = Int128(a.denominator) * Int128(b.denominator)
            return Int64(n / d - (n % d < 0 ? 1 : 0))
        }
        var minimum = -local.floorFrame
        var maximum = evaluator.durationFrames - local.floorFrame - (local.fractionalPart == nil ? 0 : 1)
        if index > 0 {
            minimum = max(minimum, floorDifference(try localCoordinate(of: points[index - 1]), local) + 1)
        }
        if index + 1 < points.count {
            maximum = min(maximum, -floorDifference(local, try localCoordinate(of: points[index + 1])) - 1)
        }
        let bounded = min(max(delta, minimum), maximum)
        guard bounded != 0 else { return evaluator.envelope }
        let coordinate = try points[index].coordinate().adding(.init(numerator: bounded))
        var result = evaluator.envelope
        result.points[index].frame = coordinate.floorFrame
        result.points[index].fraction = coordinate.fractionalPart
        _ = try AudioEnvelopeEvaluator(envelope: result, durationFrames: evaluator.durationFrames)
        return result
    }

    /// A flat interior segment moves both bounding levels; a held tail moves its endpoint only.
    public func settingFlatLevel(first: Int, last: Int, amplitude: Double) throws -> AudioClipEnvelope {
        try requireEditablePoint(first)
        try requireEditablePoint(last)
        let points = evaluator.envelope.points
        let held: Bool
        if first == last {
            let local = try localCoordinate(of: points[first])
            let end = try AudioEnvelopeCoordinate(numerator: evaluator.durationFrames)
            held = first == 0 && local > .zero || first == points.count - 1 && local < end
        } else { held = false }
        guard first == last ? held : last == first + 1 && points[first].amplitude == points[last].amplitude else {
            throw AudioEnvelopeEditError.invalidInterval
        }
        guard amplitude.isFinite, (0...1).contains(amplitude) else { throw AudioEnvelopeError.invalidAmplitude }
        var result = evaluator.envelope
        result.points[first].amplitude = amplitude
        result.points[last].amplitude = amplitude
        _ = try AudioEnvelopeEvaluator(envelope: result, durationFrames: evaluator.durationFrames)
        return result
    }

    public func removingPoint(at index: Int) throws -> AudioEnvelopeEditPreview {
        try requireEditablePoint(index)
        var result = evaluator.envelope
        let removed = result.points.remove(at: index)
        if result.points.isEmpty { result.window = nil }
        _ = try AudioEnvelopeEvaluator(envelope: result, durationFrames: evaluator.durationFrames)
        return .init(envelope: result, replacedPoints: [removed], overlapsRamp: false, heldUntil: nil)
    }

    private func requireEditablePoint(_ index: Int) throws {
        guard evaluator.envelope.points.indices.contains(index) else { throw AudioEnvelopeEditError.unknownPoint }
        let local = try localCoordinate(of: evaluator.envelope.points[index])
        guard local >= .zero, local <= (try AudioEnvelopeCoordinate(numerator: evaluator.durationFrames)) else {
            throw AudioEnvelopeEditError.retainedSupportIsReadOnly
        }
    }
}
