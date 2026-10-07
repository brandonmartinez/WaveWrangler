import Foundation
import Testing
import WWCore
import WWDecode
@testable import WWDerived
import WWSources

/// Content digests are consent-gated: only an explicit request on an available, local source reaches the
/// content gateway. Refusals happen before any metadata, open or read.
@Suite("Decoded content digest")
struct ContentDigestTests {
    func digester(io: RecordingSourceIO, content: RecordingContentIO, chunkFrames: Int = 4096) -> DecodedContentDigester {
        DecodedContentDigester(decoder: SourceDecoder(
            access: SourceAccessContext(io: io),
            content: content,
            configuration: .init(chunkFrames: chunkFrames)
        ))
    }

    @Test func withoutAnExplicitRequestNothingIsTouched() async throws {
        let directory = try TemporaryDirectory("digest")
        let url = try directory.writeWAV("host.wav", frames: 4800, seed: 1)
        let source = SourceID()
        let io = RecordingSourceIO()
        let content = RecordingContentIO()
        let digester = digester(io: io, content: content)
        for authorization in [nil, ContentWorkAuthorization.explicitUserRequest(for: SourceID())] {
            await #expect(throws: ContentDigestRefusal.notExplicitlyRequested) {
                try await digester.digest(source: source, at: url, authorization: authorization, availability: .on)
            }
        }
        #expect(io.metadataCalls == 0)
        #expect(content.calls == 0)
    }

    @Test func sourceAvailabilityOffIsZeroContentEvenWhenRequested() async throws {
        let directory = try TemporaryDirectory("digest")
        let url = try directory.writeWAV("host.wav", frames: 4800, seed: 1)
        let source = SourceID()
        let io = RecordingSourceIO()
        let content = RecordingContentIO()
        await #expect(throws: ContentDigestRefusal.sourceAvailabilityOff) {
            try await digester(io: io, content: content).digest(
                source: source, at: url, authorization: .explicitUserRequest(for: source), availability: .off
            )
        }
        #expect(io.metadataCalls == 0)
        #expect(content.calls == 0)
        #expect(io.downloadRequests == 0)
    }

    @Test func aDatalessSourceIsRefusedWithoutOpeningOrDownloading() async throws {
        let directory = try TemporaryDirectory("digest")
        let url = try directory.writeWAV("host.wav", frames: 4800, seed: 1)
        let source = SourceID()
        let io = RecordingSourceIO { $0.isDataless = .known(true) }
        let content = RecordingContentIO()
        await #expect(throws: ContentDigestRefusal.decode(.notMaterialized)) {
            try await digester(io: io, content: content).digest(
                source: source, at: url, authorization: .explicitUserRequest(for: source), availability: .on
            )
        }
        #expect(content.calls == 0)
        #expect(io.downloadRequests == 0)
    }

    @Test func digestIsStableAcrossChunkingAndLeavesTheOriginalUnchanged() async throws {
        let directory = try TemporaryDirectory("digest")
        let url = try directory.writeWAV("host.wav", frames: 4800, seed: 1)
        let otherURL = try directory.writeWAV("other.wav", frames: 4800, seed: 2)
        let before = try FileSnapshot(url)
        let source = SourceID()
        let request = ContentWorkAuthorization.explicitUserRequest(for: source)

        let content = RecordingContentIO()
        let small = try await digester(io: RecordingSourceIO(), content: content, chunkFrames: 1000)
            .digest(source: source, at: url, authorization: request, availability: .on)
        let large = try await digester(io: RecordingSourceIO(), content: RecordingContentIO(), chunkFrames: 8192)
            .digest(source: source, at: url, authorization: request, availability: .on)
        let other = try await digester(io: RecordingSourceIO(), content: RecordingContentIO())
            .digest(source: source, at: otherURL, authorization: request, availability: .on)

        #expect(content.opens == 1)
        #expect(small == large)
        #expect(small.frameCount == 4800)
        #expect(small.value.hasPrefix(DecodedContentDigest.scheme))
        #expect(small.value.count == DecodedContentDigest.scheme.count + 64)
        #expect(small.format == .current)
        #expect(other.value != small.value)
        #expect(try FileSnapshot(url) == before, "the original is never modified")
        #expect(SourceRevision.decodedContent(small) == SourceRevision.decodedContent(large))
    }
}
