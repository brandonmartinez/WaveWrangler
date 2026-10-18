import Foundation
import Testing
@testable import WaveWrangler

@Suite("Transcription progress and measured estimates")
struct CleanupTranscriptionProgressTests {
    @Test func estimatesWaitForCompletedAudioAndNeverInventChunkProgress() {
        let start = Date(timeIntervalSince1970: 100)
        var status = CleanupTranscriptionStatus(startedAt: start)
        #expect(status.estimatedRemaining(at: start) == nil)
        status.record(update(completed: 0), at: start.addingTimeInterval(10))
        #expect(status.progress?.fraction == 0)
        #expect(status.estimatedRemaining(at: start.addingTimeInterval(30)) == nil)
        status.record(update(completed: 28), at: start.addingTimeInterval(30))
        #expect(status.progress?.fraction == 0.28)
        #expect(status.estimatedRemaining(at: start.addingTimeInterval(30)) == 72.0 / 28 * 20)
        status.record(update(completed: 28), at: start.addingTimeInterval(35))
        #expect(status.estimatedRemaining(at: start.addingTimeInterval(35)) == 72.0 / 28 * 20 - 5)
        #expect(status.progress?.fraction == 0.28, "Elapsed inference time never becomes fake recognized audio")
        #expect(status.elapsed(at: start.addingTimeInterval(35)) == 35)
        #expect(status.estimatedRemaining(at: start.addingTimeInterval(200)) == nil,
                "An exhausted estimate is recalculated, not displayed as a false zero seconds remaining")
        status.record(update(completed: 100), at: start.addingTimeInterval(200))
        #expect(status.progress?.fraction == 1)
        #expect(status.estimatedRemaining(at: start.addingTimeInterval(200)) == nil)
    }

    @Test func fractionIsEpisodeWideAndFinalizationIsNotSavedSuccess() {
        let packet = update(completed: 40)
        #expect(packet.speakerCount == 2)
        #expect(packet.fraction == 0.4, "Completing one speaker is not completion of the entire episode")
        let final = update(completed: 100, stage: .verifying)
        #expect(final.fraction == 1)
        #expect(final.heading.hasPrefix("Finalizing"))
        #expect(!final.heading.hasPrefix("Transcribed"))
        #expect(CleanupTranscriptionStatus.time(3661.9) == "1:01:01")
    }

    @Test func aggregatesConcurrentSpeakersWithoutDoubleCountingAndIgnoresLateUIPackets() async throws {
        let sink = ProgressSink()
        let reporter = CleanupTranscriptionReporter(workerLimit: 2) { await sink.record($0) }
        await reporter.report(update(completed: 0, speaker: 1))
        await reporter.report(update(completed: 0, speaker: 2))
        var packets = await sink.packets
        #expect(packets.last?.activeSpeakers.map(\.speakerIndex) == [1, 2])
        #expect(packets.last?.heading.contains("concurrently") == true)
        await reporter.report(update(completed: 28, stage: .completedWindow, speaker: 2))
        await reporter.report(update(completed: 28, stage: .completedWindow, speaker: 2))
        await reporter.report(update(completed: 28, stage: .completedWindow, speaker: 1))
        packets = await sink.packets
        #expect(packets.map(\.completedSeconds) == [0, 0, 28, 28, 56])
        #expect(packets.allSatisfy { $0.workerLimit == 2 && $0.totalSeconds == 100 })
        var status = CleanupTranscriptionStatus(startedAt: .now)
        let last = try #require(packets.last)
        status.record(last)
        let acceptedLatePacket = status.record(packets[2])
        #expect(!acceptedLatePacket)
        #expect(status.progress == last)
        #expect(zip(packets, packets.dropFirst()).allSatisfy { $0.sequence < $1.sequence })
    }

    @Test func initialGlobalQueueWaitDoesNotBecomeAnInferenceSpeedEstimate() {
        let start = Date(timeIntervalSince1970: 100)
        var status = CleanupTranscriptionStatus(startedAt: start)
        status.record(update(completed: 0, stage: .waiting), at: start)
        status.record(update(completed: 0), at: start.addingTimeInterval(100))
        status.record(update(completed: 28), at: start.addingTimeInterval(120))
        #expect(status.estimatedRemaining(at: start.addingTimeInterval(120)) == 72.0 / 28 * 20)
        #expect(status.elapsed(at: start.addingTimeInterval(120)) == 120)
    }

    @Test func streamingChunkCountsStayUnknownUntilTheFinalCore() async throws {
        let sink = ProgressSink()
        let reporter = CleanupTranscriptionReporter(workerLimit: 1) { await sink.record($0) }
        for (index, count, completed) in [(1, 0, 26.5), (2, 0, 53.0), (3, 3, 60.0)] {
            await reporter.report(CleanupTranscriptionProgress(stage: .completedWindow, speaker: "Synthetic",
                speakerIndex: 1, speakerCount: 1, windowIndex: index, windowCount: count,
                alignedStart: 0, alignedEnd: completed, completedSeconds: completed, totalSeconds: 60))
        }
        let packets = await sink.packets
        #expect(packets[0].activeSpeakers.first?.chunkDescription == "1")
        #expect(packets[1].activeSpeakers.first?.chunkDescription == "2")
        #expect(packets[2].activeSpeakers.isEmpty)
        #expect(packets.map(\.completedSeconds) == [26.5, 53, 60])
    }

    private func update(completed: Double,
                        stage: CleanupTranscriptionProgress.Stage = .recognizing,
                        speaker: Int = 1) -> CleanupTranscriptionProgress {
        CleanupTranscriptionProgress(stage: stage, speaker: "Synthetic \(speaker)",
            speakerIndex: speaker, speakerCount: 2, windowIndex: 2, windowCount: 4,
            alignedStart: -2, alignedEnd: 26, completedSeconds: completed, totalSeconds: 100)
    }

    private actor ProgressSink {
        var packets: [CleanupTranscriptionProgress] = []
        func record(_ packet: CleanupTranscriptionProgress) { packets.append(packet) }
    }
}
