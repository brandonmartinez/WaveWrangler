import Foundation
import WWAlignPipeline
import WWCore
import WWSources

struct AudioAssetWaveform: Sendable {
    let id = UUID()
    let envelope: WaveformEnvelope
    let witness: RawSourceIdentity
    let displayGain: Double
    let channelBins: [[WaveformBin]]
    let channelPeaks: [Float]

    func visibleBins(in range: Range<Double>, channels: [Int]) -> ArraySlice<WaveformBin> {
        let bins = channels.count == 1 ? channelBins[channels[0]] : envelope.bins
        var lo = 0, hi = bins.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if Double(bins[mid].endFrame) <= range.lowerBound { lo = mid + 1 } else { hi = mid }
        }
        let first = lo
        hi = bins.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if Double(bins[mid].firstFrame) < range.upperBound { lo = mid + 1 } else { hi = mid }
        }
        return bins[first..<lo]
    }

    func normalizedGain(channels: [Int]) -> Double {
        let peak = channels.map { channelPeaks[$0] }.max() ?? 0
        return peak > 0 ? 1 / Double(peak) : 1
    }
}

struct QualifiedAudioImport: Sendable {
    let asset: AudioAsset
    let waveform: AudioAssetWaveform

    var observations: SourceObservations {
        .init(durationSeconds: .known(Double(asset.frameCount) / Double(asset.sampleRate)),
              channelCount: .known(asset.channelCount), sampleRate: .known(Double(asset.sampleRate)))
    }
}
