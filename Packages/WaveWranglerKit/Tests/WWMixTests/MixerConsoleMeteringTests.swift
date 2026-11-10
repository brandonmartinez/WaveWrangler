import Foundation
import Testing
import WWCore
@testable import WWMix

@Suite("Playback-clock console meters")
struct MixerConsoleMeteringTests {
    private func output(_ samples: [Float], at frame: Int64 = 0, speaker: SpeakerID? = nil,
                        track: AudioTrackID? = nil) -> MixerPCMOutput {
        .init(firstFrame: frame, channels: [samples, samples],
            speakerMeters: speaker.map { [$0: MixerMeter(samples)] } ?? [:],
            audioTrackMeters: track.map { [$0: [MixerMeter(samples), MixerMeter(samples)]] } ?? [:])
    }

    @Test func dBScaleAndConsoleTaperAreInvertibleAndBounded() {
        #expect(MixerConsoleScale.decibels(0) == -.infinity)
        #expect(MixerConsoleScale.decibels(1) == 0)
        #expect(abs(MixerConsoleScale.decibels(0.5) + 6.0206) < 0.0001)
        #expect(MixerConsoleScale.meterPosition(-60) == 0)
        #expect(MixerConsoleScale.meterPosition(0) == 1)
        #expect(MixerConsoleScale.meterPosition(6) == 1)
        #expect(MixerConsoleScale.faderPosition(0) == 0.6)
        for db in stride(from: -96.0, through: 24, by: 0.5) {
            #expect(abs(MixerConsoleScale.faderDecibels(MixerConsoleScale.faderPosition(db)) - db) < 0.000_001)
        }
    }

    @Test func shortPeaksSurviveRefreshIntervalsButNeverAppearAheadOfPlayback() throws {
        let speaker = SpeakerID(), track = AudioTrackID()
        var meter = MixerConsoleMetering()
        meter.append(output([1.25] + .init(repeating: 0, count: 479), speaker: speaker, track: track))
        meter.append(output(.init(repeating: 0, count: 480), at: 480, speaker: speaker, track: track))
        #expect(meter.read(through: 479).levels.isEmpty)
        let heard = meter.read(through: 960)
        for bus in [MixerBusAddress.master, .speaker(speaker), .audioTrack(track)] {
            let level = try #require(heard.levels[bus]?.first)
            #expect(level.clipped)
            #expect(abs(level.heldPeakDB - 20 * log10(1.25)) < 0.000_001)
            #expect(abs(level.rmsDB - 20 * log10(1.25 / sqrt(960))) < 0.0001)
        }
    }

    @Test func rmsUsesSampleEnergyNotAnAverageOfBlockRms() throws {
        var meter = MixerConsoleMetering()
        meter.append(output(.init(repeating: 1, count: 480)))
        meter.append(output(.init(repeating: 0, count: 1440), at: 480))
        let level = try #require(meter.read(through: 1920).levels[.master]?.first)
        #expect(abs(level.rmsDB - 20 * log10(0.5)) < 0.0001)
        let expired = try #require(meter.read(through: 19_200).levels[.master]?.first)
        #expect(expired.rmsDB == -.infinity)
        #expect(expired.heldPeakDB == 0)
        #expect(expired.peakDB < level.peakDB)
    }

    @Test func clippingThresholdResetAndNewPlaybackAreTransient() throws {
        var meter = MixerConsoleMetering()
        meter.append(output([1]))
        #expect(meter.read(through: 1).levels[.master]?.first?.clipped == false)
        meter.append(output([1.01], at: 1))
        #expect(meter.read(through: 2).levels[.master]?.first?.clipped == true)
        meter.resetPeaks(for: .master)
        let reset = try #require(meter.read(through: 2).levels[.master]?.first)
        #expect(!reset.clipped && reset.heldPeakDB == -.infinity)
        meter = MixerConsoleMetering()
        #expect(meter.read(through: 0).levels.isEmpty)
    }

    @Test func stalledDisplaysHaveBoundedDeliveryWithoutLosingPeakOrEnergy() throws {
        var meter = MixerConsoleMetering()
        let blocks = 256, size = 480
        for index in 0..<blocks {
            meter.append(output(.init(repeating: index == 0 ? 2 : 0, count: size), at: Int64(index * size)))
        }
        #expect(meter.pendingPacketCount == MixerConsoleMetering.maximumPendingPackets)
        #expect(meter.read(through: 0).levels.isEmpty)
        let end = meter.read(through: Int64(blocks * size))
        let level = try #require(end.levels[.master]?.first)
        #expect(level.clipped)
        #expect(abs(level.heldPeakDB - 20 * log10(2)) < 0.0001)
        #expect(level.rmsDB == -.infinity)
        #expect(meter.pendingPacketCount == 0)
    }
}
