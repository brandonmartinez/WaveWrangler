import Foundation
import AudioToolbox
import Synchronization
import Testing
import WWCore
import WWCommonEdit
import WWDecode
import WWDerived
import WWSources
@testable import WWMix

private final class SupplementalAccess: Sendable {
    private let allowed = Mutex(true)
    func revoke() { allowed.withLock { $0 = false } }
    func validate() throws {
        guard allowed.withLock({ $0 }) else { throw NativeSourcePreparationFailure.notAuthorized }
    }
}

private struct SupplementalFixture {
    let root: URL
    let url: URL
    let source: SourceRecord
    let asset: AudioAsset
    let track = AudioTrack(name: "Generated music")
    let snapshot: MixerSourceSnapshot
    let admission: SourceReadAdmission
    let preparation: NativeSourcePreparation
    let permission: SupplementalAccess

    static func sample(_ frame: Int, _ channel: Int) -> Float {
        let value = frame == channel + 1 ? 24_000 : ((frame * (channel + 3) + channel * 307) % 12_000 - 6000)
        return Float(value) / 32768
    }

    init(rate: Int = 44_100, frames: Int = 441, channels: Int = 2,
         storage: Int64 = 1 << 30, codec: UInt32 = kAudioFormatLinearPCM) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ww-f4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let originals = root.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        url = originals.appendingPathComponent("generated.caf")
        var client = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 2), mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 2),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var format = codec == kAudioFormatLinearPCM ? client : AudioStreamBasicDescription(
            mSampleRate: Double(rate), mFormatID: codec, mFormatFlags: 1,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var created: ExtAudioFileRef?
        try #require(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &format, nil, 0, &created) == noErr)
        let file = try #require(created)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        try #require(ExtAudioFileSetProperty(file, kExtAudioFileProperty_FileChannelLayout,
            UInt32(MemoryLayout.size(ofValue: layout)), &layout) == noErr)
        try #require(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr)
        var pcm: [Int16] = []
        for frame in 0..<frames {
            for channel in 0..<channels { pcm.append(Int16(Self.sample(frame, channel) * 32768)) }
        }
        let status = pcm.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            return ExtAudioFileWrite(file, UInt32(frames), &list)
        }
        let closed = ExtAudioFileDispose(file)
        try #require(status == noErr && closed == noErr)
        source = SourceRecord(displayNameHint: "Generated source", purpose: .supplementalAudio)
        asset = .init(source: source.id, frameCount: Int64(frames), sampleRate: rate, channelCount: channels)
        let access = SourceAccessContext(io: SystemSourceIO(), ledger: SecurityScopeLedger())
        let decoder = SourceDecoder(access: access)
        let interpretation = try await decoder.withDecodingCursor(url, source: source.id) { $0.interpretation }
        let witness = try await decoder.captureRawIdentity(url, matching: interpretation.sourceFingerprint)
        snapshot = .init(source: source.id, witness: witness, interpretation: interpretation)
        permission = SupplementalAccess()
        admission = .init(source: source.id, location: url, witness: witness,
            authorization: .explicitUserRequest(for: source.id), availability: .on,
            validateCurrentAccess: { [permission] in try permission.validate() })
        preparation = try NativeSourcePreparation(root: root.appendingPathComponent("cache"),
            sourceLocations: [url], access: access, configuration: .init(maximumStorageBytes: storage))
    }

    func clip(at frame: Int64 = 0, channels: [Int]? = nil) -> AudioClip {
        .init(track: track.id, source: source.id, trim: .init(startFrame: 0, endFrame: asset.frameCount),
              channels: channels, anchor: .absolute(frame: frame))
    }

    func episode(clips: [AudioClip]? = nil) -> Episode {
        .init(title: "Synthetic audio-only", sources: [source],
              audioArrangement: .init(assets: [asset], tracks: [track], clips: clips ?? [clip()]))
    }

    func scheduler(_ episode: Episode, frames: Range<Int64>? = nil,
                   policy: MixerRenderPolicy = .init(),
                   preparation: NativeSourcePreparation? = nil) async throws -> SupplementalClipScheduler {
        let composition = try ProgramTimeline(episode: episode).composition()
        let range = try frames ?? #require(composition.programFrames)
        let recipe = try MixerRecipe(episode: episode, sources: [snapshot],
                                     programFrames: range, policy: policy, composition: composition)
        return try await SupplementalClipScheduler(recipe: recipe, preparation: preparation ?? self.preparation,
                                                   admissions: [source.id: admission])
    }

    func remove() throws { try FileManager.default.removeItem(at: root) }
}

@Suite("Supplemental clip production", .serialized)
struct SupplementalClipTests {
    @Test func nonseekableOverBudgetWorkingSetRefusesBeforeSchedulerBecomesReady() async throws {
        let first = try await SupplementalFixture(rate: 48_000, storage: 30_000, codec: kAudioFormatAppleLossless)
        defer { try? first.remove() }
        let second = try await SupplementalFixture(rate: 48_000, codec: kAudioFormatAppleLossless)
        defer { try? second.remove() }
        var episode = first.episode()
        episode.sources.append(second.source)
        episode.audioArrangement?.assets.append(second.asset)
        var overlay = second.clip()
        overlay.track = first.track.id
        episode.audioArrangement?.clips.append(overlay)
        let composition = try ProgramTimeline(episode: episode).composition()
        let recipe = try MixerRecipe(episode: episode, sources: [first.snapshot, second.snapshot],
            programFrames: 0..<441, composition: composition)
        await #expect(throws: NativeSourcePreparationFailure.storageBudgetExceeded) {
            try await SupplementalClipScheduler(recipe: recipe, preparation: first.preparation,
                admissions: [first.source.id: first.admission, second.source.id: second.admission])
        }
        _ = try await first.preparation.prepare(second.admission, expectedFormat: second.snapshot.interpretation)
    }

    @Test func nonseekableSchedulerRemainsPlayableWhenCompetingPreparationCannotFit() async throws {
        let first = try await SupplementalFixture(rate: 48_000, storage: 30_000, codec: kAudioFormatAppleLossless)
        defer { try? first.remove() }
        let other = try await SupplementalFixture(rate: 48_000, codec: kAudioFormatAppleLossless)
        defer { try? other.remove() }
        let scheduler = try await first.scheduler(first.episode())
        let consumer = try await scheduler.makeConsumer()
        let expected = try await consumer.read(0..<16)
        for _ in 0..<3 {
            await #expect(throws: NativeSourcePreparationFailure.storageBudgetExceeded) {
                try await first.preparation.prepare(other.admission, expectedFormat: other.snapshot.interpretation)
            }
            #expect(try await consumer.read(0..<16) == expected)
        }
        await consumer.release()
        _ = try await first.preparation.prepare(other.admission, expectedFormat: other.snapshot.interpretation)
    }

    @Test func cachedSchedulersReleaseCompletedConsumersAndReadmitAcrossEpisodes() async throws {
        let first = try await SupplementalFixture(rate: 48_000, storage: 30_000, codec: kAudioFormatAppleLossless)
        defer { try? first.remove() }
        let second = try await SupplementalFixture(rate: 48_000, codec: kAudioFormatAppleLossless)
        defer { try? second.remove() }
        let a = try await first.scheduler(first.episode())
        let expected = try await a.read(0..<16)[first.track.id]
        let b = try await second.scheduler(second.episode(), preparation: first.preparation)
        for _ in 0..<3 {
            #expect(try await b.read(0..<16)[second.track.id] == expected)
            #expect(try await a.read(0..<16)[first.track.id] == expected)
        }
    }

    @Test func cancelingOneConsumerPreservesAnotherOwnerAndPermitsLaterReadmission() async throws {
        let first = try await SupplementalFixture(rate: 48_000, storage: 30_000, codec: kAudioFormatAppleLossless)
        defer { try? first.remove() }
        let other = try await SupplementalFixture(rate: 48_000, codec: kAudioFormatAppleLossless)
        defer { try? other.remove() }
        let scheduler = try await first.scheduler(first.episode())
        let survivor = try await scheduler.makeConsumer()
        let started = SupplementalConsumerGate(), finish = SupplementalConsumerGate()
        let pending = Task {
            do {
                try await scheduler.withConsumer { consumer in
                    _ = try await consumer.read(0..<16)
                    await started.open()
                    await finish.wait()
                    try Task.checkCancellation()
                }
            } catch {
                await started.open()
                throw error
            }
        }
        await started.wait()
        pending.cancel()
        await finish.open()
        await #expect(throws: CancellationError.self) { try await pending.value }
        await #expect(throws: NativeSourcePreparationFailure.storageBudgetExceeded) {
            try await first.preparation.prepare(other.admission, expectedFormat: other.snapshot.interpretation)
        }
        #expect(try await survivor.read(0..<16)[first.track.id] != nil)
        await survivor.release()
        _ = try await first.preparation.prepare(other.admission, expectedFormat: other.snapshot.interpretation)
        #expect(try await scheduler.read(0..<16)[first.track.id] != nil)
    }

    @Test func failedConsumerReleasesClaimsWithoutDiscardingCachedMetadata() async throws {
        let first = try await SupplementalFixture(rate: 48_000, storage: 30_000, codec: kAudioFormatAppleLossless)
        defer { try? first.remove() }
        let other = try await SupplementalFixture(rate: 48_000, codec: kAudioFormatAppleLossless)
        defer { try? other.remove() }
        let scheduler = try await first.scheduler(first.episode())
        await #expect(throws: NativeSourcePreparationFailure.notAuthorized) {
            try await scheduler.withConsumer { _ in throw NativeSourcePreparationFailure.notAuthorized }
        }
        _ = try await first.preparation.prepare(other.admission, expectedFormat: other.snapshot.interpretation)
        #expect(try await scheduler.read(0..<16)[first.track.id] != nil)
    }

    @Test func schedulerSurvivesEvictionDuringConstructionAndRepeatedOverlappingReads() async throws {
        let first = try await SupplementalFixture(rate: 48_000, storage: 30_000)
        defer { try? first.remove() }
        let second = try await SupplementalFixture(rate: 48_000)
        defer { try? second.remove() }
        let originals = try [first.url, second.url].map { try Data(contentsOf: $0) }
        var episode = first.episode()
        episode.sources.append(second.source)
        episode.audioArrangement?.assets.append(second.asset)
        var overlay = second.clip()
        overlay.track = first.track.id
        episode.audioArrangement?.clips.append(overlay)
        let composition = try ProgramTimeline(episode: episode).composition()
        let recipe = try MixerRecipe(episode: episode, sources: [first.snapshot, second.snapshot],
            programFrames: 0..<441, composition: composition)
        let scheduler = try await SupplementalClipScheduler(recipe: recipe, preparation: first.preparation,
            admissions: [first.source.id: first.admission, second.source.id: second.admission])
        for range: Range<Int64> in [0..<16, 200..<237, 0..<16, 431..<441] {
            let actual = try #require(try await scheduler.read(range)[first.track.id])
            for channel in 0..<2 {
                #expect(actual[channel] == range.map { 2 * SupplementalFixture.sample(Int($0), channel) })
            }

            let assets = first.root.appendingPathComponent("cache/native-source-pcm-v1/assets")
            let bytes = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: [.fileSizeKey])
                .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            #expect(bytes <= 30_000)
        }
        #expect(try [first.url, second.url].map { try Data(contentsOf: $0) } == originals)
    }

    @Test func unchangedSchedulerRecoversExternalEvictionButStillRefusesRevocationAndMutation() async throws {
        let first = try await SupplementalFixture(rate: 48_000, storage: 30_000)
        defer { try? first.remove() }
        let other = try await SupplementalFixture(rate: 48_000)
        defer { try? other.remove() }
        let scheduler = try await first.scheduler(first.episode())
        let expected = try await scheduler.read(0..<16)
        _ = try await first.preparation.prepare(other.admission, expectedFormat: other.snapshot.interpretation)
        #expect(try await scheduler.read(0..<16) == expected)
        _ = try await first.preparation.prepare(other.admission, expectedFormat: other.snapshot.interpretation)
        first.permission.revoke()
        await #expect(throws: NativeSourcePreparationFailure.notAuthorized) { try await scheduler.read(0..<16) }

        let mutable = try await SupplementalFixture(rate: 48_000, storage: 30_000)
        defer { try? mutable.remove() }
        let stale = try await mutable.scheduler(mutable.episode())
        _ = try await mutable.preparation.prepare(other.admission, expectedFormat: other.snapshot.interpretation)
        var bytes = try Data(contentsOf: mutable.url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: mutable.url)
        await #expect(throws: (any Error).self) { try await stale.read(0..<16) }
    }

    @Test func editedFadeSequenceUsesProductionEnvelopeAcrossSeekChunksSplitsAndReopen() async throws {
        let f = try await SupplementalFixture()
        defer { try? f.remove() }
        let bytes = try Data(contentsOf: f.url)
        var clip = f.clip()
        clip.envelope = try AudioEnvelopeEditing(envelope: clip.envelope, durationFrames: 480)
            .fade(from: 0, to: 100, direction: .fadeIn, target: 0.25, initializingSilence: true)
            .confirmed(replacing: false)
        clip.envelope = try AudioEnvelopeEditing(envelope: clip.envelope, durationFrames: 480)
            .fade(from: 150, to: 250, direction: .fadeIn, target: 1).confirmed(replacing: false)
        clip.envelope = try AudioEnvelopeEditing(envelope: clip.envelope, durationFrames: 480)
            .fade(from: 300, to: 400, direction: .fadeOut, target: 0).confirmed(replacing: false)
        let evaluator = try AudioEnvelopeEvaluator(envelope: clip.envelope, durationFrames: 480)
        let unity = try await f.scheduler(f.episode())
        let raw = try #require(try await unity.read(0..<480)[f.track.id])
        let episode = f.episode(clips: [clip])
        let scheduler = try await f.scheduler(episode)
        let expected = try #require(try await scheduler.read(0..<480)[f.track.id])
        for frame in 0..<480 {
            let gain = Float(try evaluator.amplitude(atLocalFrame: Int64(frame)))
            for channel in 0..<2 { #expect(expected[channel][frame] == raw[channel][frame] * gain) }
        }
        #expect(expected.allSatisfy { $0[0] == 0 && $0[400...].allSatisfy { $0 == 0 } })
        let timeline = try ProgramTimeline(episode: episode)
        let projected = try timeline.composition().clips[0]
        let split = try projected.split(atProgramFrame: 2, timeline: timeline)
        var reopened = f.episode(clips: [split.leading, split.trailing])
        for _ in 0..<12 { reopened = try JSONDecoder().decode(Episode.self, from: JSONEncoder().encode(reopened)) }
        let pieces = try await f.scheduler(reopened)
        #expect(try await pieces.read(0..<480)[f.track.id] == expected)
        var chunked = [[Float](), [Float]()]
        for range: Range<Int64> in [0..<2, 2..<17, 17..<137, 137..<301, 301..<480] {
            let window = try #require(try await pieces.read(range)[f.track.id])
            for channel in 0..<2 { chunked[channel] += window[channel] }
        }
        #expect(chunked == expected)
        #expect(try await pieces.read(99..<157)[f.track.id] == expected.map { Array($0[99..<157]) })
        let processor = try await MixerProcessor.load(recipe: scheduler.recipe)
        let output = try await processor.process(.init(frames: 0..<480, channels: [:], audioTracks: [f.track.id: expected]))
        #expect(output.channels == expected, "The offline processor consumes the same enveloped production PCM.")
        #expect(try Data(contentsOf: f.url) == bytes)
    }

    @Test func audioOnlyStereoPlacementOverlapOrderedChannelsGapsAndImmutableSource() async throws {
        let f = try await SupplementalFixture(rate: 48_000, frames: 16)
        defer { try? f.remove() }
        let before = try Data(contentsOf: f.url)
        let scheduler = try await f.scheduler(f.episode(clips: [f.clip(at: -2), f.clip(at: 3, channels: [1, 0])]),
                                            frames: -4..<23)
        #expect(scheduler.recipe.routes.isEmpty)
        #expect(scheduler.recipe.audioTracks.map(\.track) == [f.track.id])
        #expect(scheduler.recipe.composition?.programFrames == -2..<19)
        let tracks = try await scheduler.read(-4..<23)
        let result = try #require(tracks[f.track.id])
        for (index, frame) in (-4..<23).enumerated() {
            for channel in 0..<2 {
                var expected: Float = 0
                if (-2..<14).contains(frame) { expected += SupplementalFixture.sample(frame + 2, channel) }
                if (3..<19).contains(frame) { expected += SupplementalFixture.sample(frame - 3, 1 - channel) }
                #expect(result[channel][index] == expected)
            }
        }
        let processor = try await MixerProcessor.load(recipe: scheduler.recipe)
        let output = try await processor.process(.init(frames: -4..<23, channels: [:], audioTracks: tracks))
        #expect(output.channels == result, "Stereo center must not halve, pan, or normalize the track sum.")
        #expect(output.audioTrackMeters[f.track.id]?.count == 2)
        #expect(try await processor.finishNext() == nil)
        #expect(try Data(contentsOf: f.url) == before)
    }

    @Test func exact44100SplitOwns2Plus478SamplesAndRetainsPhaseEnvelopeAndSupportAcrossReopens() async throws {
        let f = try await SupplementalFixture()
        defer { try? f.remove() }
        var clip = f.clip()
        clip.envelope = .init(points: [.init(frame: 0, amplitude: 0), .init(frame: 480, amplitude: 1)])
        let episode = f.episode(clips: [clip])
        let timeline = try ProgramTimeline(episode: episode)
        let original = try timeline.composition().clips[0]
        let split = try original.split(atProgramFrame: 2, timeline: timeline)
        #expect(split.leading.trim == clip.trim && split.trailing.trim == clip.trim)
        #expect(split.leading.durationFrames(asset: f.asset) == 2)
        #expect(split.trailing.durationFrames(asset: f.asset) == 478)
        let curve = try AudioEnvelopeEvaluator(envelope: split.trailing.envelope, durationFrames: 478)
        #expect(try curve.amplitude(atLocalFrame: 0) == 1.0 / 240)
        var edited = f.episode(clips: [split.leading, split.trailing])
        let nextTimeline = try ProgramTimeline(episode: edited)
        let trailing = try nextTimeline.composition().clips[1]
        guard case .source(let local, let native) = try trailing.sourcePosition(atProgramFrame: 2) else {
            Issue.record("Missing split sample"); return
        }
        #expect(local == 0 && native.description == "147/80")
        let again = try trailing.split(atProgramFrame: 17, timeline: nextTimeline)
        edited.audioArrangement?.clips = [split.leading, again.leading, again.trailing]
        for _ in 0..<147 { edited = try JSONDecoder().decode(Episode.self, from: JSONEncoder().encode(edited)) }
        let whole = try await f.scheduler(episode)
        let pieces = try await f.scheduler(edited)
        let expected = try #require(try await whole.read(0..<480)[f.track.id])
        let actual = try #require(try await pieces.read(0..<480)[f.track.id])
        #expect(actual == expected, "Splits preserve every impulse, stereo phase, and envelope sample bit-for-bit.")
        var chunked = [[Float](), [Float]()]
        for range: Range<Int64> in [0..<1, 1..<2, 2..<17, 17..<137, 137..<480] {
            let window = try #require(try await pieces.read(range)[f.track.id])
            for channel in 0..<2 { chunked[channel] += window[channel] }
        }
        #expect(chunked == expected)
        let seek = try #require(try await pieces.read(2..<19)[f.track.id])
        #expect(seek == expected.map { Array($0[2..<19]) })
        let restored = try split.trailing.selectingOutputFrames(0..<480, asset: f.asset, envelope: clip.envelope)
        #expect(restored.trim == clip.trim && restored.ownedOutputFrames(asset: f.asset) == 0..<480)
        #expect(try await f.scheduler(f.episode(clips: [restored])).read(2..<19)[f.track.id]
            == expected.map { Array($0[0..<17]) }, "Extending ownership preserves the retained source grid, not a cropped origin.")
        var independentlyTrimmed = clip
        independentlyTrimmed.trim = .init(startFrame: 1, endFrame: 441)
        #expect(independentlyTrimmed.durationFrames(asset: f.asset) == 479)
        #expect(throws: AudioEnvelopeError.invalidNativeTrim) {
            try AudioEnvelopeEvaluator.trimmedEnvelope(of: split.trailing, asset: f.asset,
                to: .init(startFrame: 2, endFrame: 441))
        }
    }

    @Test(arguments: [8_000, 32_000, 44_100, 48_000, 96_000, 192_000])
    func nativeRatesAndOddProducerWindowsHaveExactOwnedCounts(_ rate: Int) async throws {
        let f = try await SupplementalFixture(rate: rate, frames: 233)
        defer { try? f.remove() }
        let scheduler = try await f.scheduler(f.episode())
        let end = scheduler.recipe.programFrames.upperBound
        let expected = try #require(try await scheduler.read(0..<end)[f.track.id])
        #expect(expected[0].count == (233 * 48_000 + rate - 1) / rate)
        var actual = [[Float](), [Float]()]
        var next: Int64 = 0
        while next < end {
            let last = min(end, next + 37)
            let chunk = try #require(try await scheduler.read(next..<last)[f.track.id])
            for channel in 0..<2 { actual[channel] += chunk[channel] }
            next = last
        }
        #expect(actual == expected)
    }

    @Test func monoUpmixEnvelopeAndPostInsertStereoBalanceStayIndependentOfRecordingGain() async throws {
        let f = try await SupplementalFixture(rate: 48_000, frames: 1024, channels: 1)
        defer { try? f.remove() }
        var clip = f.clip()
        clip.envelope = .init(points: [.init(frame: 0, amplitude: 0.5)])
        var episode = f.episode(clips: [clip])
        episode.mix = .init(audioTracks: [.init(track: f.track.id, gainDB: -6, balance: 0.25)])
        let scheduler = try await f.scheduler(episode)
        let raw = try await scheduler.read(0..<1024)
        let processor = try await MixerProcessor.load(recipe: scheduler.recipe)
        let output = try await processor.process(.init(frames: 0..<1024, channels: [:], audioTracks: raw))
        let gain = Float(pow(10, -6.0 / 20) * 0.5 / sqrt(2))
        for frame in 0..<1024 {
            #expect(abs(output.channels[0][frame] - SupplementalFixture.sample(frame, 0) * gain * 0.75) < 1e-7)
            #expect(abs(output.channels[1][frame] - SupplementalFixture.sample(frame, 0) * gain) < 1e-7)
        }
        #expect(scheduler.recipe.dependencies.mix.inputGains.isEmpty)
    }

    @Test func activeWarmMediaRefusesRevocationMutationAndIncompleteAccess() async throws {
        let f = try await SupplementalFixture()
        defer { try? f.remove() }
        let scheduler = try await f.scheduler(f.episode())
        _ = try await scheduler.read(0..<10)
        f.permission.revoke()
        await #expect(throws: NativeSourcePreparationFailure.notAuthorized) { try await scheduler.read(10..<20) }
        await #expect(throws: MixerFailure.staleDependencies) {
            try await SupplementalClipScheduler(recipe: scheduler.recipe, preparation: f.preparation, admissions: [:])
        }
        let other = try await SupplementalFixture()
        defer { try? other.remove() }
        let changing = try await other.scheduler(other.episode())
        _ = try await changing.read(0..<10)
        var bytes = try Data(contentsOf: other.url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: other.url)
        await #expect(throws: (any Error).self) { try await changing.read(10..<20) }
    }

    @Test func unusedUnavailableAssetDoesNotAcquireAProductionRouteOrGrant() async throws {
        let f = try await SupplementalFixture()
        defer { try? f.remove() }
        let unused = SourceRecord(displayNameHint: "Unavailable unused asset", purpose: .supplementalAudio)
        var episode = f.episode()
        episode.sources.append(unused)
        episode.audioArrangement?.assets.append(.init(source: unused.id, frameCount: 48_000, sampleRate: 48_000, channelCount: 2))
        let scheduler = try await f.scheduler(episode)
        #expect(scheduler.recipe.audioSources.map(\.source) == [f.source.id])
        #expect(try await scheduler.read(0..<10).count == 1)
    }

    @Test func liveTrackBalanceSoloMuteAndFaderRetainTheShortControlHorizon() async throws {
        let f = try await SupplementalFixture(rate: 48_000, frames: 2048)
        defer { try? f.remove() }
        let scheduler = try await f.scheduler(f.episode())
        let processor = try await MixerProcessor.load(recipe: scheduler.recipe)
        let input = try await scheduler.read(0..<2048)
        var controls = MixerLiveControls(recipe: scheduler.recipe)
        controls.audioTracks[f.track.id]?.balance = 1
        controls.audioTracks[f.track.id]?.gainDB = -6
        try await processor.setLiveControls(controls)
        let first = try await processor.process(.init(frames: 0..<512, channels: [:],
            audioTracks: input.mapValues { $0.map { Array($0[0..<512]) } }))
        #expect(first.channels[0][511] == 0)
        #expect(abs(first.channels[1][511] - input[f.track.id]![1][511] * Float(pow(10, -6.0 / 20))) < 1e-7)
        controls.mutedAudioTracks = [f.track.id]
        try await processor.setLiveControls(controls)
        let muted = try await processor.process(.init(frames: 512..<1024, channels: [:],
            audioTracks: input.mapValues { $0.map { Array($0[512..<1024]) } }))
        #expect(muted.channels[0][511] == 0 && muted.channels[1][511] == 0)
        controls.mutedAudioTracks = []
        controls.soloedAudioTracks = [f.track.id]
        try await processor.setLiveControls(controls)
        let solo = try await processor.process(.init(frames: 1024..<1536, channels: [:],
            audioTracks: input.mapValues { $0.map { Array($0[1024..<1536]) } }))
        #expect(solo.channels[1][511] != 0)
        #expect(MixerLiveTiming.maximumPreparedControlFrames == 12_512)
        #expect(processor.recipe.audioTracks[0].strip.gainDB == 0)
    }
}

private actor SupplementalConsumerGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
