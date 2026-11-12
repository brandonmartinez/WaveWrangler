import Foundation

/// Validates our MPEG-1 stream and Xing/LAME gapless accounting before system decoding.
enum MP3Integrity {
    static func verify(url: URL, settings: ExportSettings, expectedFrames: Int64, byteCount: Int64) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        func read(_ count: Int) throws -> [UInt8] {
            let bytes = [UInt8](try file.read(upToCount: count) ?? Data())
            guard bytes.count == count else { throw ExportFailure.verification("Truncated MP3 frame") }
            return bytes
        }
        func integer(_ bytes: ArraySlice<UInt8>) -> Int64 {
            bytes.reduce(0) { ($0 << 8) | Int64($1) }
        }
        var start: Int64 = 0
        let prefix = try read(10)
        if Array(prefix.prefix(3)) == Array("ID3".utf8) {
            guard prefix[3] == 4, prefix[5] == 0, prefix[6...9].allSatisfy({ $0 < 128 }) else {
                throw ExportFailure.verification("Invalid export ID3 header")
            }
            start = 10 + prefix[6...9].reduce(0) { ($0 << 7) | Int64($1) }
        }
        try file.seek(toOffset: UInt64(start))
        var position = start
        var frameCount: Int64 = 0
        var declaredFrames: Int64?
        let bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
        while position < byteCount {
            try Task.checkCancellation()
            let header = try read(4)
            let bitrate = bitrates[Int(header[2] >> 4)]
            let rateIndex = Int((header[2] >> 2) & 3)
            guard header[0] == 255, header[1] & 254 == 250, header[1] & 1 == 1,
                  rateIndex < 3, bitrate > 0 else {
                throw ExportFailure.verification("Invalid MPEG-1 Layer III frame header")
            }
            let rate = [44_100, 48_000, 32_000][rateIndex]
            let mono = header[3] >> 6 == 3
            guard rate == settings.sampleRate, mono == (settings.channels == 1) else {
                throw ExportFailure.verification("MP3 frame rate/channels changed")
            }
            if frameCount > 0, case .mp3(.constantBitrate(let requested)) = settings.codec,
               bitrate != requested {
                throw ExportFailure.verification("MP3 frame bitrate does not match CBR settings")
            }
            let length = 144_000 * bitrate / rate + Int((header[2] >> 1) & 1)
            guard position + Int64(length) <= byteCount else {
                throw ExportFailure.verification("Truncated final MP3 frame")
            }
            let body = try read(length - 4)
            if frameCount == 0 {
                let offset = mono ? 17 : 32
                guard body.count >= offset + 156,
                      ["Xing", "Info"].contains(String(bytes: body[offset..<(offset + 4)], encoding: .ascii) ?? ""),
                      integer(body[(offset + 4)..<(offset + 8)]) == 15 else {
                    throw ExportFailure.verification("Missing complete Xing/LAME seek tag")
                }
                let declared = integer(body[(offset + 8)..<(offset + 12)])
                let bytes = integer(body[(offset + 12)..<(offset + 16)])
                guard bytes == byteCount - start else {
                    throw ExportFailure.verification("MP3 byte count does not match finalized seek tag")
                }
                let lameOffset = offset + 120
                guard String(bytes: body[lameOffset..<(lameOffset + 4)], encoding: .ascii) == "LAME" else {
                    throw ExportFailure.verification("Missing LAME gapless data")
                }
                let delay = Int64(body[lameOffset + 21]) << 4 | Int64(body[lameOffset + 22] >> 4)
                let padding = Int64(body[lameOffset + 22] & 15) << 8 | Int64(body[lameOffset + 23])
                guard declared * 1_152 - delay - padding == expectedFrames else {
                    throw ExportFailure.verification("MP3 gapless frame accounting does not match input")
                }
                declaredFrames = declared
            }
            position += Int64(length)
            frameCount += 1
        }
        guard let declaredFrames, frameCount == declaredFrames + 1, position == byteCount else {
            throw ExportFailure.verification("MP3 packet count does not match finalized seek tag")
        }
        try file.close()
    }
}
