@preconcurrency import AVFAudio
import AudioToolbox
import Darwin
import Foundation
import Testing
import WWCore
import WWDecode
import WWSources
import WWCommonEdit
import WWTimeMap
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
    @Test func playbackSubmissionsAndCapturesPopulateSeparateExecutionDiagnostics() async throws {
        let f = MixFixture()
        let recipe = try f.recipe(frames: 0..<512)
        let processor = try MixerProcessor(recipe: recipe, speakerUnits: [[]],
            masterUnits: [generated(.identity, channels: 2)])
        try await processor.setLiveControls(MixerLiveControls(recipe: recipe), submittedAt: .now)
        _ = try await processor.process(.init(frames: 0..<512,
            channels: [recipe.routes[0].reference: Array(repeating: 0.1, count: 512)]), submittedAt: .now)
        _ = try await processor.captureDocumentStates()
        let snapshot = processor.diagnostics.snapshot
        #expect(snapshot[.controlsWait]?.count == 1)
        #expect(snapshot[.processWait]?.count == 1)
        #expect(snapshot[.render]?.count == 1)
        #expect(snapshot[.unitRender]?.count == 1)
        #expect(snapshot[.stateCapture]?.count == 1)
        #expect(snapshot.values.allSatisfy { $0.started == nil })
    }

    @Test func routeMetersExcludePrerollAndFollowCommonMasterLatency() async throws {
        let f = MixFixture(), track = AudioTrack(name: "Stereo meter test")
        var episode = f.episode
        episode.audioArrangement = .init(tracks: [track])
        episode.mix = .init(speakers: [.init(speaker: f.speaker, pan: -1)])
        let recipe = try f.recipe(episode, frames: 0..<8, policy: .init(prerollFrames: 4))
        let processor = try MixerProcessor(recipe: recipe, speakerUnits: [[]],
            masterUnits: [generated(.identity, channels: 2, latency: 3)], audioTrackUnits: [[]])
        var samples = [Float](repeating: 0, count: 12)
        samples[3] = 100
        samples[4] = 0.5
        let output = try await processor.process(.init(frames: -4..<8,
            channels: [recipe.routes[0].reference: samples],
            audioTracks: [track.id: [samples, samples.map { -$0 }]]))
        #expect(output.firstFrame == 0 && output.frameCount == 5)
        let speaker = try #require(output.speakerMeters[f.speaker])
        let stereo = try #require(output.audioTrackMeters[track.id])
        #expect(speaker.peak == 0.5 && !speaker.clipped)
        #expect(abs(speaker.rms - Float(0.5 / sqrt(5))) < 0.000_001)
        #expect(stereo.count == 2 && stereo.allSatisfy { $0 == speaker })
        #expect(output.masterMeters[0].peak == 1 && output.masterMeters[1].peak == 0.5)
    }

    @Test(arguments: [false, true], [false, true])
    func speechGateIsSampleClockedThroughLatencySeekPrerollAndFlush(seeking: Bool, restricted: Bool) async throws {
        let f = MixFixture(), track = AudioTrack(name: "Unaffected music")
        var episode = f.episode
        let occurrence = try SourceOccurrence(source: f.source.id, nominalRate: NominalRate(48_000), frameCount: 48_000)
        let group = RecorderGroupID(), epoch = RecordingEpochID()
        let reference = TimelineReference(group: group, epoch: epoch, occurrence: occurrence.id)
        let map = try AlignedTimelineMap(reference: reference, groups: [
            .init(group: group, reference: reference, epochs: [
                .init(epoch: epoch, mapping: .mapped(segments: [
                    .init(groupClockStart: .zero, groupClockEnd: ExactRational(1), rateRatio: .one, alignedOffset: .zero)
                ], provenance: .timelineReference))
            ], placements: [.init(occurrence: occurrence, spans: [
                .init(startFrame: 0, endFrame: 48_000, epoch: epoch, groupClockOffset: .zero)
            ])])
        ])
        episode.alignment = .init(maps: [.init(revision: 1, inputs: .init(sources: [.init(sourceID: f.source.id)]),
            map: try JSONDecoder().decode(EmbeddedJSON.self, from: JSONEncoder().encode(map)))], acceptedRevision: 1)
        episode.cleanup = .init(workingRange: .init(alignmentRevision: 1, tracksIn: 0.02, tracksOut: 0.06))
        episode.productionRange = .init(start: .absolute(frame: 0), end: .absolute(frame: 4096), restrictSpeech: restricted)
        episode.audioArrangement = .init(tracks: [track])
        episode.mix = .init(speakers: [.init(speaker: f.speaker, pan: -1)])
        let composition = try ProgramTimeline(episode: episode, dialogueFrames: 0..<48_000).composition()
        let first: Int64 = seeking ? 1703 : 0
        let recipe = try MixerRecipe(episode: episode, sources: [f.snapshot(f.source)],
            programFrames: first..<4096, policy: .init(prerollFrames: 37, tail: .includeReported),
            composition: composition)
        let processor = try MixerProcessor(recipe: recipe,
            speakerUnits: [[generated(.decay, channels: 1, latency: 23, tail: 31)]],
            masterUnits: [generated(.decay, channels: 2, latency: 13, tail: 19)],
            audioTrackUnits: [[generated(.identity, channels: 2, latency: 7)]])
        var output = [[Float](), [Float]()]
        var cursor = first - 37
        while cursor < 4096 {
            let end = min(cursor + 173, 4096), count = Int(end - cursor)
            let value = try await processor.process(.init(frames: cursor..<end,
                channels: [recipe.routes[0].reference: .init(repeating: 0.5, count: count)],
                audioTracks: [track.id: [.init(repeating: 0.25, count: count), .init(repeating: -0.25, count: count)]]))
            output[0] += value.channels[0]; output[1] += value.channels[1]
            cursor = end
        }
        while let value = try await processor.finishNext(maximumFrames: 17) {
            output[0] += value.channels[0]; output[1] += value.channels[1]
        }
        #expect(output[0].count == Int(4096 - first) + 50)
        let production = try #require(recipe.production)
        var speaker: Float = 0, left: Float = 0, right: Float = 0
        for frame in (first - 37)..<4096 {
            let input: Float = !restricted || (960..<2880).contains(frame) ? 0.5 : 0
            speaker = input + speaker * 0.5
            left = 0.25 + speaker * production.speechGain(atProgramFrame: frame) + left * 0.5
            right = -0.25 + right * 0.5
            if frame >= first {
                let index = Int(frame - first)
                #expect(abs(output[0][index] - left) < 0.000_001)
                #expect(abs(output[1][index] - right) < 0.000_001, "Speaker restriction must never gate music.")
            }
        }
        if restricted {
            #expect(output[0][Int(2880 - first)] > 0.5, "The common master's decay continues after Speaker Out.")
        }
        #expect(output[0].suffix(50).contains { $0 > 0 }, "Reported master tails may drain on natural completion, never on Stop.")
        #expect(throws: MixerFailure.self) {
            try MixerRecipe(episode: episode, sources: [f.snapshot(f.source)], programFrames: 0..<4097,
                composition: composition)
        }
        #expect(throws: MixerFailure.self) { try f.recipe(episode) }
    }

    @Test func supplementalProgramStateRefusesRatherThanSilentlyOmittingProductionInputs() throws {
        let f = MixFixture()
        var episode = f.episode
        let source = SourceRecord(displayNameHint: "Generated stereo", purpose: .supplementalAudio)
        let track = AudioTrack(name: "Music")
        let asset = AudioAsset(source: source.id, frameCount: 48_000, sampleRate: 48_000, channelCount: 2)
        episode.sources.append(source)
        episode.audioArrangement = .init(assets: [asset], tracks: [track])
        #expect(try f.recipe(episode).routes.count == 1, "Unplaced assets and empty tracks do not replace dialogue.")
        episode.audioArrangement?.clips = [.init(track: track.id, source: source.id,
            trim: .init(startFrame: 0, endFrame: 48_000), anchor: .programOrigin(frame: 0))]
        #expect(throws: MixerFailure.invalidRecipe("supplemental audio requires program projection and clip mixer routes")) {
            try f.recipe(episode)
        }
        episode.audioArrangement?.clips = []
        episode.audioArrangement?.insertionRegions = [.init(anchor: .programOrigin(frame: 0), durationFrames: 48_000)]
        #expect(throws: MixerFailure.self) { try f.recipe(episode) }
        episode = f.episode
        episode.sources[0].purpose = .supplementalAudio
        #expect(throws: MixerFailure.unresolvedChannel(f.source.id)) { try f.recipe(episode) }
    }

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

    @Test func singleSlotCaptureReadsOnlyItsUnitAndRenderingCanRunBetweenCaptures() async throws {
        let f = MixFixture()
        let slots = (0..<2).map { _ in
            AudioUnitSlot(component: .init(type: kAudioUnitType_Effect, subtype: 0x57575453,
                manufacturer: kAudioUnitManufacturer_Apple))
        }
        let units = try slots.map { _ in
            try GeneratedUnit(channels: 2, operation: .identity, latency: 0, tail: 0)
        }
        var episode = f.episode
        episode.mix = .init(master: .init(inserts: slots))
        let recipe = try f.recipe(episode, frames: 0..<32)
        let native = try zip(slots, units).map {
            try NativeAudioUnit(slot: $0.0, unit: $0.1, channels: 2, policy: .init())
        }
        let processor = try MixerProcessor(recipe: recipe, speakerUnits: [[]], masterUnits: native)
        let first = try await processor.captureDocumentState(slot: slots[0].id)
        #expect(first.id == slots[0].id && first.documentState != nil)
        #expect(units.map(\.documentCaptureCount) == [1, 0])
        let rendered = try await processor.process(.init(frames: 0..<32,
            channels: [recipe.routes[0].reference: .init(repeating: 0.25, count: 32)]))
        #expect(rendered.frameCount == 32 && units.map(\.renderCount) == [1, 1])
        let second = try await processor.captureDocumentState(slot: slots[1].id)
        #expect(second.id == slots[1].id)
        #expect(units.map(\.documentCaptureCount) == [1, 1])
        let complete = try await processor.captureDocumentStates()
        #expect(complete.map(\.id) == slots.map(\.id))
        #expect(units.map(\.documentCaptureCount) == [2, 2])
    }

    @Test func singleSlotCaptureRejectsMissingAndInvalidStatesWithoutReadingOtherUnits() async throws {
        let f = MixFixture()
        let slots = (0..<2).map { _ in
            AudioUnitSlot(component: .init(type: kAudioUnitType_Effect, subtype: 0x57575453,
                manufacturer: kAudioUnitManufacturer_Apple))
        }
        let units = try slots.map { _ in
            try GeneratedUnit(channels: 2, operation: .identity, latency: 0, tail: 0)
        }
        let native = try zip(slots, units).map {
            try NativeAudioUnit(slot: $0.0, unit: $0.1, channels: 2, policy: .init())
        }
        let processor = try MixerProcessor(recipe: f.recipe(), speakerUnits: [[]], masterUnits: native)
        let missing = AudioUnitSlotID()
        await #expect(throws: MixerFailure.missingUnit(missing)) {
            try await processor.captureDocumentState(slot: missing)
        }
        #expect(units.map(\.documentCaptureCount) == [0, 0])
        units[0].fullStateForDocument = ["invalid": Double.nan]
        await #expect(throws: MixerFailure.self) {
            try await processor.captureDocumentState(slot: slots[0].id)
        }
        #expect(units.map(\.documentCaptureCount) == [1, 0])
        units[0].fullStateForDocument = nil
        await #expect(throws: MixerFailure.self) { try await processor.captureDocumentStates() }
        #expect(units.map(\.documentCaptureCount) == [2, 0])
    }

    @Test func obsoleteSingleSlotCaptureChecksCancellationBeforeAndAfterVendorGetter() async throws {
        let f = MixFixture()
        let slot = AudioUnitSlot(component: .init(type: kAudioUnitType_Effect, subtype: 0x57575453,
            manufacturer: kAudioUnitManufacturer_Apple))
        let unit = try GeneratedUnit(channels: 2, operation: .identity, latency: 0, tail: 0)
        let native = try NativeAudioUnit(slot: slot, unit: unit, channels: 2, policy: .init())
        let processor = try MixerProcessor(recipe: f.recipe(), speakerUnits: [[]], masterUnits: [native])
        let obsolete = MixerStateCaptureCancellation()
        obsolete.cancel()
        await #expect(throws: CancellationError.self) {
            try await processor.captureDocumentState(slot: slot.id, cancellation: obsolete)
        }
        #expect(unit.documentCaptureCount == 0)
        let interrupted = MixerStateCaptureCancellation()
        unit.onDocumentCapture = { interrupted.cancel() }
        await #expect(throws: CancellationError.self) {
            try await processor.captureDocumentState(slot: slot.id, cancellation: interrupted)
        }
        #expect(unit.documentCaptureCount == 1, "An already-running getter cannot be interrupted.")
        unit.onDocumentCapture = nil
        let authoritative = try await processor.captureDocumentStates()
        #expect(authoritative.count == 1 && unit.documentCaptureCount == 2,
            "Canceling observation must not disable authoritative document barriers.")
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
        #expect(MixerLiveTiming.maximumScheduledAheadFrames == MixerRecipe.sampleRate / 4)
        #expect(MixerLiveTiming.maximumPreparedControlFrames == 12_512)
        #expect(MixerLiveTiming.refillLowWaterFrames == 9_600)
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

    @Test func audioTrackStereoInsertsFollowClipSumAndPrecedeBalanceAndCommonMaster() async throws {
        let f = MixFixture(), track = AudioTrack(name: "Stereo music")
        var episode = f.episode
        episode.audioArrangement = .init(tracks: [track])
        episode.mix = .init(inputGains: [.init(source: f.source.id, channel: 0, gainDB: 6)],
            speakers: [.init(speaker: f.speaker, pan: -1)],
            audioTracks: [.init(track: track.id, gainDB: -6, balance: 0.5)])
        let recipe = try f.recipe(episode, frames: 0..<7)
        let processor = try MixerProcessor(recipe: recipe, speakerUnits: [[]],
            masterUnits: [generated(.square, channels: 2)],
            audioTrackUnits: [[generated(.square, channels: 2)]])
        // Two same-track clips have already summed to L=.2+.3 and R=.1+.2.
        let output = try await processor.process(.init(frames: 0..<7,
            channels: [recipe.routes[0].reference: [Float](repeating: 0.1, count: 7)],
            audioTracks: [track.id: [.init(repeating: 0.5, count: 7), .init(repeating: 0.3, count: 7)]]))
        let gain = Float(pow(10, -6.0 / 20))
        let left = Float(0.1 * pow(10, 6.0 / 20)) + 0.25 * gain * 0.5
        let right = Float(0.09) * gain
        #expect(abs(output.channels[0][0] - left * left) < 1e-7)
        #expect(abs(output.channels[1][0] - right * right) < 1e-7)
    }

    @Test func unequalSpeakerTrackMasterLatencyAndReportedTailsKeepExactOwnership() async throws {
        let f = MixFixture(), track = AudioTrack(name: "Stereo music")
        var episode = f.episode
        episode.audioArrangement = .init(tracks: [track])
        episode.mix = .init(speakers: [.init(speaker: f.speaker, pan: -1)])
        let recipe = try f.recipe(episode, frames: 20..<1021,
                                 policy: .init(prerollFrames: 20, tail: .includeReported))
        let processor = try MixerProcessor(recipe: recipe,
            speakerUnits: [[generated(.identity, channels: 1, latency: 7, tail: 11)]],
            masterUnits: [generated(.identity, channels: 2, latency: 13, tail: 19)],
            audioTrackUnits: [[generated(.identity, channels: 2, latency: 23, tail: 17)]])
        #expect(processor.latencyFrames == 36 && processor.tailFrames == 36)
        var speaker = [Float](repeating: 0, count: 1021), left = speaker, right = speaker
        speaker[20] = 0.25; left[20] = 0.5; right[20] = -0.75
        var output = try await processor.process(.init(frames: 0..<1021,
            channels: [recipe.routes[0].reference: speaker], audioTracks: [track.id: [left, right]])).channels
        while let tail = try await processor.finishNext(maximumFrames: 17) {
            output[0] += tail.channels[0]; output[1] += tail.channels[1]
        }
        #expect(output[0].count == 1037 && output[1].count == 1037)
        #expect(output[0][0] == 0.75 && output[1][0] == -0.75)
        #expect(output[0].dropFirst().allSatisfy { $0 == 0 })
        #expect(output[1].dropFirst().allSatisfy { $0 == 0 })
    }

    @Test func soloIsSharedAcrossTypedSpeakerAndAudioTrackRoutesAndPCMShapesRefuse() async throws {
        let f = MixFixture(), track = AudioTrack(name: "Stereo music")
        var episode = f.episode
        episode.audioArrangement = .init(tracks: [track])
        let recipe = try f.recipe(episode, frames: 0..<1536)
        let processor = try await MixerProcessor.load(recipe: recipe)
        let reference = recipe.routes[0].reference
        var controls = MixerLiveControls(recipe: recipe)
        controls.soloedAudioTracks = [track.id]
        try await processor.setLiveControls(controls)
        let output = try await processor.process(.init(frames: 0..<512,
            channels: [reference: .init(repeating: 0.9, count: 512)],
            audioTracks: [track.id: [.init(repeating: 0.2, count: 512), .init(repeating: -0.4, count: 512)]]))
        #expect(output.channels[0][511] == 0.2 && output.channels[1][511] == -0.4)
        controls.soloedAudioTracks = []
        controls.soloedSpeakers = [f.speaker]
        try await processor.setLiveControls(controls)
        let speaker = try await processor.process(.init(frames: 512..<1024,
            channels: [reference: .init(repeating: 0.5, count: 512)],
            audioTracks: [track.id: [.init(repeating: 0.9, count: 512), .init(repeating: -0.9, count: 512)]]))
        #expect(abs(speaker.channels[0][511] - Float(0.5 / sqrt(2))) < 1e-7)
        #expect(speaker.channels[0][511] == speaker.channels[1][511])
        await #expect(throws: MixerFailure.incompletePCM) {
            try await processor.process(.init(frames: 1024..<1536,
                channels: [reference: .init(repeating: 0, count: 512)]))
        }
        await #expect(throws: MixerFailure.incompletePCM) {
            try await processor.process(.init(frames: 1024..<1536,
                channels: [reference: .init(repeating: 0, count: 512)],
                audioTracks: [track.id: [.init(repeating: 0, count: 512)]]))
        }
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
    enum Operation { case identity, square, add, decay, unwritten }
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private let delay: Int
    private let tail: Int
    private let operation: Operation
    private var rings: [[Float]]
    private var decay: [Float]
    private var cursor = 0
    private var failures: Int
    private var documentState: [String: Any]? = ["generated": true]
    private(set) var documentCaptureCount = 0
    private(set) var renderCount = 0
    var onDocumentCapture: (@Sendable () -> Void)?
    var reportedLatency: TimeInterval?
    var reportedTail: TimeInterval?

    init(channels: Int, operation: Operation, latency: Int, tail: Int, failures: Int = 0,
         inputBusCount: Int = 1, outputBusCount: Int = 1) throws {
        delay = latency
        self.tail = tail
        self.operation = operation
        self.failures = failures
        rings = Array(repeating: [Float](repeating: 0, count: latency), count: channels)
        decay = .init(repeating: 0, count: channels)
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
        get {
            documentCaptureCount += 1
            onDocumentCapture?()
            return documentState
        }
        set {
            documentState = newValue
            if let enabled = newValue?["auxiliaryEnabled"] as? Bool {
                for index in (0..<inputBusses.count).dropFirst() { inputBusses[index].isEnabled = enabled }
            }
        }
    }
    override var internalRenderBlock: AUInternalRenderBlock {
        { [self] flags, time, count, _, output, _, pull in
            renderCount += 1
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
                    case .decay:
                        value += decay[channel] * 0.5
                        decay[channel] = value
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
