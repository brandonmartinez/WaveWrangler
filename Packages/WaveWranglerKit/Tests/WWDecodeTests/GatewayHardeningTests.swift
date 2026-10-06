import Darwin
import Foundation
import Testing
import WWCore
import WWSources
@testable import WWDecode

/// Records the dataless-materialization policy the gateway observed at each content read.
final class ReadPolicyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _policies: [Int32] = []
    var policies: [Int32] { lock.withLock { _policies } }
    func record(_ policy: Int32) { lock.withLock { _policies.append(policy) } }
}

@Suite("Content gateway hardening")
struct GatewayHardeningTests {
    static let specs: [FixtureSpec] = [
        FixtureSpec(container: .wave, codec: .linearPCM, sampleFormat: .int(16, bigEndian: false), sampleRate: 44_100, channelCount: 2),
        FixtureSpec(container: .caf, codec: .linearPCM, sampleFormat: .float(32, bigEndian: false), sampleRate: 48_000, channelCount: 1),
        FixtureSpec(container: .aiff, codec: .linearPCM, sampleFormat: .int(24, bigEndian: true), sampleRate: 96_000, channelCount: 2),
        FixtureSpec(container: .m4a, codec: .aac, sampleFormat: .lossy, sampleRate: 44_100, channelCount: 2),
        FixtureSpec(container: .m4a, codec: .appleLossless, sampleFormat: .lossless(24), sampleRate: 48_000, channelCount: 2),
    ]

    /// Header parsing (AudioFile properties, the ExtAudioFile wrap and its setters, the container-length
    /// check) and decoding all read through the gateway's descriptor; none may run with the default
    /// policy, under which a dataless file would be materialized (a provider download).
    @Test(arguments: specs)
    func everyContentReadRunsWithDatalessMaterializationOff(_ spec: FixtureSpec) async throws {
        let directory = try FixtureDirectory("policy")
        let url = try directory.write(spec, signal: LandmarkSignal(frames: 9_000, channelCount: spec.channelCount, seed: 41))
        let recorder = ReadPolicyRecorder()
        var gateway = SystemSourceContentIO()
        gateway.readPolicyObserver = { recorder.record($0) }
        let decoded = try await decodeAll(url, chunkFrames: 1024, content: gateway)
        let policies = recorder.policies
        #expect(decoded.report.readCalls > 1)
        #expect(policies.count > decoded.report.readCalls, "header reads are observed as well as decode reads")
        #expect(policies.allSatisfy { $0 == IOPOL_MATERIALIZE_DATALESS_FILES_OFF }, "policies seen: \(Set(policies))")
    }

    @Test func theDatalessPolicyIsRestoredAfterEachRead() {
        let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        let inside = withoutMaterializingDataless {
            getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        }
        let nested = withoutMaterializingDataless {
            withoutMaterializingDataless { () -> Void in }
            return getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        }
        #expect(inside == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        #expect(nested == IOPOL_MATERIALIZE_DATALESS_FILES_OFF, "an inner wrap restores the outer OFF policy")
        #expect(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == before)
    }

    /// `O_RDONLY` is 0, so flags such as `O_RDONLY | 2` look read-only in source. The gateway checks the
    /// descriptor's access mode and refuses anything writable before reading or publishing.
    @Test(arguments: [O_RDWR, O_WRONLY])
    func aWritableDescriptorIsRefusedBeforeAnyRead(_ accessMode: Int32) async throws {
        let directory = try FixtureDirectory("access-mode")
        let fixture = try directory.write(Self.specs[0], signal: LandmarkSignal(frames: 6_000, channelCount: 2, seed: 7))
        let url = try directory.copy(fixture, as: "writable.wav")
        let before = try FileSnapshot(url)
        let recorder = ReadPolicyRecorder()
        var gateway = SystemSourceContentIO()
        gateway.readPolicyObserver = { recorder.record($0) }
        gateway.descriptorOpener = { Darwin.open($0, accessMode | O_CLOEXEC | O_NOFOLLOW) }
        let journal = SinkJournal()
        var failure: DecodeFailure?
        do {
            _ = try await makeDecoder(content: gateway).decode(url, source: SourceID()) { interpretation in
                JournalingSink(inner: CollectingSink(channelCount: interpretation.channelCount, maximumChunk: 16_384), journal: journal)
            }
        } catch {
            failure = error
        }
        #expect(failure == .notOpenedReadOnly)
        #expect(recorder.policies.isEmpty, "nothing was read through the writable descriptor")
        #expect(journal.events.isEmpty, "no sink was made")
        #expect(try FileSnapshot(url) == before)
    }

    /// Control for the test above: the injected opener path itself decodes when it opens read-only.
    @Test func aReadOnlyInjectedOpenStillDecodes() async throws {
        let directory = try FixtureDirectory("access-mode-control")
        let url = try directory.write(Self.specs[0], signal: LandmarkSignal(frames: 6_000, channelCount: 2, seed: 7))
        var gateway = SystemSourceContentIO()
        gateway.descriptorOpener = { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        let decoded = try await decodeAll(url, content: gateway)
        #expect(decoded.interpretation.frames.validFrames == 6_000)
    }

    /// The "source untouched" evidence must see metadata-only writes, not just content and mtime.
    @Test(arguments: ["xattr added", "xattr value changed", "flags", "mode round trip"])
    func fileSnapshotSeesMetadataOnlyWrites(_ write: String) throws {
        let directory = try FixtureDirectory("snapshot")
        let url = try directory.writeBytes(Data(repeating: 0x11, count: 512), as: "probe.bin")
        chmod(url.path, 0o644)
        let marker = Array("v1".utf8)
        #expect(setxattr(url.path, "org.wavewrangler.test.existing", marker, marker.count, 0, XATTR_NOFOLLOW) == 0)
        let before = try FileSnapshot(url)
        switch write {
        case "xattr added":
            #expect(setxattr(url.path, "org.wavewrangler.test.added", marker, marker.count, 0, XATTR_NOFOLLOW) == 0)
        case "xattr value changed":
            let changed = Array("v2".utf8)
            #expect(setxattr(url.path, "org.wavewrangler.test.existing", changed, changed.count, 0, XATTR_NOFOLLOW) == 0)
        case "flags":
            #expect(chflags(url.path, UInt32(UF_HIDDEN)) == 0)
        default:
            #expect(chmod(url.path, 0o600) == 0)
            #expect(chmod(url.path, 0o644) == 0)
        }
        let after = try FileSnapshot(url)
        #expect(after.sha256 == before.sha256)
        #expect(after != before, "\(write) went unnoticed")
        chflags(url.path, 0)
    }
}
