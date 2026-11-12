import Foundation
import WWCore
import WWExport

enum EpisodeExportFormat: String, Codable, CaseIterable, Identifiable {
    case wave, mp3, m4a
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wave: "WAV / PCM"
        case .mp3: "MP3"
        case .m4a: "M4A / AAC"
        }
    }
    var fileExtension: String { self == .wave ? "wav" : rawValue }
}

/// Device-local choices, not part of the portable show schema or publication metadata.
struct EpisodeExportOptions: Codable, Equatable {
    var formats: Set<EpisodeExportFormat> = [.wave]
    var waveBits = 24
    var waveRate = 48_000
    var waveChannels = 2
    var waveDither = false
    var mp3Rate = 44_100
    var mp3Channels = 2
    var mp3VBR = false
    var mp3Bitrate = 192
    var mp3Quality = 2
    var aacRate = 48_000
    var aacChannels = 2
    var aacBitrate = 192
    enum Normalization: String, Codable, CaseIterable { case off, podcast, custom }
    var normalization = Normalization.off
    var targetLUFS = -16.0
    var ceilingDBTP = -1.0

    static let mp3Bitrates = [64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    static let aacBitrates = [64, 96, 128, 160, 192, 256]

    func delivery(_ format: EpisodeExportFormat, baseName: String) throws -> EpisodeExportDelivery {
        guard !baseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              baseName != ".", baseName != "..",
              baseName.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ExportFailure.destination("Enter a nonempty base filename without control characters.")
        }
        let codec: ExportCodec
        let rate: Int
        let channels: Int
        switch format {
        case .wave:
            guard let pcm = ExportPCMEncoding(rawValue: waveBits) else {
                throw ExportFailure.invalidSettings("Choose a supported WAV bit depth.")
            }
            codec = .wave(pcm); rate = waveRate; channels = waveChannels
        case .mp3:
            codec = .mp3(mp3VBR ? .variableBitrate(quality: mp3Quality) : .constantBitrate(kbps: mp3Bitrate))
            rate = mp3Rate; channels = mp3Channels
        case .m4a:
            guard Self.aacBitrates.contains(aacBitrate) else {
                throw ExportFailure.invalidSettings("Choose a supported AAC bitrate.")
            }
            codec = .aacLC(bitrate: aacBitrate * 1_000); rate = aacRate; channels = aacChannels
        }
        var value = EpisodeExportDelivery(filename: "\(baseName).\(format.fileExtension)",
            settings: try ExportSettings(codec: codec, sampleRate: rate, channels: channels))
        value.dither = format == .wave && waveBits != 32 && waveDither ? .tpdf : .none
        switch normalization {
        case .off: value.normalization = .off
        case .podcast: value.normalization = .podcast
        case .custom: value.normalization = .custom(targetLUFS: targetLUFS, ceilingDBTP: ceilingDBTP)
        }
        // Validate independently of metadata, which still needs its explicit omission preview.
        _ = try ExportDelivery(filename: value.filename, settings: value.settings,
                               dither: value.dither, normalization: value.normalization)
        return value
    }

    func validate() throws {
        guard !formats.isEmpty else { throw ExportFailure.invalidSettings("Select at least one format.") }
        for format in EpisodeExportFormat.allCases {
            _ = try delivery(format, baseName: "Validation")
        }
    }

    static func suggestedBaseName(_ title: String) -> String {
        let parts = title.components(separatedBy: CharacterSet(charactersIn: "/:\0\n\r"))
        let value = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = String(value.prefix(60))
        return safe.isEmpty || safe == "." || safe == ".." ? "Episode" : safe
    }
}

struct EpisodeExportPreferenceStore {
    let defaults: UserDefaults
    let show: ShowID
    private var key: String { "WWEpisodeExport.v1.\(show)" }

    private struct Saved: Codable {
        let options: EpisodeExportOptions
        let directoryBookmark: Data
    }

    func load() throws -> (options: EpisodeExportOptions, directory: URL)? {
        guard let data = defaults.data(forKey: key) else { return nil }
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        try saved.options.validate()
        var stale = false
        let url = try URL(resolvingBookmarkData: saved.directoryBookmark,
                          options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        guard !stale, url.isFileURL else {
            throw ExportFailure.destination("The saved export folder needs authorization. Choose the folder again.")
        }
        return (saved.options, url)
    }

    /// Only complete, cleanup-clean attempts may replace the last successful choices.
    func save(_ options: EpisodeExportOptions, directory: URL, succeeded: Bool) throws {
        guard succeeded else { return }
        try options.validate()
        let scoped = directory.startAccessingSecurityScopedResource()
        defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
        let bookmark = try directory.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(try JSONEncoder().encode(Saved(options: options, directoryBookmark: bookmark)), forKey: key)
    }
}

enum EpisodeExportWording {
    static func error(_ error: Error) -> String {
        switch error {
        case ExportFailure.invalidSettings(let text), ExportFailure.invalidMetadata(let text),
             ExportFailure.invalidPCM(let text), ExportFailure.destination(let text),
             ExportFailure.encoder(let text), ExportFailure.verification(let text): return text
        case ExportFailure.invalidState: return "Another export is active for this show. Wait for it to finish."
        default: return error.localizedDescription
        }
    }

    static func phase(_ phase: ExportJobPhase) -> String {
        switch phase {
        case .idle: "Ready"
        case .preflight: "Checking export"
        case .rendering: "Rendering episode"
        case .measuring(let delivery): "Measuring output \(delivery + 1)"
        case .converting(let delivery): "Encoding output \(delivery + 1)"
        case .verifying(let delivery): "Verifying output \(delivery + 1)"
        case .correcting(let delivery, let attempt): "Correcting output \(delivery + 1), pass \(attempt)"
        case .publishing: "Publishing verified files"
        case .cleaning: "Cleaning temporary files"
        case .completed: "Export completed"
        case .canceled: "Export canceled"
        case .failed: "Export stopped"
        }
    }

    static func resultTitle(_ result: ExportJobResult) -> String {
        if result.succeeded { return "Export completed" }
        if result.problem?.kind == .canceled { return "Export canceled" }
        return result.published.isEmpty ? "Export stopped" : "Export partially completed"
    }

    static func loudness(_ report: ExportLoudnessReport) -> String {
        let level = report.measurement.integratedLUFS.map { String(format: "%.1f LUFS", $0) }
            ?? "Integrated loudness not measurable"
        let peak = report.measurement.truePeakDBTP.map { String(format: "%.1f dBTP estimated", $0) }
            ?? "No measurable peak (digital silence)"
        let status: String
        switch report.targetStatus {
        case .off: status = "Normalization off; levels preserved"
        case .achieved: status = "Loudness target achieved"
        case .peakLimited: status = "Target limited by peak ceiling"
        case .boostLimited: status = "Target limited by +24 dB boost cap"
        case .unmeasurable: status = "Loudness target unmeasurable (silent, gated, or too short)"
        case .targetMissed: status = "Delivered loudness missed the requested target"
        }
        let requested = report.requestedTargetLUFS.map { String(format: "; requested %.1f LUFS", $0) } ?? ""
        let ceiling = report.ceilingDBTP.map { String(format: "; ceiling %.1f dBTP", $0) } ?? ""
        return "\(level); \(peak)\n\(status)\(requested)\(ceiling)"
            + String(format: "; gain %+.2f dB; correction %.2f dB (%d passes)",
                     report.appliedGainDB, report.correctiveAttenuationDB, report.correctionPasses)
    }
}
