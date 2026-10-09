import Darwin
import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

/// RED contract: the selected-source identity must reach the only content gateway before any header byte.
/// The expectedIdentity overloads do not exist yet. Do not remove these calls to make this suite green.
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

    @Test func missingDescriptorIdentityRefusesBeforeParser() async throws {
        let directory = try FixtureDirectory("selected-primary-unknown")
        let primary = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 606)
        )
        var expected = try fingerprint(primary)
        expected.volumeUUID = .unknown
        let reads = ReadPolicyRecorder()
        var gateway = SystemSourceContentIO()
        gateway.readPolicyObserver = { reads.record($0) }
        #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            let reader = try gateway.openForDecoding(primary, expectedIdentity: expected)
            reader.close()
        }
        #expect(reads.policies.isEmpty)
    }

    @Test func pushAndCursorPathsCannotBypassCheckedOpen() async throws {
        let directory = try FixtureDirectory("selected-primary-all-paths")
        let primary = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 707)
        )
        let backup = try directory.write(
            spec, signal: LandmarkSignal(frames: 40_000, channelCount: 2, seed: 808)
        )
        let wrongIdentity = try fingerprint(backup)
        let reads = ReadPolicyRecorder()
        var gateway = SystemSourceContentIO()
        gateway.readPolicyObserver = { reads.record($0) }
        let decoder = makeDecoder(content: gateway)
        let journal = SinkJournal()
        await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            try await decoder.decode(
                primary, source: SourceID(), expectedIdentity: wrongIdentity
            ) { interpretation in
                JournalingSink(
                    inner: CollectingSink(channelCount: interpretation.channelCount),
                    journal: journal
                )
            }
        }
        await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            try await decoder.withDecodingCursor(
                primary, source: SourceID(), expectedIdentity: wrongIdentity
            ) { _ in 0 }
        }
        #expect(journal.events.isEmpty, "no sink may be created for a wrong opened descriptor")
        #expect(reads.policies.isEmpty)
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
