import Darwin
import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

/// RED contract: the selected-source identity must reach the only content gateway before any header byte.
/// Checked opens must use the same descriptor for identity verification and all later callbacks.
@Suite("RED selected-Primary checked descriptor open")
struct SelectedPrimaryCheckedOpenRedTests {
    private let spec = FixtureSpec(
        container: .wave, codec: .linearPCM, sampleFormat: .int(16, bigEndian: false),
        sampleRate: 16_000, channelCount: 2
    )

    private func fingerprint(_ url: URL) throws -> FileSystemFingerprint {
        guard case let .success(metadata) = SystemSourceIO().metadata(at: url) else {
            throw POSIXError(.ENOENT)
        }
        let value = metadata.fingerprint
        _ = try #require(value.fileIdentifier.value)
        _ = try #require(value.volumeUUID.value)
        _ = try #require(value.fileSize.value)
        _ = try #require(value.contentModificationDate.value)
        return value
    }

    @Test(arguments: [false, true])
    func pathReplacementBeforeParserRefusesWithoutHeaderReads(sameSize: Bool) async throws {
        let directory = try FixtureDirectory("selected-primary-replacement")
        let primary = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 101),
            name: "primary.wav"
        )
        let replacement = try directory.write(
            spec, signal: LandmarkSignal(
                frames: sameSize ? 40_000 : 41_000, channelCount: 2, seed: 202
            ), name: "replacement.wav"
        )
        let expected = try fingerprint(primary)
        let backup = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 303),
            name: "backup.wav"
        )
        let backupBefore = try FileSnapshot(backup)
        let reads = ReadPolicyRecorder()
        let swap = CheckedOpenProbe()
        var gateway = SystemSourceContentIO()
        gateway.readPolicyObserver = { reads.record($0) }
        gateway.descriptorOpener = { path in
            swap.recordOpen(String(cString: path))
            let didReplace = Darwin.rename(replacement.path, path) == 0
            swap.recordReplacement(didReplace)
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }

        await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            try await makeDecoder(content: gateway).readVerifiedPCMWindow(
                primary, source: SourceID(), channel: 1, startingAt: 0,
                expectedIdentity: expected
            )
        }
        #expect(swap.didReplace)
        #expect(swap.openedPaths == [primary.path])
        #expect(reads.policies.isEmpty, "even container header callbacks must not see the wrong file")
        #expect(try FileSnapshot(backup) == backupBefore)
    }

    @Test func selectedPrimaryChannelUsesOneCheckedDescriptorAndNeverOpensBackup() async throws {
        let directory = try FixtureDirectory("selected-primary-positive")
        let signal = LandmarkSignal(frames: 40_000, channelCount: 2, seed: 404)
        let primary = try directory.write(spec, signal: signal, name: "primary.wav")
        let backup = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 505),
            name: "backup.wav"
        )
        let expected = try fingerprint(primary)
        let before = try FileSnapshot(primary)
        let backupBefore = try FileSnapshot(backup)
        let probe = CheckedOpenProbe()
        var gateway = SystemSourceContentIO()
        gateway.descriptorOpener = { path in
            probe.recordOpen(String(cString: path))
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }

        let window = try await makeDecoder(content: gateway).readVerifiedPCMWindow(
            primary, source: SourceID(), channel: 1, startingAt: 0,
            expectedIdentity: expected
        )
        #expect(probe.openedPaths == [primary.path])
        #expect(window.channel == 1)
        #expect(window.sourceFrames == 0..<32_000)
        #expect(window.samples.count == 32_000)
        #expect(window.samples == Array(signal.channels[1].prefix(32_000)))
        #expect(try FileSnapshot(primary) == before)
        #expect(try FileSnapshot(backup) == backupBefore)
    }

    @Test(arguments: [false, true])
    func missingOrWrongDescriptorVolumeRefusesBeforeParser(wrongVolume: Bool) async throws {
        let directory = try FixtureDirectory("selected-primary-unknown")
        let primary = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 606)
        )
        var expected = try fingerprint(primary)
        expected.volumeUUID = wrongVolume ? .known("not-the-primary-volume") : .unknown
        let reads = ReadPolicyRecorder()
        let probe = CheckedOpenProbe()
        var gateway = SystemSourceContentIO()
        gateway.readPolicyObserver = { reads.record($0) }
        gateway.descriptorOpener = { path in
            probe.recordOpen(String(cString: path))
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            let reader = try gateway.openForDecoding(primary, expectedIdentity: expected)
            reader.close()
        }
        #expect(probe.openedPaths == [primary.path])
        #expect(reads.policies.isEmpty)
    }

    @Test func subMillisecondTimestampMismatchRefusesBeforeParser() throws {
        let directory = try FixtureDirectory("selected-primary-timestamp")
        let primary = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 707)
        )
        var expected = try fingerprint(primary)
        expected.contentModificationDate = .known(
            try #require(expected.contentModificationDate.value).addingTimeInterval(0.0005)
        )
        let reads = ReadPolicyRecorder()
        let probe = CheckedOpenProbe()
        var gateway = SystemSourceContentIO()
        gateway.readPolicyObserver = { reads.record($0) }
        gateway.descriptorOpener = { path in
            probe.recordOpen(String(cString: path))
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            let reader = try gateway.openForDecoding(primary, expectedIdentity: expected)
            reader.close()
        }
        #expect(probe.openedPaths == [primary.path])
        #expect(reads.policies.isEmpty)
    }

    @Test func cancellationAtLastWindowReadCannotPublishCheckedPCM() async throws {
        let source = try ScriptedSource()
        let expected = try fingerprint(source.url)
        let cancellation = TaskCancellationTarget()
        let triggered = Counter()
        let gate = AsyncStartGate()
        var script = source.script(
            source.aacFacts(valid: 32_000, remainder: 0, sampleRate: 16_000),
            streamFrames: ScriptedSource.aacPriming + 32_000
        )
        script.sampleScale = 1 / 100_000
        script.onRead = { index in
            if index == 2 {
                triggered.increment()
                cancellation.cancel()
            }
        }
        let content = ScriptedContentIO(script)
        let task = Task {
            await gate.wait()
            return try await makeDecoder(chunkFrames: 16_000, content: content)
                .readVerifiedPCMWindow(source.url, source: SourceID(), channel: 1, startingAt: 0,
                                       expectedIdentity: expected)
        }
        cancellation.install(task)
        gate.release()
        do {
            _ = try await task.value
            Issue.record("cancelled checked window unexpectedly returned")
        } catch {
            #expect(error as? DecodeFailure == .cancelled)
        }
        #expect(triggered.count == 1)
        #expect(content.record.closes == 1)
    }

    @Test(arguments: [false, true])
    func pushAndCursorPathsCannotBypassCheckedOpen(cursor: Bool) async throws {
        let directory = try FixtureDirectory("selected-primary-all-paths")
        let primary = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 707)
        )
        let expected = try fingerprint(primary)
        let replacement = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 909),
            name: "replacement.wav"
        )
        #expect(try FileSnapshot(primary).size == FileSnapshot(replacement).size)
        let backup = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 808)
        )
        let backupBefore = try FileSnapshot(backup)
        let reads = ReadPolicyRecorder()
        let swap = CheckedOpenProbe()
        var gateway = SystemSourceContentIO()
        gateway.readPolicyObserver = { reads.record($0) }
        gateway.descriptorOpener = { path in
            swap.recordOpen(String(cString: path))
            swap.recordReplacement(Darwin.rename(replacement.path, path) == 0)
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        let decoder = makeDecoder(content: gateway)
        let journal = SinkJournal()
        if cursor {
            await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
                try await decoder.withDecodingCursor(
                    primary, source: SourceID(), expectedIdentity: expected
                ) { _ in 0 }
            }
        } else {
            await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
                try await decoder.decode(
                    primary, source: SourceID(), expectedIdentity: expected
                ) { interpretation in
                    JournalingSink(
                        inner: CollectingSink(channelCount: interpretation.channelCount),
                        journal: journal
                    )
                }
            }
        }
        #expect(swap.openedPaths == [primary.path], "the selected Primary opener must actually run")
        #expect(swap.didReplace, "replace the path after metadata preflight, before descriptor open")
        #expect(journal.events.isEmpty, "no sink may be created for a wrong opened descriptor")
        #expect(reads.policies.isEmpty, "even container header callbacks must read zero bytes")
        #expect(try FileSnapshot(backup) == backupBefore)
    }

    @Test func checkedCallsNeverFallBackToAnUncheckedGateway() async throws {
        let directory = try FixtureDirectory("selected-primary-no-fallback")
        let primary = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 110)
        )
        let expected = try fingerprint(primary)
        let content = CountingContentIO()
        let decoder = makeDecoder(content: content)
        await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            try await decoder.withDecodingCursor(
                primary, source: SourceID(), expectedIdentity: expected
            ) { _ in 0 }
        }
        await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            try await decoder.decode(
                primary, source: SourceID(), expectedIdentity: expected
            ) { interpretation in
                CollectingSink(channelCount: interpretation.channelCount)
            }
        }
        #expect(content.opens == 0)
    }
}

private final class CheckedOpenProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var replaced = false
    private var paths: [String] = []

    var didReplace: Bool { lock.withLock { replaced } }
    var openedPaths: [String] { lock.withLock { paths } }
    func recordReplacement(_ result: Bool) { lock.withLock { replaced = result } }
    func recordOpen(_ path: String) { lock.withLock { paths.append(path) } }
}
