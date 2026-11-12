import Foundation

public enum ExportFailure: Error, Sendable, Equatable {
    case invalidSettings(String)
    case invalidMetadata(String)
    case invalidPCM(String)
    case invalidState
    case destination(String)
    case encoder(String)
    case verification(String)
}

public enum ExportPCMEncoding: Int, Sendable, CaseIterable {
    case int16 = 16
    case int24 = 24
    case float32 = 32
}

public enum ExportMP3Mode: Sendable, Equatable {
    case constantBitrate(kbps: Int)
    /// LAME VBR quality: 0 (highest) through 9 (lowest).
    case variableBitrate(quality: Int)
}

public enum ExportCodec: Sendable, Equatable {
    case wave(ExportPCMEncoding)
    case mp3(ExportMP3Mode)
    /// System AAC-LC constrained to constant bitrate; VBR is not qualified.
    case aacLC(bitrate: Int)

    public var fileExtension: String {
        switch self {
        case .wave: "wav"
        case .mp3: "mp3"
        case .aacLC: "m4a"
        }
    }
}

/// PCM must already have this rate/channel count. No implicit resampling, downmix, or normalization.
public struct ExportSettings: Sendable, Equatable {
    public let codec: ExportCodec
    public let sampleRate: Int
    public let channels: Int

    public init(codec: ExportCodec, sampleRate: Int = 48_000, channels: Int = 2) throws {
        guard [44_100, 48_000, 88_200, 96_000].contains(sampleRate),
              channels == 1 || channels == 2 else {
            throw ExportFailure.invalidSettings("Expected 44.1/48/88.2/96 kHz and mono or stereo")
        }
        switch codec {
        case .wave: break
        case .mp3(let mode):
            guard sampleRate <= 48_000 else {
                throw ExportFailure.invalidSettings("MP3 supports 44.1/48 kHz; convert PCM explicitly")
            }
            switch mode {
            case .constantBitrate(let kbps):
                guard [64, 80, 96, 112, 128, 160, 192, 224, 256, 320].contains(kbps) else {
                    throw ExportFailure.invalidSettings("MP3 CBR requires 64/80/96/112/128/160/192/224/256/320 kbps with gapless tags")
                }
            case .variableBitrate(let quality):
                guard (0...9).contains(quality) else {
                    throw ExportFailure.invalidSettings("MP3 VBR quality must be 0...9")
                }
            }
        case .aacLC(let bitrate):
            guard sampleRate <= 48_000 else {
                throw ExportFailure.invalidSettings("Qualified system AAC-LC supports 44.1/48 kHz; convert PCM explicitly")
            }
            guard [64_000, 96_000, 128_000, 160_000, 192_000, 256_000].contains(bitrate) else {
                throw ExportFailure.invalidSettings("AAC-LC bitrate must be 64/96/128/160/192/256 kbps")
            }
        }
        self.codec = codec
        self.sampleRate = sampleRate
        self.channels = channels
    }
}
