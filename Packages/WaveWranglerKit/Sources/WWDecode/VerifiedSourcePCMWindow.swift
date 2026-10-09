import Foundation
import WWCore

/// The verified content of a single selected *channel* at source rate. The source ID was supplied
/// by the caller; this is evidence of the read-only descriptor and decode, NOT of its canonical
/// assignment, occurrence, map, publication, user consent, or right to run inference.
package struct VerifiedSourcePCMWindow: Sendable {
    package let interpretation: FormatInterpretation
    package let channel: Int
    package let sourceFrames: Range<Int64>
    package let samples: [Float]

    fileprivate init(
        interpretation: FormatInterpretation, channel: Int,
        sourceFrames: Range<Int64>, samples: [Float]
    ) {
        self.interpretation = interpretation
        self.channel = channel
        self.sourceFrames = sourceFrames
        self.samples = samples
    }
}

package enum VerifiedPCMWindowFailure: Error, Sendable, Equatable {
    case invalidRequest
    case invalidPCM
}

extension SourceDecoder {
    /// Package-internal content primitive, not a speech authorization entry point. It uses the same
    /// read-only source gateway and consumes the *entire* stream so even a short tail after the
    /// requested window refuses before a result escapes. This currently admits only native 16 kHz;
    /// no resampling, clock map or source-to-occurrence assignment is inferred.
    @concurrent
    package func readVerifiedPCMWindow(
        _ url: URL, source: SourceID, channel: Int, startingAt start: Int64
    ) async throws -> VerifiedSourcePCMWindow {
        let (end, overflow) = start.addingReportingOverflow(32_000)
        guard !overflow, start >= 0, channel >= 0 else {
            throw VerifiedPCMWindowFailure.invalidRequest
        }
        return try await withDecodingCursor(url, source: source) { cursor in
            let interpretation = cursor.interpretation
            guard interpretation.formatInterpretationVersion == FormatInterpretation.currentVersion,
                  interpretation.envelopeVersion == DecodeEnvelope.version,
                  interpretation.sourceSampleRate == 16_000,
                  interpretation.output.sampleRate == 16_000,
                  interpretation.output.channelCount == interpretation.channelCount,
                  interpretation.origin.sourceSampleRate == 16_000,
                  interpretation.origin.sourceFrameOfFirstDecodedFrame == 0,
                  interpretation.origin.decodedFrameCount == interpretation.frames.validFrames,
                  interpretation.frames.validFrames <= 16_000 * 60 * 10,
                  end <= interpretation.frames.validFrames,
                  channel < interpretation.channelCount
            else { throw VerifiedPCMWindowFailure.invalidRequest }

            var samples: [Float] = []
            samples.reserveCapacity(32_000)
            var next: Int64 = 0
            while let chunk = try await cursor.next() {
                let (chunkEnd, overrun) = next.addingReportingOverflow(Int64(chunk.frameCount))
                guard !overrun, chunk.frameCount > 0,
                      chunk.firstSourceFrame == next,
                      chunk.channelCount == interpretation.channelCount,
                      chunkEnd <= interpretation.frames.validFrames
                else { throw VerifiedPCMWindowFailure.invalidPCM }
                let low = max(next, start)
                let high = min(chunkEnd, end)
                if low < high {
                    let channelSamples = chunk.channel(channel)
                    let offset = Int(low - next)
                    let selected = channelSamples.dropFirst(offset).prefix(Int(high - low))
                    guard selected.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else {
                        throw VerifiedPCMWindowFailure.invalidPCM
                    }
                    samples.append(contentsOf: selected)
                }
                next = chunkEnd
            }
            guard next == interpretation.frames.validFrames, samples.count == 32_000 else {
                throw VerifiedPCMWindowFailure.invalidPCM
            }
            return VerifiedSourcePCMWindow(
                interpretation: interpretation, channel: channel,
                sourceFrames: start..<end, samples: samples
            )
        }
    }
}
