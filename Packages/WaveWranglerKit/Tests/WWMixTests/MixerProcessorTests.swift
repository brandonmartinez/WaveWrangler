@preconcurrency import AVFAudio
import AudioToolbox
import Darwin
import Foundation
import Testing
import WWCore
import WWDecode
import WWSources
@testable import WWMix

struct MixFixture {
    let episodeID = EpisodeID()
    let source = SourceRecord(displayNameHint: "Generated Primary", observations: .init(channelCount: .known(1)))
    let backup = SourceRecord(displayNameHint: "Never summed", observations: .init(channelCount: .known(2)))
    let speaker = SpeakerID()
    var episode: Episode {
        .init(id: episodeID, title: "Generated PCM", sources: [source, backup], speakerAssignments: [
            .init(speakerID: speaker, primary: .init(sourceID: source.id, channel: .unknown),
                primaryConfirmation: .userConfirmed, backups: [.init(sourceID: backup.id, statedChannel: 0)]),
        ])
    }

    func snapshot(_ source: SourceRecord, channels: Int = 1) -> MixerSourceSnapshot {
        var metadata = stat()
        metadata.st_mode = UInt16(S_IFREG | 0o644)
        metadata.st_size = 4096
        let witness = RawSourceIdentity(metadata, volumeUUID: "generated", fileSystemID: (1, 2))
        let format = FormatInterpretation(envelopeVersion: 1,
            container: .init(kind: .wave, typeCode: "WAVE", fileExtension: "wav", extensionMatchesContainer: true),
            codec: .init(kind: .linearPCM, formatID: "lpcm", formatFlags: 0), sourceSampleRate: 48_000,
            sampleFormat: .float(32, bigEndian: false), channelCount: channels,
            channelLayout: .init(isDeclaredBySource: false, layoutTag: nil, channelBitmap: nil, channelLabels: []),
            frames: .init(validFrames: 48_000, primingFrames: 0, remainderFrames: 0, hasPacketTable: false),
            packets: .init(framesPerPacket: 1, bytesPerPacket: 4, packetCount: 48_000, maximumPacketSize: 4,
                averageBitRate: nil, isVariableBitRate: false),
            output: .init(sampleRate: 48_000, channelCount: channels, representsSourceSamplesExactly: true),
            origin: .init(sourceSampleRate: 48_000, decodedFrameCount: 48_000,
                discardedLeadingStreamFrames: 0, declaredTrailingStreamFrames: 0),
            source: source.id, sourceFingerprint: .init())
        return .init(source: source.id, witness: witness, interpretation: format)
    }

    func recipe(_ episode: Episode? = nil, frames: Range<Int64> = 0..<4096,
                policy: MixerRenderPolicy = .init()) throws -> MixerRecipe {
        try MixerRecipe(episode: episode ?? self.episode,
            sources: [snapshot(source), snapshot(backup, channels: 2)], programFrames: frames, policy: policy)
    }
}

@Suite("Shared mixer processing", .serialized)
struct MixerProcessorTests {
    @Test func confirmedPrimariesOnlyAndUnknownMultichannelRefuses() throws {
        let f = MixFixture()
        let recipe = try f.recipe()
        #expect(recipe.routes.count == 1)
        #expect(recipe.routes[0].reference == ChannelReference(sourceID: f.source.id, statedChannel: 0))
        #expect(recipe.routes[0].source.source != f.backup.id)
        var episode = f.episode
        episode.speakerAssignments[0].primary = .init(sourceID: f.backup.id, channel: .unknown)
        #expect(throws: MixerFailure.unresolvedChannel(f.backup.id)) { try f.recipe(episode) }
        episode.speakerAssignments[0].primaryConfirmation = .provisional
        #expect(throws: MixerFailure.unconfirmedPrimary(f.speaker)) { try f.recipe(episode) }
    }

    @Test func neutralEqualPowerExactFramesAndNoAutomaticAttenuation() async throws {
        let f = MixFixture()
        let recipe = try f.recipe()
        let processor = try await MixerProcessor.load(recipe: recipe)
        let ref = recipe.routes[0].reference
        let output = try await processor.process(.init(frames: 0..<4096,
            channels: [ref: [Float](repeating: 0.5, count: 4096)]))
        #expect(output.frameCount == 4096 && output.firstFrame == 0)
        #expect(abs(output.channels[0][0] - Float(0.5 / sqrt(2))) < 0.000_001)
        #expect(abs(output.channels[1][4095] - output.channels[0][0]) < 0.000_001)
        #expect(try await processor.finishNext() == nil)
        var episode = f.episode
        let other = SpeakerID()
        episode.speakerAssignments.append(.init(speakerID: other,
            primary: .init(sourceID: f.backup.id, statedChannel: 1), primaryConfirmation: .userConfirmed))
        let two = try f.recipe(episode)
        let sum = try await MixerProcessor.load(recipe: two)
        let channels = Dictionary(uniqueKeysWithValues: two.routes.map {
            ($0.reference, [Float](repeating: 0.8, count: 4096))
        })
        let summed = try await sum.process(.init(frames: 0..<4096, channels: channels))
        #expect(abs(summed.channels[0][0] - Float(1.6 / sqrt(2))) < 0.000_001)
        #expect(summed.masterMeters[0].clipped)
    }

    @Test func sourceGainPrecedesNonlinearInsertAndFaderFollowsIt() async throws {
        let f = MixFixture()
        var episode = f.episode
        episode.mix = .init(inputGains: [.init(source: f.source.id, channel: 0, gainDB: 6)],
            speakers: [.init(speaker: f.speaker, gainDB: -6, pan: -1)])
        let recipe = try f.recipe(episode, frames: 0..<7)
        let effect = try generated(.square, channels: 1)
        let processor = try MixerProcessor(recipe: recipe, speakerUnits: [[effect]], masterUnits: [])
        let result = try await processor.process(.init(frames: 0..<7,
            channels: [recipe.routes[0].reference: [Float](repeating: 0.25, count: 7)]))
        let pre = 0.25 * pow(10, 6.0 / 20)
        let expected = Float(pre * pre * pow(10, -6.0 / 20))
        #expect(result.frameCount == 7)
        #expect(abs(result.channels[0][0] - expected) < 0.000_001)
        #expect(result.channels[1].allSatisfy { abs($0) < 0.000_001 })
    }

    @Test func insertOrderAndMasterAfterSumAreObservable() async throws {
        let f = MixFixture()
        var episode = f.episode
        episode.mix = .init(speakers: [.init(speaker: f.speaker, pan: -1)], master: .init(gainDB: -6))
        let recipe = try f.recipe(episode, frames: 0..<11)
        let first = try MixerProcessor(recipe: recipe, speakerUnits: [[
            generated(.add, channels: 1), generated(.square, channels: 1),
        ]], masterUnits: [generated(.square, channels: 2)])
        let second = try MixerProcessor(recipe: recipe, speakerUnits: [[
            generated(.square, channels: 1), generated(.add, channels: 1),
        ]], masterUnits: [generated(.square, channels: 2)])
        let window = MixerPCMWindow(frames: 0..<11,
            channels: [recipe.routes[0].reference: [Float](repeating: 0.2, count: 11)])
        let a = try await first.process(window), b = try await second.process(window)
        #expect(abs(a.channels[0][0] - pow(0.3, 4) * Float(pow(10, -6.0 / 20))) < 0.000_001)
        #expect(abs(b.channels[0][0] - pow(0.14, 2) * Float(pow(10, -6.0 / 20))) < 0.000_001)
        #expect(a.channels[0] != b.channels[0])
    }

    @Test func nonlinearMasterProcessesTheSumNotEachSpeakerIndependently() async throws {
        let f = MixFixture(), other = SpeakerID()
        var episode = f.episode
        episode.speakerAssignments.append(.init(speakerID: other,
            primary: .init(sourceID: f.backup.id, statedChannel: 0), primaryConfirmation: .userConfirmed))
        episode.mix = .init(speakers: [.init(speaker: f.speaker, pan: -1), .init(speaker: other, pan: -1)])
        let recipe = try f.recipe(episode, frames: 0..<9)
        let processor = try MixerProcessor(recipe: recipe, speakerUnits: [[], []],
            masterUnits: [generated(.square, channels: 2)])
        let channels = Dictionary(uniqueKeysWithValues: recipe.routes.map {
            ($0.reference, [Float](repeating: 0.2, count: 9))
        })
        let output = try await processor.process(.init(frames: 0..<9, channels: channels))
        #expect(abs(output.channels[0][0] - 0.16) < 0.000_001)
    }

    @Test func boundedRetriesAndUnwrittenOrInvalidVendorOutputNeverSucceed() throws {
        let slot = AudioUnitSlot(component: .init(type: kAudioUnitType_Effect, subtype: 0x57575453,
            manufacturer: kAudioUnitManufacturer_Apple))
        let transient = try GeneratedUnit(channels: 1, operation: .identity, latency: 0, tail: 0, failures: 2)
        let retrying = try NativeAudioUnit(slot: slot, unit: transient, channels: 1, policy: .init())
        #expect(try retrying.render([[0.2, 0.4]]) == [[0.2, 0.4]])
        let stuck = try GeneratedUnit(channels: 1, operation: .identity, latency: 0, tail: 0, failures: 4)
        let limited = try NativeAudioUnit(slot: slot, unit: stuck, channels: 1, policy: .init())
        #expect(throws: MixerFailure.noProgress) { try limited.render([[0.2]]) }
        let unwritten = try GeneratedUnit(channels: 1, operation: .unwritten, latency: 0, tail: 0)
        let invalid = try NativeAudioUnit(slot: slot, unit: unwritten, channels: 1, policy: .init())
        #expect(throws: MixerFailure.nonfinitePCM) { try invalid.render([[0.2]]) }
        unwritten.fullStateForDocument = ["invalid": Double.nan]
        #expect(throws: MixerFailure.self) { try invalid.capture() }
    }

    @Test func unusedSidechainInputsAreDisabledAfterStateRecall() throws {
        for channels in [1, 2] {
            var slot = AudioUnitSlot(component: .init(type: kAudioUnitType_Effect, subtype: 0x57575453,
                manufacturer: kAudioUnitManufacturer_Apple), productName: "Generated Sidechain Effect")
            slot.documentState = try PropertyListSerialization.data(
                fromPropertyList: ["auxiliaryEnabled": true], format: .binary, options: 0)
            let unit = try GeneratedUnit(channels: channels, operation: .identity, latency: 0, tail: 0,
                inputBusCount: 2)
            let host = try NativeAudioUnit(slot: slot, unit: unit, channels: channels, policy: .init())
            #expect(unit.inputBusses[0].isEnabled)
            #expect(!unit.inputBusses[1].isEnabled)
            let samples = Array(repeating: [Float(0.2), -0.4, 0.1], count: channels)
            #expect(try host.render(samples) == samples)
            #expect(try host.capture().documentState == slot.documentState)
        }
    }

    @Test func missingMainBussesAndMultipleOutputsStillRefuse() throws {
        let slot = AudioUnitSlot(component: .init(type: kAudioUnitType_Effect, subtype: 0x57575453,
            manufacturer: kAudioUnitManufacturer_Apple), productName: "Generated Multi-Bus Effect")
        for (inputs, outputs) in [(0, 1), (1, 0), (1, 2)] {
            let unit = try GeneratedUnit(channels: 1, operation: .identity, latency: 0, tail: 0,
                inputBusCount: inputs, outputBusCount: outputs)
            #expect(throws: MixerFailure.format(slot.id,
                "Generated Multi-Bus Effect needs 48 kHz mono audio. The effect must provide a main input and a single output bus.")) {
                try NativeAudioUnit(slot: slot, unit: unit, channels: 1, policy: .init())
            }
        }
    }

    @Test func changedNonfiniteFractionalAndOverBudgetLatencyOrTailRefuse() throws {
        let slot = AudioUnitSlot(component: .init(type: kAudioUnitType_Effect, subtype: 0x57575453,
            manufacturer: kAudioUnitManufacturer_Apple))
        for latency in [Double.nan, .infinity, -1, 0.5 / 48_000, 3] {
            let unit = try GeneratedUnit(channels: 1, operation: .identity, latency: 0, tail: 0)
            unit.reportedLatency = latency
            #expect(throws: MixerFailure.latencyLimit) {
                try NativeAudioUnit(slot: slot, unit: unit, channels: 1, policy: .init())
            }
        }
        let unit = try GeneratedUnit(channels: 1, operation: .identity, latency: 0, tail: 0)
        let host = try NativeAudioUnit(slot: slot, unit: unit, channels: 1, policy: .init(tail: .includeReported))
        unit.reportedLatency = 1.0 / 48_000
        #expect(throws: MixerFailure.changedLatency(slot.id)) { try host.render([[0.1]]) }
        unit.reportedLatency = 0
        unit.reportedTail = 1.0 / 48_000
        #expect(throws: MixerFailure.changedTail(slot.id)) { try host.render([[0.1]]) }
        let oversized = try GeneratedUnit(channels: 1, operation: .identity, latency: 0, tail: 100)
        #expect(throws: MixerFailure.tailLimit) {
            try NativeAudioUnit(slot: slot, unit: oversized, channels: 1,
                policy: .init(maximumTailFrames: 99, tail: .includeReported))
        }
    }

    @Test func persistentAppleEffectsAreChunkContinuous() async throws {
        let f = MixFixture()
        var episode = f.episode
        let slot = AudioUnitSlot(component: .init(type: kAudioUnitType_Effect,
            subtype: kAudioUnitSubType_LowPassFilter, manufacturer: kAudioUnitManufacturer_Apple))
        episode.mix = .init(speakers: [.init(speaker: f.speaker, inserts: [slot])])
        let recipe = try f.recipe(episode)
        let whole = try await MixerProcessor.load(recipe: recipe)
        let pieces = try await MixerProcessor.load(recipe: recipe)
        let samples = (0..<4096).map { Float(sin(Double($0) * 0.8)) * 0.2 }
        let ref = recipe.routes[0].reference
        let expected = try await whole.process(.init(frames: 0..<4096, channels: [ref: samples]))
        var actual: [Float] = []
        for range in [0..<113, 113..<1901, 1901..<4096] {
            let out = try await pieces.process(.init(frames: Int64(range.lowerBound)..<Int64(range.upperBound),
                channels: [ref: Array(samples[range])]))
            actual += out.channels[0]
        }
        #expect(actual.count == expected.frameCount)
        #expect(zip(actual, expected.channels[0]).allSatisfy { abs($0 - $1) < 0.000_001 })
    }

    @Test func parallelLatencyMasterLatencyPrerollAndTailHaveExactFrameAccounting() async throws {
        let f = MixFixture()
        var episode = f.episode
        let second = SpeakerID()
        episode.speakerAssignments.append(.init(speakerID: second,
            primary: .init(sourceID: f.backup.id, statedChannel: 0), primaryConfirmation: .userConfirmed))
        episode.mix = .init(speakers: [.init(speaker: f.speaker, pan: -1), .init(speaker: second, pan: 1)])
        let recipe = try f.recipe(episode, frames: 20..<1021,
            policy: .init(prerollFrames: 20, tail: .includeReported))
        let processor = try MixerProcessor(recipe: recipe, speakerUnits: [
            [generated(.identity, channels: 1, latency: 23, tail: 17)],
            [generated(.identity, channels: 1, latency: 0, tail: 0)],
        ], masterUnits: [generated(.identity, channels: 2, latency: 13, tail: 19)])
        #expect(processor.latencyFrames == 36 && processor.tailFrames == 36)
        var samples = [Float](repeating: 0, count: 1021)
        samples[20] = 0.5
        let input = Dictionary(uniqueKeysWithValues: recipe.routes.map { ($0.reference, samples) })
        var result = try await processor.process(.init(frames: 0..<1021, channels: input)).channels
        while let out = try await processor.finishNext() {
            result[0] += out.channels[0]; result[1] += out.channels[1]
        }
        #expect(result[0].count == 1001 + 36 && result[1].count == 1001 + 36)
        #expect(abs(result[0][0] - 0.5) < 0.000_001)
        #expect(abs(result[1][0] - 0.5) < 0.000_001)
        #expect(zip(result[0], result[1]).allSatisfy { abs($0 - $1) < 0.000_001 })
    }

    @Test func rampsRemainContinuousAcrossOddChunks() {
        var ramp = GainRamp(1)
        ramp.set(0)
        let first = (0..<113).map { _ in ramp.next() }
        ramp.set(0)
        let rest = (0..<367).map { _ in ramp.next() }
        #expect(abs(first[0] - Float(479.0 / 480)) < 0.000_001)
        #expect(abs(first.last! - rest[0]) < 0.003)
        #expect(rest.last == 0)
    }

    @Test func productionSoloMuteAndLiveGainsAreSeparateRampedControls() async throws {
        let recipe = try MixFixture().recipe(frames: 0..<1536)
        let processor = try await MixerProcessor.load(recipe: recipe)
        let route = recipe.routes[0]
        var controls = MixerLiveControls(recipe: recipe)
        controls.mutedSpeakers = [route.speaker]
        try await processor.setLiveControls(controls)
        let output = try await processor.process(.init(frames: 0..<512,
            channels: [route.reference: [Float](repeating: 0.5, count: 512)]))
        #expect(output.channels[0][0] > 0 && output.channels[0][0] < Float(0.5 / sqrt(2)))
        #expect(output.channels[0][511] == 0)
        controls.mutedSpeakers = []
        controls.soloedSpeakers = [route.speaker]
        controls.inputGainDB[route.reference] = 6
        controls.speakers[route.speaker]?.gainDB = -6
        try await processor.setLiveControls(controls)
        let restored = try await processor.process(.init(frames: 512..<1024,
            channels: [route.reference: [Float](repeating: 0.5, count: 512)]))
        #expect(abs(restored.channels[0][511] - Float(0.5 / sqrt(2))) < 0.000_001)
        controls.masterMuted = true
        try await processor.setLiveControls(controls)
        let muted = try await processor.process(.init(frames: 1024..<1536,
            channels: [route.reference: [Float](repeating: 0.5, count: 512)]))
        #expect(muted.channels[0][511] == 0 && muted.channels[1][511] == 0)
        #expect(processor.recipe.routes[0].strip.gainDB == 0)
    }

    @Test func liveUpdateAffectsTheNextShortBlockNotTheLongPreparedSourceWindow() async throws {
        let f = MixFixture()
        let recipe = try f.recipe(frames: 0..<Int64(MixerLiveTiming.sourceWindowFrames))
        let processor = try await MixerProcessor.load(recipe: recipe)
        let ref = recipe.routes[0].reference
        let raw = [Float](repeating: 0.5, count: MixerLiveTiming.sourceWindowFrames)
        let block = MixerLiveTiming.processingBlockFrames
        let before = try await processor.process(.init(frames: 0..<Int64(block),
            channels: [ref: Array(raw[0..<block])]))
        var controls = MixerLiveControls(recipe: recipe)
        controls.speakers[recipe.routes[0].speaker]?.gainDB = -12
        try await processor.setLiveControls(controls)
        let after = try await processor.process(.init(frames: Int64(block)..<Int64(2 * block),
            channels: [ref: Array(raw[block..<(2 * block)])]))
        #expect(after.channels[0][0] < before.channels[0][block - 1])
        #expect(abs(after.channels[0][479] - Float(0.5 / sqrt(2) * pow(10, -12.0 / 20))) < 0.000_001)
        #expect(after.firstFrame == Int64(block))
        #expect(MixerLiveTiming.maximumPreparedControlFrames <= MixerRecipe.sampleRate / 10)
        #expect(MixerLiveTiming.processingBlockFrames == 512)
    }

    @Test func frozenRecipeIncludesIdentityGainCutsAndDeclaredPolicy() throws {
        let f = MixFixture(), episode = MixFixture().episode
        let recipe = try f.recipe()
        #expect(recipe.isCurrent(in: f.episode, sources: [f.snapshot(f.source)]))
        #expect(!recipe.isCurrent(in: episode, sources: [f.snapshot(f.source)]))
        var changed = f.episode
        changed.mix = .init(inputGains: [.init(source: f.source.id, channel: 0, gainDB: 1)])
        #expect(!recipe.isCurrent(in: changed, sources: [f.snapshot(f.source)]))
        #expect(!recipe.isCurrent(in: f.episode, sources: []))
        #expect(throws: MixerFailure.self) {
            try f.recipe(frames: (-ManualEpisodeCut.frameLimit)..<0, policy: .init(prerollFrames: 1))
        }
    }

    @Test func malformedIncompleteDiscontinuousAndNonfinitePCMRefuse() async throws {
        let recipe = try MixFixture().recipe(frames: 0..<3)
        let processor = try await MixerProcessor.load(recipe: recipe), ref = recipe.routes[0].reference
        await #expect(throws: MixerFailure.discontinuousPCM) {
            try await processor.process(.init(frames: 1..<3, channels: [ref: [0, 0]]))
        }
        await #expect(throws: MixerFailure.incompletePCM) {
            try await processor.process(.init(frames: 0..<3, channels: [ref: [0, 0]]))
        }
        await #expect(throws: MixerFailure.nonfinitePCM) {
            try await processor.process(.init(frames: 0..<3, channels: [ref: [0, .nan, 0]]))
        }
        await #expect(throws: MixerFailure.incompletePCM) { try await processor.finishNext() }
    }

    @Test func offlineStaleCancellationAndExactSinkShape() async throws {
        let recipe = try MixFixture().recipe(frames: -11..<500_003)
        let sink = PCMCollector()
        try await MixerOfflineRenderer.render(recipe: recipe, isCurrent: { true }, input: { frames in
            .init(frames: frames, channels: [recipe.routes[0].reference: [Float](repeating: 0.2, count: frames.count)])
        }, sink: { output in await sink.append(output) })
        let outputs = await sink.outputs
        #expect(outputs.reduce(0, { $0 + $1.frameCount }) == 500_014)
        #expect(outputs.allSatisfy { $0.frameCount <= MixerRecipe.maximumWindowFrames && $0.channels.count == 2 })
        #expect(outputs.first?.firstFrame == -11)
        await #expect(throws: MixerFailure.staleDependencies) {
            try await MixerOfflineRenderer.render(recipe: recipe, isCurrent: { false },
                input: { _ in throw MixerFailure.incompletePCM }, sink: { _ in Issue.record("must not publish") })
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MixerOfflineRenderer.render(recipe: recipe, isCurrent: { true },
                input: { _ in throw MixerFailure.incompletePCM }, sink: { _ in Issue.record("must not publish") })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private func generated(_ operation: GeneratedUnit.Operation, channels: Int,
                           latency: Int = 0, tail: Int = 0) throws -> NativeAudioUnit {
        let slot = AudioUnitSlot(component: .init(type: kAudioUnitType_Effect, subtype: 0x57575453,
            manufacturer: kAudioUnitManufacturer_Apple))
        let unit = try GeneratedUnit(channels: channels, operation: operation, latency: latency, tail: tail)
        return try NativeAudioUnit(slot: slot, unit: unit, channels: channels,
            policy: .init(tail: .includeReported))
    }
}

actor PCMCollector {
    var outputs: [MixerPCMOutput] = []
    func append(_ value: MixerPCMOutput) { outputs.append(value) }
}

/// Generated DSP exercises the native pull path with independently known timing/nonlinear behavior.
private final class GeneratedUnit: AUAudioUnit, @unchecked Sendable {
    enum Operation { case identity, square, add, unwritten }
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let delay: Int
    private let tail: Int
    private let operation: Operation
    private var rings: [[Float]]
    private var cursor = 0
    private var failures: Int
    private var documentState: [String: Any]? = ["generated": true]
    var reportedLatency: TimeInterval?
    var reportedTail: TimeInterval?

    init(channels: Int, operation: Operation, latency: Int, tail: Int, failures: Int = 0,
         inputBusCount: Int = 1, outputBusCount: Int = 1) throws {
        delay = latency
        self.tail = tail
        self.operation = operation
        self.failures = failures
        rings = Array(repeating: [Float](repeating: 0, count: latency), count: channels)
        try super.init(componentDescription: .init(componentType: kAudioUnitType_Effect,
            componentSubType: 0x57575453, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0), options: [])
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000,
            channels: AVAudioChannelCount(channels)))
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input,
            busses: try (0..<inputBusCount).map { _ in try AUAudioUnitBus(format: format) })
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output,
            busses: try (0..<outputBusCount).map { _ in try AUAudioUnitBus(format: format) })
    }
    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var latency: TimeInterval { reportedLatency ?? Double(delay) / 48_000 }
    override var tailTime: TimeInterval { reportedTail ?? Double(tail) / 48_000 }
    override var fullStateForDocument: [String: Any]? {
        get { documentState }
        set {
            documentState = newValue
            if let enabled = newValue?["auxiliaryEnabled"] as? Bool {
                for index in (0..<inputBusses.count).dropFirst() { inputBusses[index].isEnabled = enabled }
            }
        }
    }
    override var internalRenderBlock: AUInternalRenderBlock {
        { [self] flags, time, count, _, output, _, pull in
            if failures > 0 {
                failures -= 1
                return kAudioUnitErr_CannotDoInCurrentContext
            }
            if case .unwritten = operation { return noErr }
            guard (0..<inputBusses.count).dropFirst().allSatisfy({ !inputBusses[$0].isEnabled }) else {
                return kAudioUnitErr_NoConnection
            }
            guard let pull else { return kAudioUnitErr_NoConnection }
            let status = pull(flags, time, count, 0, output)
            if status != noErr { return status }
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            for frame in 0..<Int(count) {
                for channel in buffers.indices {
                    guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else {
                        return kAudioUnitErr_InvalidParameter
                    }
                    var value = data[frame]
                    switch operation {
                    case .identity, .unwritten: break
                    case .square: value *= value
                    case .add: value += 0.1
                    }
                    if delay > 0 {
                        let prior = rings[channel][cursor]
                        rings[channel][cursor] = value
                        value = prior
                    }
                    data[frame] = value
                }
                if delay > 0 { cursor = (cursor + 1) % delay }
            }
            return noErr
        }
    }
}
