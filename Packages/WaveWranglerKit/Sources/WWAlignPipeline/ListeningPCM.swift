import Foundation

/// App-cache PCM only. A payload is never source authorization or timing authority.
struct ListeningPCM: Sendable, Equatable {
    let firstFrame: Int64
    let sampleRate: Int
    let channels: [[Float]]

    static let magic = Data("WWPCM1\n\0".utf8)
    private static let headerBytes = 32

    enum Failure: Error, Sendable, Equatable, LocalizedError {
        case invalidPayload
        var errorDescription: String? { "The saved aligned-audio PCM has an invalid shape or samples. No substitute audio was used." }
    }

    func encode() throws -> Data {
        guard (8000...192000).contains(sampleRate), (1...32).contains(channels.count),
              let frames = channels.first?.count, frames > 0, frames <= sampleRate * 5,
              !firstFrame.addingReportingOverflow(Int64(frames)).overflow,
              channels.allSatisfy({ $0.count == frames && $0.allSatisfy(\.isFinite) })
        else { throw Failure.invalidPayload }
        var data = Data(capacity: Self.headerBytes + frames * channels.count * 4)
        data.append(Self.magic)
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(channels.count).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(bitPattern: firstFrame).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(frames).littleEndian) { data.append(contentsOf: $0) }
        for channel in channels {
            channel.map { $0.bitPattern.littleEndian }.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count >= headerBytes, data.prefix(magic.count) == magic else { throw Failure.invalidPayload }
        return try data.withUnsafeBytes { bytes in
            let rate = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
            let count = Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
            let first = Int64(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self)))
            let frames = UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 24, as: UInt64.self))
            guard (8000...192000).contains(rate), (1...32).contains(count),
                  frames > 0, frames <= UInt64(rate * 5),
                  !first.addingReportingOverflow(Int64(frames)).overflow,
                  bytes.count == headerBytes + Int(frames) * count * 4 else { throw Failure.invalidPayload }
            let channels = try (0..<count).map { channel in
                try (0..<Int(frames)).map { frame in
                    let offset = headerBytes + (channel * Int(frames) + frame) * 4
                    let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                    guard value.isFinite else { throw Failure.invalidPayload }
                    return value
                }
            }
            return Self(firstFrame: first, sampleRate: rate, channels: channels)
        }
    }
}
