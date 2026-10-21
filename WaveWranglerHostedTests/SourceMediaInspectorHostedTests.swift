import Foundation
import CoreGraphics
import ImageIO
import Testing
import WWCore
import WWSources
@testable import WaveWrangler

@MainActor
@Suite("Local header inspection and owned avatars", .serialized)
struct SourceMediaInspectorHostedTests {
    @Test func residentImportObservesExactHeaderFactsWithoutConfirmingOrChangingOriginals() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.wav")
        let original = Self.wave(rate: 48_000, channels: 2, frames: 60_000)
        try original.write(to: url)
        let access = SourceAccessContext()
        let key = DeviceAccessKey(showID: ShowID(), sourceID: SourceID())
        let record = try Self.record(key: key, url: url, access: access, confirmation: .provisional)
        let records = InMemoryDeviceAccessStore([record])
        let inspector = SourceMediaInspector(accessStore: records, access: access)
        await #expect(throws: SourceMediaInspector.Failure.self) { try await inspector.inspect(key) }
        let facts = try await inspector.inspect(key, permitProvisional: true)
        #expect(facts.durationSeconds == .known(1.25))
        #expect(facts.channelCount == .known(2))
        #expect(facts.sampleRate == .known(48_000))
        #expect(facts.isComplete)
        #expect(try await inspector.inspect(key, permitProvisional: true) == facts)
        #expect(await records.record(for: key) == record)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func changedMediaRefusesUntilExplicitRelinkThenInvalidatesCachedHeaderFacts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.wav")
        try Self.wave(rate: 48_000, channels: 2, frames: 60_000).write(to: url)
        let access = SourceAccessContext()
        let key = DeviceAccessKey(showID: ShowID(), sourceID: SourceID())
        let records = InMemoryDeviceAccessStore([try Self.record(key: key, url: url, access: access, confirmation: .userConfirmed)])
        let inspector = SourceMediaInspector(accessStore: records, access: access)
        #expect(try await inspector.inspect(key).durationSeconds == .known(1.25))
        let changed = Self.wave(rate: 16_000, channels: 1, frames: 32_000)
        try changed.write(to: url)
        await #expect(throws: SourceMediaInspector.Failure.self) { try await inspector.inspect(key) }
        await records.save(try Self.record(key: key, url: url, access: access, confirmation: .userConfirmed))
        let refreshed = try await inspector.inspect(key)
        #expect(refreshed.durationSeconds == .known(2))
        #expect(refreshed.channelCount == .known(1))
        #expect(refreshed.sampleRate == .known(16_000))
        #expect(try Data(contentsOf: url) == changed)
        try FileManager.default.removeItem(at: url)
        await #expect(throws: SourceMediaInspector.Failure.self) { try await inspector.inspect(key) }
    }

    @Test func missingPermissionIsNotInventedMetadata() async throws {
        let inspector = SourceMediaInspector(accessStore: InMemoryDeviceAccessStore(), access: SourceAccessContext())
        await #expect(throws: SourceMediaInspector.Failure.self) {
            try await inspector.inspect(.init(showID: ShowID(), sourceID: SourceID()), permitProvisional: true)
        }
    }

    @Test func avatarNormalizationOwnsBoundedPixelsAfterTheSelectedFileIsRemoved() async throws {
        let bitmap = try #require(CGContext(data: nil, width: 1024, height: 512, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        let original = try #require(bitmap.makeImage())
        let encoded = NSMutableData()
        let encoder = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, original, nil)
        try #require(CGImageDestinationFinalize(encoder))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-avatar-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try (encoded as Data).write(to: url)
        let owned = try await SpeakerAvatarImport.png(from: url)
        try FileManager.default.removeItem(at: url)
        let source = try #require(CGImageSourceCreateWithData(owned as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 256 && image.height == 128)
        #expect(owned.count <= 512 * 1024)
        #expect(SpeakerAppearance(color: .blue, avatarPNG: owned).isValid)
        let speaker = Speaker(name: "Synthetic", appearance: .init(color: .teal, avatarPNG: owned))
        let model = ShowDocumentModel(show: Show(title: "Portable avatar"), speakers: [speaker])
        let bytes = try JSONEncoder().encode(model)
        let reopened = try JSONDecoder().decode(ShowDocumentModel.self, from: bytes)
        #expect(reopened == model)
        #expect(!String(decoding: bytes, as: UTF8.self).contains(url.lastPathComponent))
        await #expect(throws: SpeakerAvatarImport.Failure.self) {
            try await SpeakerAvatarImport.png(from: Data("not an image".utf8))
        }
    }

    private static func record(key: DeviceAccessKey, url: URL, access: SourceAccessContext,
                               confirmation: WWCore.Confirmation) throws -> DeviceAccessRecord {
        guard case let .success(metadata) = access.io.metadata(at: url) else {
            throw SourceMediaInspector.Failure.notLocalOrAccessible
        }
        return DeviceAccessRecord(showID: key.showID, sourceID: key.sourceID,
            bookmark: try access.io.makeReadOnlyBookmark(for: url), lastKnownPath: url.path,
            recordedIdentity: RecordedIdentity(fingerprint: metadata.fingerprint,
                confirmation: confirmation, recordedAt: Date()), createdAt: Date())
    }

    private static func wave(rate: Int, channels: Int, frames: Int) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        let size = frames * channels * 2
        data.append(contentsOf: "RIFF".utf8); put(UInt32(36 + size))
        data.append(contentsOf: "WAVEfmt ".utf8)
        put(UInt32(16)); put(UInt16(1)); put(UInt16(channels))
        put(UInt32(rate)); put(UInt32(rate * channels * 2)); put(UInt16(channels * 2)); put(UInt16(16))
        data.append(contentsOf: "data".utf8); put(UInt32(size))
        for frame in 0..<frames {
            for channel in 0..<channels { put(Int16((frame + channel) % 2000 - 1000)) }
        }
        return data
    }
}
