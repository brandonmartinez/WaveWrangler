import AppKit
import Foundation
import Testing
import WWCore
import WWMix
import WWPersistence
import WWSources
@testable import WaveWrangler

@MainActor
@Suite("Manual per-speaker input gain (synthetic only)", .serialized)
struct AutoInputGainHostedTests {
    @Test func waveformReadsAndGainFollowTheSelectedStereoChannel() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ww-stereo-gain-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let rate = 8_000, frames = rate * 2
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); put(UInt32(36 + frames * 4))
        data.append(contentsOf: "WAVEfmt ".utf8); put(UInt32(16)); put(UInt16(1)); put(UInt16(2))
        put(UInt32(rate)); put(UInt32(rate * 4)); put(UInt16(4)); put(UInt16(16))
        data.append(contentsOf: "data".utf8); put(UInt32(frames * 4))
        for frame in 0..<frames {
            let value = sin(2 * .pi * 1000 * Double(frame) / Double(rate))
            for amplitude in [0.03, 0.2] { put(Int16((amplitude * value * 32767).rounded())) }
        }
        try data.write(to: file)
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(
            cleanupPrimaries: 1, durationSeconds: 2, sourceFiles: [file, file])
        defer { f.close() }
        let store = f.document.store
        let episode = try #require(store.model.episode(f.model.episodeID))
        let primary = try #require(episode.speakerAssignments.first?.primary)
        try #require(store.apply("Select Channel", { model throws(DomainError) in
            try model.settingStatedChannel(1, forSource: primary.sourceID, in: episode.id)
        }))
        try #require(store.setRecordingInputGain(12, reference: primary, in: episode.id))
        try #require(store.setRecordingInputGain(-6,
            reference: .init(sourceID: primary.sourceID, statedChannel: 1), in: episode.id))
        for overview in [false, true] {
            let load = try await f.runtime.waveformTracks(model: store.model, episode: episode.id,
                startSeconds: 0, durationSeconds: 1, overview: overview, onlySources: [primary.sourceID])
            let track = try #require(load.tracks.first)
            #expect(track.decodedChannel == 1)
            let peak = track.envelope.bins.map { max(abs($0.minimum), abs($0.maximum)) }.max() ?? 0
            #expect(peak > 0.19 && peak < 0.201)
            let gain = f.model.waveformInputGain(for: track)
            #expect(abs(gain - pow(10, -6.0 / 20)) < 0.000001)
            let aggregate = AlignmentWaveformTrack(group: track.group, epoch: track.epoch,
                name: track.name, groupName: track.groupName, envelope: track.envelope)
            let aggregateGain = f.model.waveformInputGain(for: aggregate)
            #expect(aggregateGain == 1, "An aggregate stereo envelope must not inherit either channel's gain")
        }
        #expect(try Data(contentsOf: f.files[0]) == data)
    }

    private func waitForAnalysis(_ controller: AutoInputGainController) async throws {
        let deadline = Date().addingTimeInterval(30)
        while controller.active != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(controller.active == nil, "Auto Input Gain did not finish")
    }

    @Test func oneSpeakerIsAdjustedWithIndependentUndoAndVerifiedSave() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 2, durationSeconds: 4)
        defer { f.close() }
        let store = f.document.store
        let episode = try #require(store.model.episode(f.model.episodeID))
        let assignment = try #require(episode.speakerAssignments.first)
        let primary = try #require(assignment.primary)
        let key = AutoInputGainController.Key(episode: episode.id, speaker: assignment.speakerID)
        let originalBytes = try f.files.map { try Data(contentsOf: $0) }
        // An inaccessible second Primary must not block or participate in this explicit run.
        let access = FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json"))
        try await access.removeRecord(for: .init(showID: store.model.show.id, sourceID: f.target))
        let undo = try #require(f.document.undoManager)
        undo.groupsByEvent = false
        try #require(store.setRecordingInputGain(6, reference: primary, in: episode.id))
        let before = store.model
        let controller = store.autoInputGain
        controller.start(key, targetDBFS: -24, runtime: f.runtime)
        try await waitForAnalysis(controller)
        let result = try #require(controller.results[key], "\(controller.messages[key] ?? "No result")")
        let gain = store.model.episode(episode.id)?.mix?.inputGainDB(for: primary.sourceID, channel: 0)
        #expect(gain == result.gainDB)
        #expect(abs(result.activeRMSDBFS + result.gainDB + 24) < 0.001)
        let inputGains = store.model.episode(episode.id)?.mix?.inputGains ?? []
        #expect(inputGains.count == 1 && inputGains[0].source == primary.sourceID)
        let applied = store.model
        #expect(undo.undoActionName == "Auto Input Gain")
        undo.undo()
        let undone = store.model
        #expect(undone == before)
        undo.redo()
        let redone = store.model
        #expect(redone == applied)
        try await MixerHostedTests().save(f.document)
        let verified = f.document.verifiedModel
        #expect(verified == applied)
        #expect(try f.files.map { try Data(contentsOf: $0) } == originalBytes)
    }

    @Test func cancellationAndAnEditFollowedByUndoNeverApplyAStaleResult() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1, durationSeconds: 4)
        defer { f.close() }
        let store = f.document.store
        let episode = try #require(store.model.episode(f.model.episodeID))
        let key = AutoInputGainController.Key(episode: episode.id,
            speaker: try #require(episode.speakerAssignments.first?.speakerID))
        let before = store.model
        let undo = try #require(f.document.undoManager)
        undo.groupsByEvent = false
        let controller = store.autoInputGain
        controller.start(key, targetDBFS: -20, runtime: f.runtime)
        controller.cancel(key)
        try await waitForAnalysis(controller)
        let canceledModel = store.model
        #expect(controller.results[key] == nil && canceledModel == before)
        #expect(controller.messages[key]?.contains("canceled") == true)

        controller.start(key, targetDBFS: -20, runtime: f.runtime)
        try #require(store.apply("Rename Episode", { model throws(DomainError) in
            try model.renamingEpisode(episode.id, to: "Changed during analysis")
        }))
        undo.undo()
        let undone = store.model
        #expect(undone == before)
        try await waitForAnalysis(controller)
        let staleModel = store.model
        #expect(controller.results[key] == nil && staleModel == before)
        #expect(controller.messages[key]?.contains("changed during analysis") == true)
    }

    @Test func revocationAtTheEndOfTheScanRefusesTheResultAndUnconfirmedChannelsCannotStart() async throws {
        let f = try await AlignmentWaveformRetentionHostedTests().fixture(cleanupPrimaries: 1, durationSeconds: 4)
        defer { f.close() }
        let store = f.document.store
        let before = store.model
        let episode = try #require(before.episode(f.model.episodeID))
        let assignment = try #require(episode.speakerAssignments.first)
        let primary = try #require(assignment.primary)
        let access = FileDeviceAccessStore(fileURL: f.folder.appendingPathComponent("access.json"))
        await #expect(throws: (any Error).self) {
            try await f.runtime.analyzeInputGain(
                model: before, episode: episode.id, speaker: assignment.speakerID, targetDBFS: -20,
                validateSelection: {}, progress: { value in
                    if value >= 1 {
                        try await access.removeRecord(for: .init(showID: before.show.id, sourceID: primary.sourceID))
                    }
                })
        }
        let afterRevocation = store.model
        #expect(afterRevocation == before)
        try #require(store.apply("Clear Channel", { model throws(DomainError) in
            try model.settingStatedChannel(nil, forSource: primary.sourceID, in: episode.id)
        }))
        let key = AutoInputGainController.Key(episode: episode.id, speaker: assignment.speakerID)
        store.autoInputGain.start(key, targetDBFS: -20, runtime: f.runtime)
        #expect(store.autoInputGain.active == nil && store.autoInputGain.results[key] == nil)
        #expect(store.autoInputGain.messages[key]?.contains("confirm") == true)
    }
}
