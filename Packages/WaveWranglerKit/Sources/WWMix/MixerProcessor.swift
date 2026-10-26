import Foundation
import WWCore

/// Targets may change between prepared windows. Ramps are linear amplitude, 10 ms, sample-clocked.
/// Insert topology/state/routing changes require a fresh recipe; they never mutate an offline job.
public struct MixerLiveControls: Sendable {
    public var inputGainDB: [ChannelReference: Double]
    public var speakers: [SpeakerID: SpeakerMixState]
    public var masterGainDB: Double
    public var mutedSpeakers: Set<SpeakerID> = []
    public var soloedSpeakers: Set<SpeakerID> = []
    public var masterMuted = false

    public init(recipe: MixerRecipe) {
        inputGainDB = Dictionary(uniqueKeysWithValues: recipe.routes.map { ($0.reference, $0.inputGainDB) })
        speakers = Dictionary(uniqueKeysWithValues: recipe.routes.map { ($0.speaker, $0.strip) })
        masterGainDB = recipe.master.gainDB
    }
}

public enum MixerLoadingEvent: Sendable {
    case loading(AudioUnitSlotID)
    case ready(MixerUnitStatus)
}

/// One serial non-realtime DSP owner. Playback and offline use independent instances of this exact
/// graph. Only already-authorized, time-corrected/cut PCM enters; no paths or readers reach effects.
public actor MixerProcessor {
    public nonisolated let recipe: MixerRecipe
    public nonisolated let latencyFrames: Int
    public nonisolated let tailFrames: Int
    private let speakerUnits: [[NativeAudioUnit]]
    private let masterUnits: [NativeAudioUnit]
    private var delays: [FrameDelay]
    private var inputGains: [GainRamp]
    private var leftGains: [GainRamp]
    private var rightGains: [GainRamp]
    private var masterGain: GainRamp
    private var nextInput: Int64
    private var discarded: Int
    private var emitted: Int64 = 0
    private var flushRemaining: Int?
    private var terminal = false
    private var failure: (any Error)?

    public static func load(
        recipe: MixerRecipe,
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
                let unit = try await NativeAudioUnit.load(slot, channels: channels, policy: recipe.policy)
                units.append(unit)
                progress(.ready(unit.status))
            }
            return units
        }
        var speakers: [[NativeAudioUnit]] = []
        for route in recipe.routes { speakers.append(try await chain(route.strip.inserts, channels: 1)) }
        let master = try await chain(recipe.master.inserts, channels: 2)
        try Task.checkCancellation()
        return try MixerProcessor(recipe: recipe, speakerUnits: speakers, masterUnits: master)
        #endif
    }

    init(recipe: MixerRecipe, speakerUnits: [[NativeAudioUnit]], masterUnits: [NativeAudioUnit]) throws {
        self.recipe = recipe
        self.speakerUnits = speakerUnits
        self.masterUnits = masterUnits
        let latencies = speakerUnits.map { $0.reduce(0) { $0 + $1.latencyFrames } }
        let parallelLatency = latencies.max() ?? 0
        latencyFrames = parallelLatency + masterUnits.reduce(0) { $0 + $1.latencyFrames }
        let reportedTail = (speakerUnits.map { $0.reduce(0) { $0 + $1.tailFrames } }.max() ?? 0)
            + masterUnits.reduce(0) { $0 + $1.tailFrames }
        guard latencyFrames <= recipe.policy.maximumLatencyFrames else { throw MixerFailure.latencyLimit }
        guard recipe.policy.tail == .truncate || reportedTail <= recipe.policy.maximumTailFrames else {
            throw MixerFailure.tailLimit
        }
        tailFrames = recipe.policy.tail == .truncate ? 0 : reportedTail
        delays = latencies.map { FrameDelay(frames: parallelLatency - $0) }
        inputGains = recipe.routes.map { GainRamp(Self.amplitude($0.inputGainDB)) }
        leftGains = recipe.routes.map {
            GainRamp(recipe.panLaw.gains(pan: $0.strip.pan).left * Self.amplitude($0.strip.gainDB))
        }
        rightGains = recipe.routes.map {
            GainRamp(recipe.panLaw.gains(pan: $0.strip.pan).right * Self.amplitude($0.strip.gainDB))
        }
        masterGain = GainRamp(Self.amplitude(recipe.master.gainDB))
        nextInput = recipe.programFrames.lowerBound - Int64(recipe.policy.prerollFrames)
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

    /// Poll while ANY editor is open, not just after close. Also capture at Save/Undo barriers.
    /// The UI must atomically persist returned slots in the normal document transaction (see guide).
    /// Capturing every unit also detects opaque vendor changes that emit no parameter notification.
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
              controls.inputGainDB.values.allSatisfy(EpisodeMixState.isValidGain),
              EpisodeMixState.isValidGain(controls.masterGainDB),
              controls.mutedSpeakers.isSubset(of: Set(controls.speakers.keys)),
              controls.soloedSpeakers.isSubset(of: Set(controls.speakers.keys)),
              controls.speakers.values.allSatisfy({
                  EpisodeMixState.isValidGain($0.gainDB) && $0.pan.isFinite && (-1...1).contains($0.pan)
              }) else {
            throw MixerFailure.invalidRecipe("invalid live controls")
        }
        guard recipe.routes.allSatisfy({ route in
            controls.speakers[route.speaker]?.speaker == route.speaker
                && controls.speakers[route.speaker]?.inserts == route.strip.inserts
        }) else { throw MixerFailure.staleDependencies }
        for (index, route) in recipe.routes.enumerated() {
            guard let gain = controls.inputGainDB[route.reference], let strip = controls.speakers[route.speaker] else {
                throw MixerFailure.staleDependencies
            }
            let pan = recipe.panLaw.gains(pan: strip.pan)
            let audible = !controls.mutedSpeakers.contains(route.speaker)
                && (controls.soloedSpeakers.isEmpty || controls.soloedSpeakers.contains(route.speaker))
            let fader = audible ? Self.amplitude(strip.gainDB) : 0
            inputGains[index].set(Self.amplitude(gain))
            leftGains[index].set(fader * pan.left)
            rightGains[index].set(fader * pan.right)
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
              window.channels.values.allSatisfy({ $0.count == window.frames.count }) else {
            throw MixerFailure.incompletePCM
        }
        guard window.channels.values.allSatisfy({ $0.allSatisfy(\.isFinite) }) else { throw MixerFailure.nonfinitePCM }
        do {
            let result = try render(channels: window.channels, count: window.frames.count)
            nextInput = window.frames.upperBound
            return result
        } catch {
            terminal = true
            failure = error
            throw error
        }
    }

    /// Drain latency and the declared tail in bounded windows. Call until nil; no device/file output.
    public func finishNext() throws -> MixerPCMOutput? {
        if let failure { throw failure }
        if terminal { return nil }
        try Task.checkCancellation()
        guard nextInput == recipe.programFrames.upperBound else { throw MixerFailure.incompletePCM }
        if flushRemaining == nil { flushRemaining = latencyFrames + tailFrames }
        guard let remaining = flushRemaining else { throw MixerFailure.incompletePCM }
        if remaining == 0 {
            let expected = Int64(recipe.programFrames.count + tailFrames)
            guard emitted == expected, discarded == 0 else { throw MixerFailure.incompletePCM }
            terminal = true
            return nil
        }
        let count = min(MixerRecipe.maximumWindowFrames, remaining)
        let zeros = Dictionary(uniqueKeysWithValues: recipe.routes.map {
            ($0.reference, [Float](repeating: 0, count: count))
        })
        do {
            let result = try render(channels: zeros, count: count)
            flushRemaining = remaining - count
            return result
        } catch {
            terminal = true
            failure = error
            throw error
        }
    }

    private var allUnits: [NativeAudioUnit] { speakerUnits.flatMap { $0 } + masterUnits }
    private func unit(_ id: AudioUnitSlotID) throws -> NativeAudioUnit {
        guard let unit = allUnits.first(where: { $0.slot.id == id }) else { throw MixerFailure.missingUnit(id) }
        return unit
    }
    private func ensureActive() throws {
        if let failure { throw failure }
        guard !terminal else { throw MixerFailure.finished }
    }
    private static func amplitude(_ db: Double) -> Float { Float(pow(10, db / 20)) }

    private func render(channels: [ChannelReference: [Float]], count: Int) throws -> MixerPCMOutput {
        let firstFrame = recipe.programFrames.lowerBound + emitted
        var output = [[Float](), [Float]()]
        output[0].reserveCapacity(count)
        output[1].reserveCapacity(count)
        var metered = Array(repeating: [Float](), count: recipe.routes.count)
        for offset in stride(from: 0, to: count, by: MixerRecipe.blockFrames) {
            try Task.checkCancellation()
            let blockCount = min(MixerRecipe.blockFrames, count - offset)
            var sum = Array(repeating: [Float](repeating: 0, count: blockCount), count: 2)
            for (index, route) in recipe.routes.enumerated() {
                guard let source = channels[route.reference] else { throw MixerFailure.incompletePCM }
                var mono = [Float](repeating: 0, count: blockCount)
                for frame in 0..<blockCount { mono[frame] = source[offset + frame] * inputGains[index].next() }
                for unit in speakerUnits[index] { mono = try unit.render([mono])[0] }
                mono = delays[index].process(mono)
                for frame in 0..<blockCount {
                    let left = mono[frame] * leftGains[index].next()
                    let right = mono[frame] * rightGains[index].next()
                    sum[0][frame] += left
                    sum[1][frame] += right
                    metered[index].append(max(abs(left), abs(right)))
                }
            }
            for unit in masterUnits { sum = try unit.render(sum) }
            let skip = min(discarded, blockCount)
            discarded -= skip
            for frame in 0..<blockCount {
                let gain = masterGain.next()
                let left = sum[0][frame] * gain, right = sum[1][frame] * gain
                guard left.isFinite, right.isFinite else { throw MixerFailure.nonfinitePCM }
                if frame >= skip { output[0].append(left); output[1].append(right) }
            }
        }
        emitted += Int64(output[0].count)
        return MixerPCMOutput(firstFrame: firstFrame, channels: output,
            speakerMeters: Dictionary(uniqueKeysWithValues: zip(recipe.routes, metered).map {
                ($0.0.speaker, MixerMeter($0.1))
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
