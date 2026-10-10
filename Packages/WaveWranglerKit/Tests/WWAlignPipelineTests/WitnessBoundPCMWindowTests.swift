import Foundation
import Testing
import WWCore
import WWDecode
import WWSources
@testable import WWAlignPipeline

@Suite("Witness-bound selected-channel PCM windows")
struct WitnessBoundPCMWindowTests {
    private struct Fixture {
        let folder: URL
        let primary: URL
        let other: URL
        let source = SourceID()
        let access = SourceAccessContext()

        init(rate: Int = 16_000, channels: Int = 2, frames: Int = 32_000) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            primary = folder.appendingPathComponent("primary.wav")
            other = folder.appendingPathComponent("other.wav")
            try Self.wave(rate: rate, channels: channels, frames: frames).write(to: primary)
            try Self.wave(rate: rate, channels: channels, frames: frames).write(to: other)
        }

        func witness() async throws -> RawSourceIdentity {
            guard case let .success(metadata) = access.io.metadata(at: primary) else {
                throw DecodeFailure.notFound
            }
            return try await SourceDecoder(access: access).captureRawIdentity(primary, matching: metadata.fingerprint)
        }

        func remove() throws { try FileManager.default.removeItem(at: folder) }

        private static func wave(rate: Int, channels: Int, frames: Int) -> Data {
            var data = Data()
            func write<T: FixedWidthInteger>(_ number: T) {
                var littleEndian = number.littleEndian
                withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
            }
            let bytes = frames * channels * 2
            data.append(contentsOf: "RIFF".utf8)
            write(UInt32(36 + bytes))
            data.append(contentsOf: "WAVEfmt ".utf8)
            write(UInt32(16))
            write(UInt16(1))
            write(UInt16(channels))
            write(UInt32(rate))
            write(UInt32(rate * channels * 2))
            write(UInt16(channels * 2))
            write(UInt16(16))
            data.append(contentsOf: "data".utf8)
            write(UInt32(bytes))
            for _ in 0..<frames {
                for channel in 0..<channels { write(Int16(channel == 0 ? 0 : 16_384)) }
            }
            return data
        }
    }

    @Test func mapsOnlyChosenChannelIntoExactlyTwoSeconds() async throws {
        let fixture = try Fixture(frames: 36_000)
        defer { try? fixture.remove() }
        let witness = try await fixture.witness()
        let window = try await WitnessBoundPCMWindowReader(access: fixture.access).read(
            fixture.primary, source: fixture.source, matching: witness, channel: 1, startFrame: 4_000
        )
        #expect(window.source == fixture.source)
        #expect(window.firstSourceFrame == 4_000)
        #expect(window.sampleRate == 16_000)
        #expect(window.sourceFrameCount == 36_000)
        #expect(window.channelCount == 2)
        #expect(window.samples.count == 32_000)
        #expect(window.samples.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    @Test func wrongOpenedSourceIsRejectedBeforeAWindowCanEscape() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let witness = try await fixture.witness()
        let saved = fixture.folder.appendingPathComponent("saved.wav")
        try FileManager.default.moveItem(at: fixture.primary, to: saved)
        try FileManager.default.moveItem(at: fixture.other, to: fixture.primary)
        await #expect(throws: DecodeFailure.sourceIdentityMismatch) {
            _ = try await WitnessBoundPCMWindowReader(access: fixture.access).read(
                fixture.primary, source: fixture.source, matching: witness, channel: 0, startFrame: 0
            )
        }
    }

    @Test func unsupportedRateChannelAndRangeNeverBecomePCM() async throws {
        let fixture = try Fixture(rate: 48_000, channels: 1)
        defer { try? fixture.remove() }
        let witness = try await fixture.witness()
        let reader = WitnessBoundPCMWindowReader(access: fixture.access)
        await #expect(throws: WitnessBoundPCMWindowFailure.invalidChannel) {
            _ = try await reader.read(fixture.primary, source: fixture.source, matching: witness, channel: 1, startFrame: 0)
        }
        await #expect(throws: WitnessBoundPCMWindowFailure.invalidRange) {
            _ = try await reader.read(fixture.primary, source: fixture.source, matching: witness, channel: 0, startFrame: -1)
        }
        await #expect(throws: WitnessBoundPCMWindowFailure.invalidRange) {
            _ = try await reader.read(
                fixture.primary, source: fixture.source, matching: witness, channel: 0, startFrame: Int64.max
            )
        }
        await #expect(throws: WitnessBoundPCMWindowFailure.unsupportedSampleRate(48_000)) {
            _ = try await reader.read(fixture.primary, source: fixture.source, matching: witness, channel: 0, startFrame: 0)
        }
    }

    @Test func shorterSourceCannotFillAWindow() async throws {
        let fixture = try Fixture(channels: 1, frames: 31_999)
        defer { try? fixture.remove() }
        let witness = try await fixture.witness()
        await #expect(throws: WitnessBoundPCMWindowFailure.invalidRange) {
            _ = try await WitnessBoundPCMWindowReader(access: fixture.access).read(
                fixture.primary, source: fixture.source, matching: witness, channel: 0, startFrame: 0
            )
        }
    }

    @Test func cancelledRequestCannotIssuePCM() async throws {
        let fixture = try Fixture()
        defer { try? fixture.remove() }
        let witness = try await fixture.witness()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await WitnessBoundPCMWindowReader(access: fixture.access).read(
                fixture.primary, source: fixture.source, matching: witness, channel: 0, startFrame: 0
            )
        }
        await #expect(throws: DecodeFailure.cancelled) { try await cancelled.value }
    }
}
