import Foundation
import Synchronization
import WWCore

/// Targets may change between prepared windows. Ramps are linear amplitude, 10 ms, sample-clocked.
/// Insert topology/state/routing changes require a fresh recipe; they never mutate an offline job.
public struct MixerLiveControls: Sendable {
    public var inputGainDB: [ChannelReference: Double]
    public var speakers: [SpeakerID: SpeakerMixState]
    public var audioTracks: [AudioTrackID: AudioTrackMixState]
    public var masterGainDB: Double
    public var bypassedSlots: Set<AudioUnitSlotID>
    public var mutedSpeakers: Set<SpeakerID> = []
    public var soloedSpeakers: Set<SpeakerID> = []
    public var mutedAudioTracks: Set<AudioTrackID> = []
    public var soloedAudioTracks: Set<AudioTrackID> = []
    public var masterMuted = false

    public init(recipe: MixerRecipe) {
        inputGainDB = Dictionary(uniqueKeysWithValues: recipe.routes.map { ($0.reference, $0.inputGainDB) })
        speakers = Dictionary(uniqueKeysWithValues: recipe.routes.map { ($0.speaker, $0.strip) })
        audioTracks = Dictionary(uniqueKeysWithValues: recipe.audioTracks.map { ($0.track, $0.strip) })
        masterGainDB = recipe.master.gainDB
        bypassedSlots = Set((recipe.routes.flatMap(\.strip.inserts)
            + recipe.audioTracks.flatMap(\.strip.inserts) + recipe.master.inserts)
            .filter(\.bypassed).map(\.id))
    }
}

public enum MixerLoadingEvent: Sendable {
    case loading(AudioUnitSlotID)
    case ready(MixerUnitStatus)
}

/// Explicit cancellation for observations submitted by an unstructured operation queue.
/// Check on the processor too, so a getter queued behind rendering can become obsolete.
public final class MixerStateCaptureCancellation: Sendable {
    private let canceled = Atomic<Bool>(false)

    public init() {}
    public func cancel() { canceled.store(true, ordering: .releasing) }
    fileprivate func check() throws {
        if canceled.load(ordering: .acquiring) { throw CancellationError() }
    }
}

/// One serial non-realtime DSP owner. Playback and offline use independent instances of this exact
/// graph. Only authorized program-grid mono speaker/stereo track PCM enters; no readers reach effects.
public actor MixerProcessor {
    public nonisolated let recipe: MixerRecipe
    public nonisolated let latencyFrames: Int
    public nonisolated let tailFrames: Int
    private let speakerUnits: [[NativeAudioUnit]]
    private let audioTrackUnits: [[NativeAudioUnit]]
    private let masterUnits: [NativeAudioUnit]
    private var delays: [FrameDelay]
    private var audioTrackDelays: [[FrameDelay]]
    private var speakerMeterDelays: [FrameDelay]
    private var audioTrackMeterDelays: [[FrameDelay]]
    private var audioTrackGains: [[GainRamp]]
    private var inputGains: [GainRamp]
    private var leftGains: [GainRamp]
    private var rightGains: [GainRamp]
    private var masterGain: GainRamp
    private var nextInput: Int64
    private var renderFrame: Int64
    private let parallelLatency: Int
    private var discarded: Int
    private var emitted: Int64 = 0
    private var flushRemaining: Int?
    private var terminal = false
    private var failure: (any Error)?
    private let livePlayback: Bool
    private var playbackInputFrames: Int64 = 0
    private var playbackStartOffset: Int64 = 0
    private var playbackSegments: [(streamFrame: Int64, programFrame: Int64)] = []

    public static func load(
        recipe: MixerRecipe,
        livePlayback: Bool = false,
        progress: @Sendable (MixerLoadingEvent) -> Void = { _ in }
    ) async throws -> MixerProcessor {
        try Task.checkCancellation()
        #if !arch(arm64)
        throw MixerFailure.invalidRecipe("native arm64 is required for this qualification")
        #else
        func chain(_ slots: [AudioUnitSlot], channels: Int) async throws -> [NativeAudioUnit] {
            var units: [NativeAudioUnit] = []
            for slot in slots {
                try Task.checkCancellation()
                progress(.loading(slot.id))
                let unit = try await NativeAudioUnit.load(slot, channels: channels, policy: recipe.policy,
                                                         supportsLiveBypass: livePlayback)
                units.append(unit)
                progress(.ready(unit.status))
            }
            return units
        }
        var speakers: [[NativeAudioUnit]] = []
        for route in recipe.routes { speakers.append(try await chain(route.strip.inserts, channels: 1)) }
        var tracks: [[NativeAudioUnit]] = []
        for route in recipe.audioTracks { tracks.append(try await chain(route.strip.inserts, channels: 2)) }
        let master = try await chain(recipe.master.inserts, channels: 2)
        try Task.checkCancellation()
        return try MixerProcessor(recipe: recipe, speakerUnits: speakers, masterUnits: master,
                                  audioTrackUnits: tracks, livePlayback: livePlayback)
        #endif
    }

    init(recipe: MixerRecipe, speakerUnits: [[NativeAudioUnit]], masterUnits: [NativeAudioUnit],
         audioTrackUnits: [[NativeAudioUnit]] = [], livePlayback: Bool = false) throws {
        guard speakerUnits.count == recipe.routes.count, audioTrackUnits.count == recipe.audioTracks.count else {
            throw MixerFailure.invalidRecipe("unit chains do not match bus routes")
        }
        self.recipe = recipe
        self.livePlayback = livePlayback
        self.speakerUnits = speakerUnits
        self.audioTrackUnits = audioTrackUnits
        self.masterUnits = masterUnits
        let latencies = (speakerUnits + audioTrackUnits).map { $0.reduce(0) { $0 + $1.latencyFrames } }
        let parallelLatency = latencies.max() ?? 0
        self.parallelLatency = parallelLatency
        let masterLatency = masterUnits.reduce(0) { $0 + $1.latencyFrames }
        latencyFrames = parallelLatency + masterLatency
        let reportedTail = ((speakerUnits + audioTrackUnits).map { $0.reduce(0) { $0 + $1.tailFrames } }.max() ?? 0)
            + masterUnits.reduce(0) { $0 + $1.tailFrames }
        guard latencyFrames <= recipe.policy.maximumLatencyFrames else { throw MixerFailure.latencyLimit }
        guard recipe.policy.tail == .truncate || reportedTail <= recipe.policy.maximumTailFrames else {
            throw MixerFailure.tailLimit
        }
        tailFrames = recipe.policy.tail == .truncate ? 0 : reportedTail
        delays = latencies.prefix(speakerUnits.count).map { FrameDelay(frames: parallelLatency - $0) }
        audioTrackDelays = latencies.dropFirst(speakerUnits.count).map {
            [FrameDelay(frames: parallelLatency - $0), FrameDelay(frames: parallelLatency - $0)]
        }
        speakerMeterDelays = recipe.routes.map { _ in FrameDelay(frames: masterLatency) }
        audioTrackMeterDelays = recipe.audioTracks.map { _ in
            [FrameDelay(frames: masterLatency), FrameDelay(frames: masterLatency)]
        }
        audioTrackGains = recipe.audioTracks.map {
            let balance = MixerStereoBalance.gains(balance: $0.strip.balance)
            let gain = Self.amplitude($0.strip.gainDB)
            return [GainRamp(balance.left * gain), GainRamp(balance.right * gain)]
        }
        inputGains = recipe.routes.map { GainRamp(Self.amplitude($0.inputGainDB)) }
        leftGains = recipe.routes.map {
            GainRamp(recipe.panLaw.gains(pan: $0.strip.pan).left * Self.amplitude($0.strip.gainDB))
        }
        rightGains = recipe.routes.map {
            GainRamp(recipe.panLaw.gains(pan: $0.strip.pan).right * Self.amplitude($0.strip.gainDB))
        }
        masterGain = GainRamp(Self.amplitude(recipe.master.gainDB))
        nextInput = recipe.programFrames.lowerBound - Int64(recipe.policy.prerollFrames)
        renderFrame = nextInput
        discarded = recipe.policy.prerollFrames + latencyFrames
    }

    public func unitStatuses() -> [MixerUnitStatus] { allUnits.map(\.status) }

    public func parameters(slot: AudioUnitSlotID) throws -> [MixerParameter] {
        try unit(slot).parameters()
    }

    public func editor(slot: AudioUnitSlotID) throws -> MixerUnitEditor {
        MixerUnitEditor(try unit(slot).unit)
    }

    public func setParameter(slot: AudioUnitSlotID, address: UInt64, value: Float) throws {
        if let failure { throw failure }
        try unit(slot).setParameter(address: address, value: value)
    }

    /// Background observers may call once per slot, yielding the actor to rendering between units.
    /// The caller must validate the complete candidate and publish atomically, never slot by slot.
    public func captureDocumentState(slot: AudioUnitSlotID,
                                    cancellation: MixerStateCaptureCancellation? = nil) throws -> AudioUnitSlot {
        try cancellation?.check()
        let captured = try unit(slot).capture()
        try cancellation?.check()
        return captured
    }

    /// Authoritative Save/Undo/close capture: no suspension between units. Background observers
    /// must still periodically capture every unit to detect opaque edits without notifications.
    public func captureDocumentStates() throws -> [AudioUnitSlot] {
        let captured = try allUnits.map { try $0.capture() }
        guard captured.reduce(0, { $0 + ($1.documentState?.count ?? 0) }) <= EpisodeMixState.maximumDocumentStateBytes else {
            throw MixerFailure.invalidRecipe("combined captured document state exceeds the episode budget")
        }
        return captured
    }

    public func setLiveControls(_ controls: MixerLiveControls) throws {
        try ensureActive()
        guard Set(controls.inputGainDB.keys) == Set(recipe.routes.map(\.reference)),
              Set(controls.speakers.keys) == Set(recipe.routes.map(\.speaker)),
              Set(controls.audioTracks.keys) == Set(recipe.audioTracks.map(\.track)),
              controls.inputGainDB.values.allSatisfy(EpisodeMixState.isValidGain),
              EpisodeMixState.isValidGain(controls.masterGainDB),
              controls.bypassedSlots.isSubset(of: Set(allUnits.map(\.slot.id))),
              controls.mutedSpeakers.isSubset(of: Set(controls.speakers.keys)),
              controls.soloedSpeakers.isSubset(of: Set(controls.speakers.keys)),
              controls.mutedAudioTracks.isSubset(of: Set(controls.audioTracks.keys)),
              controls.soloedAudioTracks.isSubset(of: Set(controls.audioTracks.keys)),
              controls.audioTracks.values.allSatisfy({
                  EpisodeMixState.isValidGain($0.gainDB) && $0.balance.isFinite && (-1...1).contains($0.balance)
              }),
              controls.speakers.values.allSatisfy({
                  EpisodeMixState.isValidGain($0.gainDB) && $0.pan.isFinite && (-1...1).contains($0.pan)
              }) else {
            throw MixerFailure.invalidRecipe("invalid live controls")
        }
        guard recipe.routes.allSatisfy({ route in
            controls.speakers[route.speaker]?.speaker == route.speaker
                && controls.speakers[route.speaker]?.inserts == route.strip.inserts
        }), recipe.audioTracks.allSatisfy({
            controls.audioTracks[$0.track]?.track == $0.track
                && controls.audioTracks[$0.track]?.inserts == $0.strip.inserts
        }) else { throw MixerFailure.staleDependencies }
        guard allUnits.allSatisfy({
            $0.supportsLiveBypass || $0.status.bypassed == controls.bypassedSlots.contains($0.slot.id)
        }) else { throw MixerFailure.staleDependencies }
        for unit in allUnits { try unit.setBypassed(controls.bypassedSlots.contains(unit.slot.id)) }
        let hasSolo = !controls.soloedSpeakers.isEmpty || !controls.soloedAudioTracks.isEmpty
        for (index, route) in recipe.routes.enumerated() {
            guard let gain = controls.inputGainDB[route.reference], let strip = controls.speakers[route.speaker] else {
                throw MixerFailure.staleDependencies
            }
            let pan = recipe.panLaw.gains(pan: strip.pan)
            let audible = !controls.mutedSpeakers.contains(route.speaker)
                && (!hasSolo || controls.soloedSpeakers.contains(route.speaker))
            let fader = audible ? Self.amplitude(strip.gainDB) : 0
            inputGains[index].set(Self.amplitude(gain))
            leftGains[index].set(fader * pan.left)
            rightGains[index].set(fader * pan.right)
        }
        for (index, route) in recipe.audioTracks.enumerated() {
            guard let strip = controls.audioTracks[route.track] else { throw MixerFailure.staleDependencies }
            let audible = !controls.mutedAudioTracks.contains(route.track)
                && (!hasSolo || controls.soloedAudioTracks.contains(route.track))
            let balance = MixerStereoBalance.gains(balance: strip.balance)
            let gain = audible ? Self.amplitude(strip.gainDB) : 0
            audioTrackGains[index][0].set(gain * balance.left)
            audioTrackGains[index][1].set(gain * balance.right)
        }
        masterGain.set(controls.masterMuted ? 0 : Self.amplitude(controls.masterGainDB))
    }

    /// Includes real, authorized preroll if requested by policy. Never pad a missing program input.
    public func process(_ window: MixerPCMWindow) throws -> MixerPCMOutput {
        try ensureActive()
        try Task.checkCancellation()
        guard flushRemaining == nil, window.frames.lowerBound == nextInput,
              window.frames.upperBound <= recipe.programFrames.upperBound else {
            throw MixerFailure.discontinuousPCM
        }
        guard !window.frames.isEmpty, window.frames.count <= MixerRecipe.maximumWindowFrames,
              Set(window.channels.keys) == Set(recipe.routes.map(\.reference)),
              window.channels.values.allSatisfy({ $0.count == window.frames.count }),
              Set(window.audioTracks.keys) == Set(recipe.audioTracks.map(\.track)),
              window.audioTracks.values.allSatisfy({
                  $0.count == 2 && $0.allSatisfy({ $0.count == window.frames.count })
              }) else {
            throw MixerFailure.incompletePCM
        }
        guard window.channels.values.allSatisfy({ $0.allSatisfy(\.isFinite) }),
              window.audioTracks.values.allSatisfy({ $0.allSatisfy({ $0.allSatisfy(\.isFinite) }) }) else {
            throw MixerFailure.nonfinitePCM
        }
        do {
            let result = try render(channels: window.channels, audioTracks: window.audioTracks, count: window.frames.count)
            nextInput = window.frames.upperBound
            if livePlayback {
                playbackInputFrames += Int64(window.frames.count)
                if let index = playbackSegments.lastIndex(where: {
                    $0.streamFrame <= playbackInputFrames - Int64(latencyFrames)
                }), index > 0 { playbackSegments.removeFirst(index) }
            }
            return result
        } catch {
            terminal = true
            failure = error
            throw error
        }
    }

    /// Reuse a live graph and its warm effects at a program boundary; device output remains monotonic.
    public func beginPlaybackPass(at frame: Int64) throws {
        try ensureActive()
        guard livePlayback, flushRemaining == nil,
              frame >= recipe.programFrames.lowerBound - Int64(recipe.policy.prerollFrames),
              frame < recipe.programFrames.upperBound else { throw MixerFailure.staleDependencies }
        if playbackInputFrames == 0 {
            playbackStartOffset = frame + Int64(recipe.policy.prerollFrames) - recipe.programFrames.lowerBound
            emitted = playbackStartOffset
        }
        nextInput = frame
        renderFrame = frame
        playbackSegments.append((playbackInputFrames, frame))
    }

    /// Drain latency and the declared tail in bounded windows. Call until nil; no device/file output.
    public func finishNext(maximumFrames: Int = MixerRecipe.maximumWindowFrames) throws -> MixerPCMOutput? {
        if let failure { throw failure }
        if terminal { return nil }
        try Task.checkCancellation()
        guard (1...MixerRecipe.maximumWindowFrames).contains(maximumFrames) else {
            throw MixerFailure.incompletePCM
        }
        guard nextInput == recipe.programFrames.upperBound else { throw MixerFailure.incompletePCM }
        if flushRemaining == nil { flushRemaining = latencyFrames + tailFrames }
        guard let remaining = flushRemaining else { throw MixerFailure.incompletePCM }
        if remaining == 0 {
            let expected = livePlayback
                ? playbackStartOffset + playbackInputFrames - Int64(recipe.policy.prerollFrames) + Int64(tailFrames)
                : Int64(recipe.programFrames.count + tailFrames)
            guard emitted == expected, discarded == 0 else { throw MixerFailure.incompletePCM }
            terminal = true
            return nil
        }
        let count = min(maximumFrames, remaining)
        let zeros = Dictionary(uniqueKeysWithValues: recipe.routes.map {
            ($0.reference, [Float](repeating: 0, count: count))
        })
        let tracks = Dictionary(uniqueKeysWithValues: recipe.audioTracks.map {
            ($0.track, Array(repeating: [Float](repeating: 0, count: count), count: 2))
        })
        do {
            let result = try render(channels: zeros, audioTracks: tracks, count: count)
            flushRemaining = remaining - count
            return result
        } catch {
            terminal = true
            failure = error
            throw error
        }
    }

    private var allUnits: [NativeAudioUnit] { (speakerUnits + audioTrackUnits).flatMap { $0 } + masterUnits }
    private func unit(_ id: AudioUnitSlotID) throws -> NativeAudioUnit {
        guard let unit = allUnits.first(where: { $0.slot.id == id }) else { throw MixerFailure.missingUnit(id) }
        return unit
    }
    private func ensureActive() throws {
        if let failure { throw failure }
        guard !terminal else { throw MixerFailure.finished }
    }
    private static func amplitude(_ db: Double) -> Float { Float(pow(10, db / 20)) }

    private func programPosition(at offset: Int64) -> Int64 {
        let flushed = flushRemaining.map { latencyFrames + tailFrames - $0 } ?? 0
        let streamFrame = playbackInputFrames + Int64(flushed) + offset
        guard livePlayback, let segment = playbackSegments.last(where: {
            $0.streamFrame <= streamFrame
        }) ?? playbackSegments.first else { return renderFrame + offset }
        return segment.programFrame + streamFrame - segment.streamFrame
    }

    private func render(channels: [ChannelReference: [Float]], audioTracks: [AudioTrackID: [[Float]]],
                        count: Int) throws -> MixerPCMOutput {
        let firstFrame = recipe.programFrames.lowerBound + emitted
        var output = [[Float](), [Float]()]
        output[0].reserveCapacity(count)
        output[1].reserveCapacity(count)
        var metered = Array(repeating: [Float](), count: recipe.routes.count)
        var trackMeters = Array(repeating: [[Float](), [Float]()], count: recipe.audioTracks.count)
        for offset in stride(from: 0, to: count, by: MixerRecipe.blockFrames) {
            try Task.checkCancellation()
            let blockCount = min(MixerRecipe.blockFrames, count - offset)
            let skip = min(discarded, blockCount)
            discarded -= skip
            var sum = Array(repeating: [Float](repeating: 0, count: blockCount), count: 2)
            for (index, route) in recipe.routes.enumerated() {
                guard let source = channels[route.reference] else { throw MixerFailure.incompletePCM }
                var mono = [Float](repeating: 0, count: blockCount)
                for frame in 0..<blockCount {
                    let position = renderFrame + Int64(offset + frame)
                    let allowed = recipe.production.map {
                        !$0.restrictSpeech || $0.speakerProgramFrames?.contains(position) == true
                    } ?? true
                    mono[frame] = (allowed ? source[offset + frame] : 0) * inputGains[index].next()
                }
                for unit in speakerUnits[index] { mono = try unit.render([mono])[0] }
                mono = delays[index].process(mono)
                var meter = [Float](repeating: 0, count: blockCount)
                for frame in 0..<blockCount {
                    let position = programPosition(at: Int64(offset + frame - parallelLatency))
                    let speech = mono[frame] * (recipe.production?.speechGain(atProgramFrame: position) ?? 1)
                    let left = speech * leftGains[index].next()
                    let right = speech * rightGains[index].next()
                    sum[0][frame] += left
                    sum[1][frame] += right
                    meter[frame] = max(abs(left), abs(right))
                }
                metered[index] += speakerMeterDelays[index].process(meter).dropFirst(skip)
            }
            for (index, route) in recipe.audioTracks.enumerated() {
                guard let input = audioTracks[route.track] else { throw MixerFailure.incompletePCM }
                var stereo = input.map { Array($0[offset..<(offset + blockCount)]) }
                for unit in audioTrackUnits[index] { stereo = try unit.render(stereo) }
                for channel in 0..<2 {
                    stereo[channel] = audioTrackDelays[index][channel].process(stereo[channel])
                    for frame in 0..<blockCount {
                        let sample = stereo[channel][frame] * audioTrackGains[index][channel].next()
                        guard sample.isFinite else { throw MixerFailure.nonfinitePCM }
                        sum[channel][frame] += sample
                        stereo[channel][frame] = sample
                    }
                    trackMeters[index][channel] += audioTrackMeterDelays[index][channel].process(stereo[channel]).dropFirst(skip)
                }
            }
            for unit in masterUnits { sum = try unit.render(sum) }
            for frame in 0..<blockCount {
                let gain = masterGain.next()
                let left = sum[0][frame] * gain, right = sum[1][frame] * gain
                guard left.isFinite, right.isFinite else { throw MixerFailure.nonfinitePCM }
                if frame >= skip { output[0].append(left); output[1].append(right) }
            }
        }
        renderFrame += Int64(count)
        emitted += Int64(output[0].count)
        return MixerPCMOutput(firstFrame: firstFrame, channels: output,
            speakerMeters: Dictionary(uniqueKeysWithValues: zip(recipe.routes, metered).map {
                ($0.0.speaker, MixerMeter($0.1))
            }), audioTrackMeters: Dictionary(uniqueKeysWithValues: zip(recipe.audioTracks, trackMeters).map {
                ($0.0.track, $0.1.map(MixerMeter.init))
            }))
    }
}

struct GainRamp {
    private var value: Float
    private var target: Float
    private var remaining = 0
    init(_ value: Float) { self.value = value; target = value }
    mutating func set(_ target: Float) {
        guard target != self.target else { return }
        self.target = target
        remaining = 480
    }
    mutating func next() -> Float {
        if remaining > 0 {
            value += (target - value) / Float(remaining)
            remaining -= 1
        }
        return value
    }
}

struct FrameDelay {
    private var samples: [Float]
    private var cursor = 0
    init(frames: Int) { samples = .init(repeating: 0, count: frames) }
    mutating func process(_ input: [Float]) -> [Float] {
        guard !samples.isEmpty else { return input }
        var output = input
        for index in input.indices {
            output[index] = samples[cursor]
            samples[cursor] = input[index]
            cursor += 1
            if cursor == samples.count { cursor = 0 }
        }
        return output
    }
}

/// No whole-program collection or file writing. The sink must stage results and publish only after
/// this call returns successfully; cancellation/staleness may invalidate previously delivered blocks.
public enum MixerOfflineRenderer {
    public static func render(
        recipe: MixerRecipe,
        isCurrent: @Sendable () async throws -> Bool,
        input: @Sendable (Range<Int64>) async throws -> MixerPCMWindow,
        sink: @Sendable (MixerPCMOutput) async throws -> Void
    ) async throws {
        let processor = try await MixerProcessor.load(recipe: recipe)
        var next = recipe.programFrames.lowerBound - Int64(recipe.policy.prerollFrames)
        while next < recipe.programFrames.upperBound {
            try Task.checkCancellation()
            guard try await isCurrent() else { throw MixerFailure.staleDependencies }
            let frames = next..<min(next + Int64(MixerRecipe.maximumWindowFrames), recipe.programFrames.upperBound)
            let window = try await input(frames)
            guard window.frames == frames else { throw MixerFailure.discontinuousPCM }
            let output = try await processor.process(window)
            try Task.checkCancellation()
            guard try await isCurrent() else { throw MixerFailure.staleDependencies }
            if output.frameCount > 0 { try await sink(output) }
            next = frames.upperBound
        }
        while let output = try await processor.finishNext() {
            try Task.checkCancellation()
            guard try await isCurrent() else { throw MixerFailure.staleDependencies }
            if output.frameCount > 0 { try await sink(output) }
        }
        try Task.checkCancellation()
        guard try await isCurrent() else { throw MixerFailure.staleDependencies }
    }
}
