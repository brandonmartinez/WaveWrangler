import Foundation
import WWAlignEstimate

public struct QuietEnergyBin: Sendable, Equatable {
    public let rms: Double
    public let peak: Double
    public let selectedRMS: Double
    public let selectedPeak: Double
}

public struct QuietAudioProfile: Sendable {
    public let duration: Double
    public let checkedChannels: Int
    public let bins: [QuietEnergyBin]
}

/// Full-band, uncentered energy. Opposite channels, bass and DC never cancel into apparent silence.
public struct QuietAudioProfileBuilder {
    private let rate: Int
    private let channels: Int
    private let selected: Int
    private let checked: Range<Int>
    private var position: Int64 = 0
    private var count = 0
    private var squares: [Double]
    private var peaks: [Double]
    private var bins: [QuietEnergyBin] = []
    private var failed = false
    private var finished = false

    public init(sampleRate: Int, channelCount: Int, selectedChannel: Int, allChannels: Bool) throws {
        guard (8000...192000).contains(sampleRate), (1...32).contains(channelCount),
              (0..<channelCount).contains(selectedChannel) else {
            throw AlignEstimateError.invalidParameter("quiet profile source shape")
        }
        rate = sampleRate
        channels = channelCount
        selected = selectedChannel
        checked = allChannels ? 0..<channelCount : selectedChannel..<selectedChannel + 1
        squares = .init(repeating: 0, count: channelCount)
        peaks = .init(repeating: 0, count: channelCount)
    }

    public mutating func append(_ samples: [Float], firstFrame: Int64, frameCount: Int) throws {
        guard !failed, !finished else { throw AlignEstimateError.invalidParameter("quiet profile is closed or failed") }
        failed = true
        try Task.checkCancellation()
        guard firstFrame == position, frameCount > 0, frameCount <= rate * 7200,
              samples.count == frameCount * channels,
              position + Int64(frameCount) <= Int64(rate) * 7200 else {
            throw AlignEstimateError.invalidParameter("noncontiguous or excessive quiet profile PCM")
        }
        var offset = 0
        while offset < frameCount {
            let boundary = (Int64(bins.count + 1) * Int64(rate) + 9) / 10
            let end = min(frameCount, offset + Int(boundary - position))
            for channel in checked {
                for index in offset..<end {
                    let value = Double(samples[channel * frameCount + index])
                    guard value.isFinite else { throw AlignEstimateError.invalidParameter("nonfinite quiet profile PCM") }
                    squares[channel] += value * value
                    peaks[channel] = max(peaks[channel], abs(value))
                }
            }
            count += end - offset
            position += Int64(end - offset)
            offset = end
            if position == boundary { flush() }
        }
        failed = false
    }

    public mutating func finish() throws -> QuietAudioProfile {
        guard !failed, !finished, position > 0 else { throw AlignEstimateError.invalidParameter("empty, failed or closed quiet profile") }
        finished = true
        try Task.checkCancellation()
        if count > 0 { flush() }
        return QuietAudioProfile(duration: Double(position) / Double(rate), checkedChannels: checked.count, bins: bins)
    }

    private mutating func flush() {
        bins.append(QuietEnergyBin(
            rms: min(peaks.max() ?? 0, sqrt((squares.max() ?? 0) / Double(count))), peak: peaks.max() ?? 0,
            selectedRMS: min(peaks[selected], sqrt(squares[selected] / Double(count))), selectedPeak: peaks[selected]))
        squares = .init(repeating: 0, count: channels)
        peaks = .init(repeating: 0, count: channels)
        count = 0
    }
}

public struct QuietTimingWitness: Sendable, Equatable, Codable {
    public let verifiedStart: Double
    public let verifiedEnd: Double
    public let checkedChannels: Int
    public let maximumRMS: Double
    public let maximumPeak: Double
    public let noiseFloor: Double
    public let anchorRMS: Double
    public let anchorPeak: Double

    var rmsLimit: Double { min(0.001, max(0.0001, 2 * noiseFloor), anchorRMS * sqrt(0.001)) }
    var peakLimit: Double { min(0.003, anchorPeak * 0.1) }

    func isValid(channels: Int, duration: Double) -> Bool {
        [verifiedStart, verifiedEnd, maximumRMS, maximumPeak, noiseFloor, anchorRMS, anchorPeak].allSatisfy(\.isFinite)
            && checkedChannels == channels && (1...32).contains(channels)
            && verifiedStart >= 0 && verifiedEnd <= duration && verifiedEnd > verifiedStart
            && maximumRMS >= 0 && maximumPeak >= maximumRMS && noiseFloor >= 0
            && anchorRMS > 0 && anchorPeak >= anchorRMS
            && maximumRMS <= rmsLimit && maximumPeak <= peakLimit
    }
}

/// Inferred quiet-only timing between measured anchors, never an acoustic timing observation.
public struct AdaptiveQuietTransition: Sendable, Equatable, Codable {
    public let sourceStart: Double
    public let sourceEnd: Double
    public let rateRatio: Double
    public let offsetSeconds: Double
    public let leftRegion: Int
    public let target: QuietTimingWitness
    public let reference: QuietTimingWitness
}

public enum AdaptiveQuietTiming {
    public static let identifier = "ww-quiet-transition/1"
    private static let guardSeconds = 0.2

    private static func geometry(
        left: AdaptiveTimingRegion, right: AdaptiveTimingRegion
    ) -> (rate: Double, offset: Double)? {
        let seconds = right.sourceStart - left.sourceEnd
        guard seconds >= 0.5, seconds <= 60 else { return nil }
        let start = left.rateRatio * left.sourceEnd + left.offsetSeconds
        let end = right.rateRatio * right.sourceStart + right.offsetSeconds
        let rate = (end - start) / seconds
        guard rate.isFinite, abs(rate - 1) <= 0.01 + 1e-12,
              abs((end - right.sourceStart) - (start - left.sourceEnd)) <= 0.05 + 1e-12 else { return nil }
        return (rate, start - rate * left.sourceEnd)
    }

    public static func adding(
        to timing: AdaptiveTimingResult, target: QuietAudioProfile, reference: QuietAudioProfile
    ) throws -> AdaptiveTimingResult {
        func valid(_ profile: QuietAudioProfile) -> Bool {
            profile.duration.isFinite && profile.duration > 0 && profile.duration <= 7200
                && (1...32).contains(profile.checkedChannels)
                && profile.bins.count == Int(ceil(profile.duration * 10 - 1e-9))
                && profile.bins.allSatisfy {
                    [$0.rms, $0.peak, $0.selectedRMS, $0.selectedPeak].allSatisfy { $0.isFinite && $0 >= 0 }
                        && $0.rms <= $0.peak && $0.selectedRMS <= $0.selectedPeak
                        && $0.selectedRMS <= $0.rms && $0.selectedPeak <= $0.peak
                }
        }
        guard valid(target), valid(reference), reference.checkedChannels == 1,
              timing.regions.allSatisfy({
                  [$0.sourceStart, $0.sourceEnd, $0.rateRatio, $0.offsetSeconds].allSatisfy(\.isFinite)
                      && $0.sourceStart >= 0 && $0.sourceEnd > $0.sourceStart && $0.sourceEnd <= 7200
                      && (0.9995...1.0005).contains($0.rateRatio) && abs($0.offsetSeconds) <= 7200
              }) else {
            throw AlignEstimateError.invalidParameter("invalid quiet energy profile")
        }
        func indices(_ start: Double, _ end: Double, _ profile: QuietAudioProfile) -> Range<Int>? {
            let lower = Int(floor(start * 10)), upper = Int(ceil(end * 10))
            guard start >= 0, end <= profile.duration, upper > lower, lower >= 0,
                  upper <= Int(floor(profile.duration * 10 + 1e-9)) else { return nil }
            return lower..<upper
        }
        func anchor(_ region: AdaptiveTimingRegion, end: Bool, profile: QuietAudioProfile, project: Bool)
            -> (rms: Double, peak: Double)? {
            let start = end ? max(region.sourceStart, region.sourceEnd - 2) : region.sourceStart
            let finish = end ? region.sourceEnd : min(region.sourceEnd, region.sourceStart + 2)
            let lo = project ? region.rateRatio * start + region.offsetSeconds : start
            let hi = project ? region.rateRatio * finish + region.offsetSeconds : finish
            let lower = Int(ceil(lo * 10)), upper = Int(floor(hi * 10))
            guard lower >= 0, upper > lower, upper <= Int(floor(profile.duration * 10)) else { return nil }
            let range = lower..<upper
            return (range.map { profile.bins[$0].selectedRMS }.max() ?? 0,
                    range.map { profile.bins[$0].selectedPeak }.max() ?? 0)
        }
        func witness(
            _ start: Double, _ end: Double, profile: QuietAudioProfile, floor: Double,
            anchor: (rms: Double, peak: Double)
        ) -> QuietTimingWitness? {
            guard let range = indices(start, end, profile) else { return nil }
            let value = QuietTimingWitness(
                verifiedStart: Double(range.lowerBound) / 10, verifiedEnd: Double(range.upperBound) / 10,
                checkedChannels: profile.checkedChannels,
                maximumRMS: range.map { profile.bins[$0].rms }.max() ?? 0,
                maximumPeak: range.map { profile.bins[$0].peak }.max() ?? 0,
                noiseFloor: floor, anchorRMS: anchor.rms, anchorPeak: anchor.peak)
            return value.isValid(channels: profile.checkedChannels, duration: profile.duration) ? value : nil
        }
        func noiseFloor(_ center: Double, profile: QuietAudioProfile) -> Double {
            let lower = max(0, Int(floor((center - 10) * 10)))
            let upper = min(profile.bins.count, Int(ceil((center + 10) * 10)))
            guard upper > lower else { return 0 }
            let values = profile.bins[lower..<upper].map(\.rms).sorted()
            return values[(values.count - 1) / 10]
        }
        var transitions: [AdaptiveQuietTransition] = []
        for index in timing.regions.indices.dropLast() {
            try Task.checkCancellation()
            let left = timing.regions[index], right = timing.regions[index + 1]
            guard let map = geometry(left: left, right: right),
                  let tl = anchor(left, end: true, profile: target, project: false),
                  let tr = anchor(right, end: false, profile: target, project: false),
                  let rl = anchor(left, end: true, profile: reference, project: true),
                  let rr = anchor(right, end: false, profile: reference, project: true) else { continue }
            let sourceCenter = (left.sourceEnd + right.sourceStart) / 2
            let tf = noiseFloor(sourceCenter, profile: target)
            let rf = noiseFloor(map.rate * sourceCenter + map.offset, profile: reference)
            let ta = (rms: min(tl.rms, tr.rms), peak: min(tl.peak, tr.peak))
            let ra = (rms: min(rl.rms, rr.rms), peak: min(rl.peak, rr.peak))
            // Full bins strictly inside the unknown gap protect both measured anchor boundaries.
            let lower = Int(floor(left.sourceEnd * 10)) + 1
            let upper = Int(ceil(right.sourceStart * 10)) - 1
            var beginning: Int?
            func flush(_ end: Int) {
                guard let start = beginning else { return }
                beginning = nil
                let a = Double(start) / 10, b = Double(end) / 10
                guard b - a >= 0.3 - 1e-9,
                      let t = witness(a - guardSeconds, b + guardSeconds, profile: target, floor: tf, anchor: ta),
                      let r = witness(map.rate * (a - guardSeconds) + map.offset,
                                      map.rate * (b + guardSeconds) + map.offset, profile: reference, floor: rf, anchor: ra)
                else { return }
                transitions.append(AdaptiveQuietTransition(sourceStart: a, sourceEnd: b, rateRatio: map.rate,
                    offsetSeconds: map.offset, leftRegion: index, target: t, reference: r))
            }
            if upper > lower {
                for bin in lower..<upper {
                    try Task.checkCancellation()
                    let a = Double(bin) / 10 - guardSeconds, b = Double(bin + 1) / 10 + guardSeconds
                    let quiet = witness(a, b, profile: target, floor: tf, anchor: ta) != nil
                        && witness(map.rate * a + map.offset, map.rate * b + map.offset,
                                   profile: reference, floor: rf, anchor: ra) != nil
                    if quiet {
                        if beginning == nil { beginning = bin }
                    } else { flush(bin) }
                }
            }
            flush(upper)
        }
        return try attaching(transitions, to: timing, targetChannels: target.checkedChannels,
                             targetDuration: target.duration, referenceDuration: reference.duration)
    }

    /// Rechecks serialized numeric witnesses and anchor geometry; no quiet span supplies timing votes.
    public static func attaching(
        _ transitions: [AdaptiveQuietTransition], to timing: AdaptiveTimingResult,
        targetChannels: Int, targetDuration: Double, referenceDuration: Double
    ) throws -> AdaptiveTimingResult {
        guard transitions.count + timing.regions.count <= 21600,
              targetDuration.isFinite, referenceDuration.isFinite,
              targetDuration > 0, targetDuration <= 7200, referenceDuration > 0, referenceDuration <= 7200 else {
            throw AlignEstimateError.invalidParameter("quiet transition bounds")
        }
        var previousEnd = -Double.infinity
        for transition in transitions {
            try Task.checkCancellation()
            guard transition.leftRegion >= 0, transition.leftRegion < timing.regions.count - 1,
                  [transition.sourceStart, transition.sourceEnd, transition.rateRatio, transition.offsetSeconds].allSatisfy(\.isFinite),
                  let map = geometry(left: timing.regions[transition.leftRegion], right: timing.regions[transition.leftRegion + 1]),
                  transition.sourceStart > timing.regions[transition.leftRegion].sourceEnd,
                  transition.sourceEnd < timing.regions[transition.leftRegion + 1].sourceStart,
                  transition.sourceEnd - transition.sourceStart >= 0.3 - 1e-9,
                  transition.sourceStart >= previousEnd,
                  abs(transition.rateRatio - map.rate) <= 1e-12, abs(transition.offsetSeconds - map.offset) <= 1e-9,
                  transition.target.isValid(channels: targetChannels, duration: targetDuration),
                  transition.reference.isValid(channels: 1, duration: referenceDuration),
                  transition.target.verifiedStart <= transition.sourceStart - guardSeconds + 1e-9,
                  transition.target.verifiedEnd >= transition.sourceEnd + guardSeconds - 1e-9,
                  transition.reference.verifiedStart <= map.rate * (transition.sourceStart - guardSeconds) + map.offset + 1e-9,
                  transition.reference.verifiedEnd >= map.rate * (transition.sourceEnd + guardSeconds) + map.offset - 1e-9 else {
                throw AlignEstimateError.invalidParameter("invalid quiet transition witness or anchor")
            }
            previousEnd = transition.sourceEnd
        }
        var result = timing
        result.quietTransitions = transitions.isEmpty ? nil : transitions
        return result
    }
}
