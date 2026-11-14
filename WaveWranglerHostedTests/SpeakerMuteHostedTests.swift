import Foundation
import Testing
import WWCore
import WWPersistence
@testable import WaveWrangler

@MainActor
@Suite("Speaker-only mute regions (synthetic only)", .serialized)
struct SpeakerMuteHostedTests {
    @Test(arguments: [1, 2])
    func sourceProductionAndPreviewMuteOnlyTheSpeakerWithUndoAndRemoval(primaryCount: Int) async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: primaryCount, durationSeconds: 6)
        defer { f.close() }
        f.model.placeGroupsAtSourceTime()
        try await wait { !f.model.isWorking && f.document.verifiedModel == f.document.store.residentModel }
        let store = f.document.store, original = store.residentModel
        let episode = try #require(original.episode(f.model.episodeID))
        let speaker = try #require(episode.speakerAssignments.first?.speakerID)
        let sources = episode.sources.map(\.id)
        let files = try f.files.map { try Data(contentsOf: $0) }
        let undo = try #require(f.document.undoManager)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        let cleanup = EpisodeCleanupModel(state: ShowWindowState(store: store), episodeID: episode.id, runtime: f.runtime)
        cleanup.connectWorkspace(to: f.model)
        defer { cleanup.cancel() }
        await cleanup.refresh()
        let window: Range<Int64> = 24_000..<144_000
        let baseline = try await f.runtime.sourceAuditions(model: original, episode: episode.id,
            sources: sources, outputFrames: window)
        cleanup.listening.select(from: 1, to: 2, within: 0...6)
        cleanup.muteSelection(for: speaker)
        let error = cleanup.error
        try #require(error == nil, "\(error ?? "")")
        let applied = store.residentModel
        let region = try #require(applied.episode(episode.id)?.activeSpeakerMuteRegions.first)
        #expect(region.startFrame == 48_000 && region.endFrame == 96_000)
        #expect(applied.episode(episode.id)?.sources == episode.sources)
        #expect(applied.episode(episode.id)?.alignment == episode.alignment)
        #expect(cleanup.cutTimeline.cuts.removals.isEmpty)
        let source = try await f.runtime.sourceAuditions(model: applied, episode: episode.id,
            sources: sources, outputFrames: window)
        for id in sources {
            let before = try #require(baseline[id]?.samples), after = try #require(source[id]?.samples)
            #expect(after.count == before.count && after.prefix(24_000) == before.prefix(24_000)
                && after.suffix(48_000) == before.suffix(48_000))
            let middle = Array(after[24_000..<72_000])
            if episode.references(to: id).contains(where: { $0.speakerID == speaker }) {
                #expect(middle.allSatisfy { $0 == 0 })
            } else {
                #expect(after == before, "Other speakers retain every sample")
            }
        }
        let raw = try await f.runtime.sourceAuditions(model: applied, episode: episode.id,
            sources: sources, outputFrames: window, applyingCuts: false, timebase: .sourceTime)
        #expect(raw.values.allSatisfy { $0.samples[24_000..<72_000].contains { $0 != 0 } },
            "Untimed source audition is not an accepted-timeline edit")
        let preview = try await f.runtime.cleanupPreview(model: applied, episode: episode.id,
            start: 0.5, duration: 2.5, respectWorkingRange: false)
        for assignment in episode.speakerAssignments {
            let primary = try #require(assignment.primary)
            #expect(preview.channels[assignment.speakerID] == source[primary.sourceID]?.samples)
        }
        let recipe = try await f.runtime.mixerRecipe(model: applied, episode: episode.id, programFrames: window)
        let pcm = try await f.runtime.productionPCM(recipe: recipe, model: applied, frames: window)
        for route in recipe.routes {
            #expect(pcm.channels[route.reference] == source[route.reference.sourceID]?.samples,
                "Production receives the same mute before effects")
        }
        undo.undo()
        #expect(store.residentModel == original)
        undo.redo()
        #expect(store.residentModel == applied)
        try await f.document.save(to: #require(f.document.fileURL), ofType: DocumentTypes.show, for: .saveOperation)
        try await wait { f.document.verifiedModel == store.residentModel }
        let decoded = try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(LocalFileOperations().read(#require(f.document.fileURL)))
        #expect(decoded.payload == applied)
        cleanup.removeSpeakerMute(region.id)
        let restored = try await f.runtime.sourceAuditions(model: store.residentModel, episode: episode.id,
            sources: sources, outputFrames: window)
        for id in sources { #expect(restored[id]?.samples == baseline[id]?.samples) }
        undo.undo()
        #expect(store.residentModel == applied)
        var overlapping = try #require(applied.episode(episode.id)?.cleanup)
        let other = SpeakerMuteRegion(speaker: speaker, alignmentRevision: region.alignmentRevision,
            startFrame: 72_000, endFrame: 120_000)
        overlapping.speakerMuteRegions?.append(other)
        overlapping.manualCuts = [.init(alignmentRevision: region.alignmentRevision, startFrame: 48_000, endFrame: 72_000)]
        try #require(store.apply("Overlapping synthetic edit") { model throws(DomainError) in
            try model.settingCleanup(overlapping, in: episode.id)
        })
        cleanup.removeSpeakerMute(region.id)
        let remaining = try #require(store.residentModel.episode(episode.id))
        #expect(remaining.activeSpeakerMuteRegions == [other])
        let cutWindow = try await f.runtime.sourceAuditions(model: store.residentModel, episode: episode.id,
            sources: sources, outputFrames: 24_000..<120_000)
        for id in sources {
            let samples = try #require(cutWindow[id]?.samples)
            #expect(samples.count == 96_000, "Only the cut removes time, never the mute")
            if episode.references(to: id).contains(where: { $0.speakerID == speaker }) {
                #expect(samples[24_000..<72_000].allSatisfy { $0 == 0 },
                    "The remaining mute follows original frames across the cut seam")
                #expect(samples.prefix(24_000) == baseline[id]?.samples.prefix(24_000))
            }
        }
        #expect(try f.files.map { try Data(contentsOf: $0) } == files)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Synthetic document preparation timed out")
    }
}
