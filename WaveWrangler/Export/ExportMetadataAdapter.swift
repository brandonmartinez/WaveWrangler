import Foundation
import WWCore
import WWExport

struct ExportMetadataOmission: Sendable, Hashable {
    let field: String
    let reason: String
}

struct ExportMetadataPreview: Sendable {
    let metadata: ExportMetadata
    let omissions: Set<ExportMetadataOmission>
}

struct EpisodeExportDelivery: Sendable {
    let filename: String
    let settings: ExportSettings
    var overrides = PublicationMetadata()
    var titleOverride: String?
    var albumOverride: String?
    var dither = ExportDither.none
    var confirmedOmissions: Set<ExportMetadataOmission> = []
}

enum ExportMetadataAdapter {
    static func preview(_ resolved: ResolvedPublicationMetadata,
                        delivery: EpisodeExportDelivery) throws -> ExportMetadataPreview {
        let publicValues = delivery.overrides.inheriting(from: resolved.metadata)
        if let message = publicValues.validationMessage { throw ExportFailure.invalidMetadata(message) }
        var omissions: Set<ExportMetadataOmission> = []
        func omit(_ field: String, _ reason: String) {
            omissions.insert(.init(field: field, reason: reason))
        }
        func text(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        for (field, present) in [
            ("publisher", text(publicValues.publisher) != nil), ("language", text(publicValues.language) != nil),
            ("website", text(publicValues.website) != nil), ("explicitContent", publicValues.explicitContent != nil),
            ("season", resolved.season != nil), ("episodeType", resolved.episodeType != nil),
        ] where present {
            omit(field, "This field has no qualified mapping in the selected export format.")
        }
        var metadata = ExportMetadata(title: text(delivery.titleOverride ?? resolved.title),
            artist: text(publicValues.creator), album: text(delivery.albumOverride ?? resolved.album),
            publicDescription: text(publicValues.publicDescription), copyright: text(publicValues.copyright),
            genre: text(publicValues.genre), date: resolved.publicationDate?.description,
            episodeNumber: resolved.episodeNumber)
        if case .wave = delivery.settings.codec {
            if publicValues.artwork?.image != nil { omit("artwork", "WAV INFO does not support embedded artwork.") }
            if metadata.episodeNumber != nil { omit("episodeNumber", "WAV INFO does not support episode numbers.") }
            metadata.episodeNumber = nil
            for (field, key) in [
                ("title", \ExportMetadata.title), ("artist", \.artist), ("album", \.album),
                ("publicDescription", \.publicDescription), ("copyright", \.copyright),
                ("genre", \.genre), ("date", \.date),
            ] {
                if let value = metadata[keyPath: key], !value.unicodeScalars.allSatisfy(\.isASCII) {
                    omit(field, "WAV INFO requires ASCII; this field will be omitted, not transliterated.")
                    metadata[keyPath: key] = nil
                }
            }
        } else if let artwork = publicValues.artwork?.image {
            if artwork.data.count > 8 * 1_024 * 1_024 {
                omit("artwork", "This original artwork exceeds the encoder's 8 MiB limit. Choose smaller export-only artwork or explicitly omit it.")
            } else {
                metadata.artwork = try .init(data: artwork.data,
                    format: artwork.mediaType == "image/png" ? .png : .jpeg)
            }
        }
        return .init(metadata: metadata, omissions: omissions)
    }

    static func delivery(_ resolved: ResolvedPublicationMetadata, selection: EpisodeExportDelivery) throws -> ExportDelivery {
        let preview = try preview(resolved, delivery: selection)
        guard preview.omissions.isSubset(of: selection.confirmedOmissions) else {
            throw ExportFailure.invalidMetadata("Confirm these metadata omissions before exporting: "
                + preview.omissions.subtracting(selection.confirmedOmissions).map(\.field).sorted().joined(separator: ", "))
        }
        return try .init(filename: selection.filename, settings: selection.settings,
                         metadata: preview.metadata, dither: selection.dither)
    }
}
