import Foundation

/// Evidence for the deliberately narrow MPEG-1 Layer III / Info-or-Xing / LAME profile.
/// The gateway validates every audio frame and the LAME music CRC during sequential decoding.
public struct MP3AccountingEvidence: Sendable, Equatable {
    public let sampleRate: Int
    public let channelCount: Int
    public let packetCount: Int64
    public let table: PacketTableFacts
    public let isVariableBitRate: Bool
    package let firstAudioByte: Int64
    package let audioEndByte: Int64
    package let musicCRC: UInt16
}

package struct MP3FrameHeader {
    let sampleRate: Int
    let channelCount: Int
    let byteCount: Int

    init(_ bytes: ArraySlice<UInt8>) throws(DecodeFailure) {
        guard bytes.count >= 4 else { throw .unsupported(.mp3Accounting("incomplete MPEG header")) }
        let b = Array(bytes.prefix(4))
        guard b[0] == 0xff, b[1] == 0xfb else {
            throw .unsupported(.mp3Accounting("requires unprotected MPEG-1 Layer III"))
        }
        let bitRateIndex = Int(b[2] >> 4)
        let rateIndex = Int(b[2] >> 2 & 3)
        guard (1...14).contains(bitRateIndex), rateIndex < 3, b[3] & 3 != 2,
            b[3] >> 6 != 2
        else {
            throw .unsupported(.mp3Accounting("free/reserved bitrate, rate, emphasis or dual-channel mode"))
        }
        sampleRate = [44_100, 48_000, 32_000][rateIndex]
        channelCount = b[3] >> 6 == 3 ? 1 : 2
        let kbps = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320][bitRateIndex]
        byteCount = 144_000 * kbps / sampleRate + Int(b[2] >> 1 & 1)
    }
}

package enum MP3Qualification {
    static func crc(_ bytes: some Sequence<UInt8>, starting: UInt16 = 0) -> UInt16 {
        var result = starting
        for byte in bytes {
            result ^= UInt16(byte)
            for _ in 0..<8 { result = result & 1 == 0 ? result >> 1 : (result >> 1) ^ 0xa001 }
        }
        return result
    }

    static func firstFrame(_ bytes: [UInt8], at offset: Int64) throws(DecodeFailure) -> MP3AccountingEvidence {
        let header = try MP3FrameHeader(bytes[...])
        let xing = header.channelCount == 1 ? 21 : 36
        let lame = xing + 120
        guard bytes.count == header.byteCount, bytes.count >= lame + 36,
            ["Info", "Xing"].contains(String(decoding: bytes[xing..<xing + 4], as: UTF8.self)),
            integer(bytes, xing + 4) == 15,
            String(decoding: bytes[lame..<lame + 4], as: UTF8.self) == "LAME"
        else { throw .unsupported(.encoderDelayUnknown) }
        guard crc(bytes.prefix(lame + 34)) == UInt16(bytes[lame + 34]) << 8 | UInt16(bytes[lame + 35]) else {
            throw .inconsistentStream(.mp3Integrity("LAME tag CRC"))
        }
        let packets = Int64(integer(bytes, xing + 8))
        let declaredBytes = Int64(integer(bytes, xing + 12))
        let delay = Int64(bytes[lame + 21]) << 4 | Int64(bytes[lame + 22] >> 4)
        let padding = Int64(bytes[lame + 22] & 15) << 8 | Int64(bytes[lame + 23])
        let valid = packets * 1152 - delay - padding
        guard packets > 0, declaredBytes > Int64(header.byteCount), valid > 0,
            delay == 576, (576...1727).contains(padding),
            Int64(integer(bytes, lame + 28)) == declaredBytes
        else { throw .unsupported(.mp3Accounting("invalid LAME frame, byte or delay/padding counts")) }
        return MP3AccountingEvidence(
            sampleRate: header.sampleRate, channelCount: header.channelCount, packetCount: packets,
            table: PacketTableFacts(validFrames: valid, primingFrames: delay, remainderFrames: padding),
            isVariableBitRate: bytes[xing] == 0x58,
            firstAudioByte: offset + Int64(header.byteCount), audioEndByte: offset + declaredBytes,
            musicCRC: UInt16(bytes[lame + 32]) << 8 | UInt16(bytes[lame + 33])
        )
    }

    private static func integer(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
