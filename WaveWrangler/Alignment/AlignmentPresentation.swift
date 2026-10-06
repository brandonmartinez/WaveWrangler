import Foundation
import WWAlignPipeline
import WWCore
import WWDecode
import WWTimeMap

struct AlignmentStateCopy: Equatable {
    var heading: String
    var evidence: String
    var remedies: [String]
    var isBlocked = false
    var details: String?
    var basis: String?
    var symbol = "questionmark.circle"
}

enum AlignmentPresentation {
    static let gap = AlignmentStateCopy(
        heading: "Gap — clock restarted",
        evidence: "The recording stopped and restarted here. WaveWrangler never bridges or guesses across a gap; the epoch on each side is timed separately.",
        remedies: ["Go to Epoch Before", "Go to Epoch After"],
        isBlocked: true,
        symbol: "arrow.triangle.branch"
    )

    static let outsideCoverage = AlignmentStateCopy(
        heading: "Outside the mapped range",
        evidence: "This instant is before the first or after the last mapped time for this occurrence. WaveWrangler never guesses beyond what it mapped.",
        remedies: ["Go to Nearest Mapped Time"],
        isBlocked: true,
        symbol: "arrow.up.and.down.and.arrow.left.and.right"
    )

    static func copy(for status: EpochAlignmentStatus, fileName: String? = nil) -> AlignmentStateCopy {
        switch status {
        case .reference:
            return AlignmentStateCopy(
                heading: "Reference",
                evidence: "This is the timeline's reference epoch. Every other epoch is measured against it.",
                remedies: [],
                symbol: "flag.checkered"
            )
        case let .proposed(proposal):
            let measurements = proposal.provenance.measurements
            let details = measurements.map {
                " Evidence: \(proposal.provenance.estimator) residual p95 \(formatMilliseconds($0.acousticResidualP95Milliseconds)) over \($0.windowCount) windows, \(Int(($0.overlapSpanFraction * 100).rounded()))% of the declared overlap."
            } ?? ""
            return AlignmentStateCopy(
                heading: "Proposed — not confirmed",
                evidence: "WaveWrangler found this timing consistent with the audio content, but acoustic delay can look the same as a clock difference. This is a proposal, not a confirmed clock correction.\(details)",
                remedies: ["Accept as Manual…", "Reject", "Edit Numerically…", "Place Anchors…", "Audition"],
                details: proposal.provenance.evidenceScore.map {
                    "Evidence score: \($0), \(proposal.provenance.estimator)'s own scale"
                },
                symbol: "waveform.circle"
            )
        case let .proposedInAcceptedMap(revision):
            return AlignmentStateCopy(
                heading: "Proposed — not confirmed",
                evidence: "WaveWrangler found the timing in map revision \(revision) consistent with the audio content, but acoustic delay can look the same as a clock difference. This is a proposal, not a confirmed clock correction.",
                remedies: ["Accept as Manual…", "Reject", "Edit Numerically…", "Place Anchors…", "Audition"],
                symbol: "waveform.circle"
            )
        case let .manual(basis, revision):
            let basisText: String = switch basis {
            case .numericEntry: "You typed the rate and offset."
            case .anchors: "Fitted from the anchors you placed."
            case .acceptedAcousticProposal: "You reviewed and accepted WaveWrangler's proposal."
            }
            return AlignmentStateCopy(
                heading: "Set by you",
                evidence: "You set this timing yourself. \(basisText) Map revision \(revision).",
                remedies: ["Edit Numerically…", "Place Anchors…", "Audition"],
                basis: basisText,
                symbol: "hand.point.up.braille"
            )
        case let .externalEvidence(kind, revision):
            return AlignmentStateCopy(
                heading: "External evidence",
                evidence: "You supplied outside evidence for this timing: \(externalKind(kind)). Map revision \(revision).",
                remedies: ["Edit Numerically…", "Audition"],
                symbol: "antenna.radiowaves.left.and.right"
            )
        case .disconnected:
            return AlignmentStateCopy(
                heading: "Disconnected — no timing evidence",
                evidence: "WaveWrangler found no usable timing evidence for this epoch (for example, an acoustic delay made the evidence unreliable, or there's no shared content). Set the timing yourself.",
                remedies: ["Edit Numerically…", "Place Anchors…"],
                isBlocked: true,
                symbol: "bolt.slash"
            )
        case let .unsupported(reason, _):
            return AlignmentStateCopy(
                heading: unsupportedHeading(reason),
                evidence: unsupported(reason),
                remedies: ["Edit Numerically…", "Place Anchors…"],
                isBlocked: true,
                symbol: "questionmark.circle"
            )
        case let .clockApprovalRefused(revision):
            return AlignmentStateCopy(
                heading: "Unsupported",
                evidence: "Map revision \(revision) claims clock approval, but this build has no holdout-qualified clock evaluator. Re-time this epoch manually.",
                remedies: ["Edit Numerically…", "Place Anchors…"],
                isBlocked: true,
                symbol: "questionmark.circle"
            )
        case let .sourceBlocked(_, block):
            return blocked(block, fileName: fileName ?? "this source")
        }
    }

    static func rateLabel(_ ppm: Double) -> String {
        "\(formatPPM(ppm)) — positive means this recorder clock runs slow"
    }

    static func offsetLabel(_ milliseconds: Double) -> String {
        "\(formatMilliseconds(milliseconds)) — positive moves this recorder later on the aligned timeline"
    }

    static func timeLabel(sourceSeconds: Double?, groupSeconds: Double?, alignedSeconds: Double?) -> String {
        [
            sourceSeconds.map { "Source \(formatTime($0))" },
            groupSeconds.map { "Group \(formatTime($0))" },
            alignedSeconds.map { "Aligned \(formatTime($0))" },
        ].compactMap { $0 }.joined(separator: " · ")
    }

    static func formatTime(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "−" : ""
        let value = abs(seconds)
        let hours = Int(value / 3600)
        let minutes = Int(value / 60) % 60
        let whole = Int(value) % 60
        let milliseconds = Int((value * 1000).rounded()) % 1000
        return String(format: "%@%02d:%02d:%02d.%03d", sign, hours, minutes, whole, milliseconds)
    }

    private static func blocked(_ block: SourceBlock, fileName: String) -> AlignmentStateCopy {
        switch block {
        case let .cannotDecode(failure):
            AlignmentStateCopy(
                heading: "Can't read this file",
                evidence: decodeFailure(failure, fileName: fileName),
                remedies: [],
                isBlocked: true,
                symbol: "xmark.octagon"
            )
        case let .needsSetup(cause):
            AlignmentStateCopy(
                heading: "Source unavailable",
                evidence: setupCause(cause) + " Resolve this source's availability in Setup before it can be timed.",
                remedies: ["Go to Setup"],
                isBlocked: true,
                symbol: "arrow.right.circle"
            )
        case let .readFailed(failure):
            AlignmentStateCopy(
                heading: "Can't read this file",
                evidence: "WaveWrangler couldn't read “\(fileName)” for alignment (\(brief(failure))). Try again, or resolve it in Setup.",
                remedies: ["Try Again", "Go to Setup"],
                isBlocked: true,
                symbol: "xmark.octagon"
            )
        }
    }

    private static func setupCause(_ cause: SourceBlock.SetupCause) -> String {
        switch cause {
        case let .decode(failure): decodeFailure(failure, fileName: "this source")
        case let .ineligible(reason): "This source is not available for content work (\(String(describing: reason)))."
        }
    }

    private static func decodeFailure(_ failure: DecodeFailure, fileName: String) -> String {
        if failure.isContentDamage {
            return "WaveWrangler started reading “\(fileName)” but it looks damaged or incomplete, so it can't be used for alignment."
        }
        return switch failure {
        case let .unsupported(reason):
            "WaveWrangler can't decode “\(fileName)” for alignment: \(plain(reason))."
        case .notFound: "The original file could not be found."
        case .permissionDenied: "WaveWrangler does not have permission to read the original file."
        case .notMaterialized: "The original is not downloaded on this Mac."
        case .residencyUnknown: "WaveWrangler cannot confirm that the original is local."
        default:
            "WaveWrangler couldn't read “\(fileName)” for alignment (\(brief(failure))). Try again, or resolve it in Setup."
        }
    }

    private static func plain(_ reason: WWDecode.UnsupportedReason) -> String {
        switch reason {
        case .container: "unsupported container"
        case .codec: "unsupported codec"
        case .sampleFormat: "unsupported sample format"
        case .sampleRate: "unsupported sample rate"
        case .channelCount: "unsupported channel count"
        case .encoderDelayUnknown: "the encoder delay is unknown"
        case .unverifiableContainerLength: "can't verify this file's declared length"
        case .variableFramesPerPacket: "variable frames per packet are unsupported"
        }
    }

    private static func brief(_ failure: DecodeFailure) -> String {
        switch failure {
        case .cancelled: "reading was cancelled"
        case .notARegularFile: "the item is not a regular file"
        case .notOpenedReadOnly: "the file could not be opened read-only"
        case .metadataUnavailable: "required metadata is unavailable"
        case .emptyFile: "the file is empty"
        case .readFailed: "an internal read error"
        case .sourceIdentityMismatch: "the file is not the recorded original"
        case .sourceChangedDuringDecode: "the file changed while reading"
        case .sinkFailed: "an internal audio consumer failed"
        default: "an internal read error"
        }
    }

    private static func brief(_ failure: AlignmentWorkFailure) -> String {
        switch failure {
        case let .decode(value): brief(value)
        case .sourceChangedSinceRegistration: "the source changed after it was registered"
        case .sourceFactsMismatch: "the source facts changed"
        case .formatRevisionMismatch: "the decoder format changed"
        default: "an internal read error"
        }
    }

    private static func unsupported(_ reason: WWTimeMap.UnsupportedReason) -> String {
        switch reason {
        case .notAttempted: "WaveWrangler hasn't attempted timing for this epoch yet."
        case .estimatorAbstained: "WaveWrangler's estimator abstained — it couldn't produce a reliable result."
        case .insufficientOverlap: "Not enough shared recording time to estimate timing."
        case .nonlinear: "The drift isn't a simple constant rate, which WaveWrangler doesn't model."
        case .disconnected: "WaveWrangler found no usable timing evidence for this epoch."
        case .acousticOnly: "Only acoustic evidence exists, below the threshold WaveWrangler uses for even a proposal."
        }
    }

    private static func unsupportedHeading(_ reason: WWTimeMap.UnsupportedReason) -> String {
        switch reason {
        case .notAttempted: "Unsupported — not attempted"
        case .estimatorAbstained: "Unsupported — estimator abstained"
        case .insufficientOverlap: "Unsupported — insufficient overlap"
        case .nonlinear: "Unsupported — nonlinear drift"
        case .disconnected: "Disconnected — no timing evidence"
        case .acousticOnly: "Unsupported — acoustic evidence only"
        }
    }

    private static func externalKind(_ kind: ExternalClockEvidence.Kind) -> String {
        switch kind {
        case .sharedTimecodeGenerator: "shared timecode generator evidence"
        case .sharedWordClock: "shared word-clock evidence"
        case .userSuppliedSyncLog: "a supplied sync log"
        }
    }

    private static func formatPPM(_ value: Double) -> String {
        String(format: "%+.3f ppm", value)
    }

    private static func formatMilliseconds(_ value: Double) -> String {
        String(format: "%+.3f ms", value)
    }
}
