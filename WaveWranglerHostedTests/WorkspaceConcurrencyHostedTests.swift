import Foundation
import Testing
import WWCore
@testable import WWSpeech
@testable import WaveWrangler

@MainActor
@Suite("Nonblocking scoped workspace jobs", .serialized)
struct WorkspaceConcurrencyHostedTests {
    private actor WorkerGate {
        var entered = false
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func pause() async {
            entered = true
            if !released {
                await withCheckedContinuation { waiters.append($0) }
            }
        }

        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    @Test func navigationPlaybackAndAppearanceRemainUsableDuringAControlledTranscription() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.model }
        let state = ShowWindowState(store: f.document.store)
        let cleanup = EpisodeCleanupModel(state: state, episodeID: f.model.episodeID, runtime: f.runtime)
        defer { cleanup.cancel() }
        cleanup.saveRange(inValue: 0, outValue: 5)
        await cleanup.refresh()
        try #require(cleanup.plan?.isReady == true)
        let snapshot = f.document.store.model
        let originals = try f.files.map { try Data(contentsOf: $0) }
        let gate = WorkerGate()
        cleanup.isBusy = true
        let job = Task {
            try await f.runtime.transcribeCleanup(model: snapshot, episode: f.model.episodeID,
                modelRevision: "synthetic-controlled-worker", transcribeWindow: { _ in
                    await gate.pause()
                    return PCMTranscript(segments: [PCMSegment(text: "um hello", startSeconds: 1, endSeconds: 1.5)])
                }, progress: { _ in })
        }
        defer { job.cancel(); Task { await gate.release() } }
        for _ in 0..<1_000 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await gate.entered)
        #expect(cleanup.canNavigate && !cleanup.canTranscribe)
        cleanup.seek(to: 2.25)
        cleanup.zoomTimeline(duration: 1)
        #expect(cleanup.playhead == 2.25 && cleanup.windowStart == 1.75)
        let speaker = try #require(cleanup.plan?.lanes.first?.speaker)
        cleanup.listening.playback.setSoloed(true, scope: .speaker(speaker))
        cleanup.play()
        try await wait { cleanup.isPlaying || cleanup.error != nil }
        try #require(cleanup.isPlaying && cleanup.error == nil, "\(cleanup.error ?? cleanup.transportMessage)")
        let applied = state.store.apply("Change appearance during transcription") { model throws(DomainError) in
            try model.settingSpeakerAppearance(.init(color: .teal), for: speaker, in: f.model.episodeID)
        }
        try #require(applied)
        cleanup.modelDidChange()
        #expect(cleanup.isBusy && cleanup.canNavigate && cleanup.isPlaying)
        await gate.release()
        let transcripts = try await job.value
        cleanup.isBusy = false
        #expect(try cleanup.publishTranscripts(transcripts, expecting: snapshot))
        #expect(state.store.model.speakerAppearance(speaker, in: f.model.episodeID)?.color == .teal)
        #expect(cleanup.episode?.cleanup?.transcripts == transcripts)
        #expect(cleanup.listening.playback.soloed == [.speaker(speaker)])
        #expect(try f.files.map { try Data(contentsOf: $0) } == originals)
        let beforeRangeChange = state.store.model
        cleanup.saveRange(inValue: 0.5, outValue: 4)
        let changed = state.store.model
        #expect(try !cleanup.publishTranscripts(transcripts, expecting: beforeRangeChange))
        #expect(state.store.model == changed, "A real job-input change refuses publication rather than overwriting current state.")
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }
}
