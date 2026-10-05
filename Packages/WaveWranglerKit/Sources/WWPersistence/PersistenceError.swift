import Foundation
import WWCore

/// Why a canonical document could not be read or written. Every case refuses; none silently repairs.
public enum PersistenceError: Error, Sendable, Equatable {
    case malformed(String)
    case formatMismatch(expected: String, found: String)
    /// The file was written by a newer WaveWrangler. It must not be edited, saved or downsaved.
    case unknownNewerSchema(found: Int, supported: Int)
    case unsupportedOlderSchema(found: Int, minimum: Int)
    case invalidRevision(Int)
    case checksumMismatch
    /// The payload contains fields this version does not model; opening would silently drop them on save.
    case unrecognizedContent
    case invalidPayload([ValidationIssue])
    case encodingFailed(String)
}

extension PersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformed:
            "The document is damaged or is not a WaveWrangler document."
        case .formatMismatch:
            "The document is not the expected kind of WaveWrangler document."
        case let .unknownNewerSchema(found, supported):
            "This document was saved by a newer version of WaveWrangler (format \(found); this version supports \(supported))."
        case let .unsupportedOlderSchema(found, _):
            "This document uses an older format (\(found)) that this version cannot open."
        case .invalidRevision, .checksumMismatch:
            "The document failed its integrity check and was not opened."
        case .invalidPayload:
            "The document contains inconsistent data and was not opened."
        case .unrecognizedContent:
            "The document contains information this version of WaveWrangler does not understand."
        case .encodingFailed:
            "The document could not be prepared for saving."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unknownNewerSchema:
            "Open it with the newer version of WaveWrangler. This version will not edit or save it, so no newer work is lost."
        case .unrecognizedContent:
            "It was not opened so that information is not lost. Try a newer version of WaveWrangler."
        case .malformed, .formatMismatch, .invalidRevision, .checksumMismatch, .invalidPayload:
            "The file was left unchanged. Try a previous version or a backup copy of the document."
        case .unsupportedOlderSchema:
            "The file was left unchanged."
        case .encodingFailed:
            "Your changes are still open. Try saving again."
        }
    }

    public var failureReason: String? {
        switch self {
        case let .malformed(detail): detail
        case let .formatMismatch(expected, found): "Expected \(expected), found \(found)."
        case let .invalidRevision(revision): "Invalid revision \(revision)."
        case .checksumMismatch: "Checksum mismatch."
        case let .invalidPayload(issues): issues.map(\.description).joined(separator: "\n")
        case let .encodingFailed(detail): detail
        case .unknownNewerSchema, .unsupportedOlderSchema, .unrecognizedContent: nil
        }
    }
}
