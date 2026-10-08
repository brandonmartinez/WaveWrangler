import Foundation
import Testing
import WWCore

@Suite("Provisional edit-map authority")
struct EditMapAuthorityTests {
    let episodeID = EpisodeID()
    let sourceID = SourceID()

    func model() -> ShowDocumentModel {
        let source = SourceRecord(id: sourceID, displayNameHint: "synthetic")
        let alignment = EpisodeAlignment(
            maps: [TimeMapVersion(
                revision: 2, inputs: TimeMapInputs(sources: [TimeMapSourceInput(sourceID: sourceID)]),
                map: .object([:])
            )],
            acceptedRevision: 2
        )
        return ShowDocumentModel(
            show: Show(title: "Synthetic"),
            episodes: [Episode(id: episodeID, title: "Episode", sources: [source], alignment: alignment)]
        )
    }

    @MainActor
    @Suite("Mutation-serial edit-map publication")
    struct EditMapPublicationTests {
        let fixture = EditMapAuthorityTests()

        @Test func absentLiveProofRefusesWithoutPublishingHistory() throws {
            let model = fixture.model()
            let snapshot = EditMapSnapshot(model: model, serial: 7)
            #expect(throws: EditMapPublicationError.proofUnavailable) {
                try EditMapPublication.recording(
                    fixture.version(), in: fixture.episodeID, actionName: "Shorten",
                    expecting: snapshot, current: { snapshot }, prove: nil
                )
            }
            #expect(model.editMaps.isEmpty && model.history.entries.isEmpty)
        }

        @Test func sourceAccessAndProtectedDecisionMustStillHoldAtPublication() throws {
            let model = fixture.model()
            let snapshot = EditMapSnapshot(model: model, serial: 7)
            var accessOn = false
            var protectedDecisionValid = true
            let proof: EditMapPublication.Proof = { live, episode, version in
                #expect(live.show.id == model.show.id && episode == fixture.episodeID && version.sourceIDs == [fixture.sourceID])
                guard accessOn, protectedDecisionValid else { throw EditMapPublicationError.proofUnavailable }
            }
            #expect(throws: EditMapPublicationError.proofUnavailable) {
                try EditMapPublication.recording(
                    fixture.version(), in: fixture.episodeID, actionName: "Shorten",
                    expecting: snapshot, current: { snapshot }, prove: proof
                )
            }
            accessOn = true
            let active = try EditMapPublication.recording(
                fixture.version(), in: fixture.episodeID, actionName: "Shorten",
                expecting: snapshot, current: { snapshot }, prove: proof
            )
            #expect(active.editMaps(for: fixture.episodeID)?.selectedRevision == 1)
            #expect(active.history.undoActionName == "Shorten")
            var live = EditMapSnapshot(model: active, serial: 8)
            #expect(try EditMapPublication.selected(
                in: fixture.episodeID, current: { live }, prove: proof
            ).revision == 1)
            protectedDecisionValid = false
            #expect(throws: EditMapPublicationError.proofUnavailable) {
                try EditMapPublication.selected(in: fixture.episodeID, current: { live }, prove: proof)
            }
            live = EditMapSnapshot(model: model, serial: 9) // Undo/restored state is not a cached permission.
            #expect(throws: EditMapPublicationError.proofUnavailable) {
                try EditMapPublication.recording(
                    fixture.version(), in: fixture.episodeID, actionName: "Redo",
                    expecting: live, current: { live }, prove: proof
                )
            }
        }

        @Test func concurrentEditOrUndoABANeverPublishes() throws {
            let model = fixture.model()
            let prior = EditMapSnapshot(model: model, serial: 3)
            var live = prior
            let proof: EditMapPublication.Proof = { _, _, _ in
                // Another window edited then undid the show; its value equals the prior snapshot.
                live = EditMapSnapshot(model: model, serial: 5)
            }
            #expect(throws: EditMapPublicationError.superseded) {
                try EditMapPublication.recording(
                    fixture.version(), in: fixture.episodeID, actionName: "Stale",
                    expecting: prior, current: { live }, prove: proof
                )
            }
            #expect(model.history.entries.isEmpty)
            #expect(throws: EditMapPublicationError.superseded) {
                try EditMapPublication.recording(
                    fixture.version(), in: fixture.episodeID, actionName: "Stale",
                    expecting: prior, current: { live }, prove: nil
                )
            }
        }

        @Test func reselectingAfterRestoreRequiresFreshProof() throws {
            let model = try fixture.model().recordingEditMap(
                fixture.version(), in: fixture.episodeID, actionName: "Shorten"
            )
            let snapshot = EditMapSnapshot(model: model, serial: 4)
            #expect(throws: EditMapPublicationError.proofUnavailable) {
                try EditMapPublication.selecting(
                    1, in: fixture.episodeID, expecting: snapshot, current: { snapshot }, prove: nil
                )
            }
            let refreshed = try EditMapPublication.selecting(
                1, in: fixture.episodeID, expecting: snapshot, current: { snapshot },
                prove: { _, _, _ in }
            )
            #expect(refreshed.editMaps(for: fixture.episodeID)?.selectedRevision == 1)
            #expect(refreshed.history.undoActionName == "Select Edit Map")
        }

        @Test func undoRedoRestoresValueButNeverRestoresProof() throws {
            let untouched = fixture.model()
            let selected = try untouched.recordingEditMap(
                fixture.version(), in: fixture.episodeID, actionName: "Shorten"
            )
            let current = EditMapSnapshot(model: untouched, serial: 10)
            let refused = EditMapPublication.revalidated(
                selected, replacing: untouched, current: { current }, prove: nil
            )
            #expect(refused.refusal == .proofUnavailable)
            #expect(refused.model.editMaps(for: fixture.episodeID)?.selectedRevision == nil)
            #expect(refused.model.editMaps(for: fixture.episodeID)?.versions == selected.editMaps(for: fixture.episodeID)?.versions)
            #expect(refused.model.history.undoActionName == "Invalidate Edit Map")

            var accessOn = true
            var checks = 0
            let proof: EditMapPublication.Proof = { _, _, _ in
                checks += 1
                guard accessOn else { throw EditMapPublicationError.proofUnavailable }
            }
            let restored = EditMapPublication.revalidated(
                selected, replacing: untouched, current: { current }, prove: proof
            )
            #expect(restored.refusal == nil && restored.model == selected)
            accessOn = false
            let revoked = EditMapPublication.revalidated(
                selected, replacing: untouched, current: { current }, prove: proof
            )
            #expect(revoked.refusal == .proofUnavailable && checks == 2)
            #expect(revoked.model.editMaps(for: fixture.episodeID)?.selectedRevision == nil)
        }
    }

    func version(_ revision: Int = 1, decision: UUID = UUID()) -> EditMapVersion {
        EditMapVersion(
            revision: revision, alignmentRevision: 2, sourceIDs: [sourceID],
            removals: [EditRemoval(startFrame: 100, endFrame: 200, decisionID: decision)]
        )
    }

    @Test func publishesMapSelectionAndNamedHistoryInOneValue() throws {
        let before = model()
        let after = try before.recordingEditMap(version(), in: episodeID, actionName: "Shorten reviewed pause")
        #expect(before.editMaps.isEmpty && before.history.entries.isEmpty)
        #expect(after.editMaps(for: episodeID)?.selectedRevision == 1)
        #expect(after.editMaps(for: episodeID)?.versions.count == 1)
        #expect(after.history.undoActionName == "Shorten reviewed pause")
        #expect(after.validationIssues().isEmpty)
        let second = try after.recordingEditMap(version(2), in: episodeID, actionName: "Adjust pause")
        #expect(second.editMaps(for: episodeID)?.selectedRevision == 2)
        #expect(second.history.entries.count == 2)
        #expect(second.history.undoActionName == "Adjust pause")
        #expect(throws: EditMapPublicationError.revisionAlreadyUsed) {
            try second.recordingEditMap(version(2), in: episodeID, actionName: "Process twice")
        }
        #expect(second.editMaps(for: episodeID)?.versions.count == 2)
    }

    @Test func refusesMissingOrStaleAlignmentAndSourcesWithoutPartialHistory() throws {
        let before = model()
        var stale = version()
        stale.alignmentRevision = 1
        #expect(throws: EditMapPublicationError.alignmentChanged) {
            try before.recordingEditMap(stale, in: episodeID, actionName: "Stale")
        }
        stale = version()
        stale.sourceIDs = [SourceID()]
        #expect(throws: EditMapPublicationError.sourcesChanged) {
            try before.recordingEditMap(stale, in: episodeID, actionName: "Wrong source")
        }
        #expect(before.editMaps.isEmpty && before.history.entries.isEmpty)
    }

    @Test func overlappingSpansAndReusedDecisionsRefuse() throws {
        var invalid = version()
        invalid.removals.append(EditRemoval(startFrame: 150, endFrame: 250, decisionID: UUID()))
        #expect(throws: EditMapPublicationError.invalidMap) {
            try model().recordingEditMap(invalid, in: episodeID, actionName: "Overlap")
        }
        invalid.removals[1] = EditRemoval(
            startFrame: 250, endFrame: 300, decisionID: invalid.removals[0].decisionID
        )
        #expect(throws: EditMapPublicationError.invalidMap) {
            try model().recordingEditMap(invalid, in: episodeID, actionName: "Duplicate decision")
        }
    }

    @Test func sourceOrAlignmentChangeInvalidatesOnlyTheSelectionAtomically() throws {
        let before = try model().recordingEditMap(version(), in: episodeID, actionName: "Shorten")
        var changed = before
        changed.episodes[0].sources[0].role = .backup
        let invalidated = changed.invalidatingChangedEditMaps(from: before)
        #expect(invalidated.editMaps(for: episodeID)?.selectedRevision == nil)
        #expect(invalidated.editMaps(for: episodeID)?.versions == before.editMaps(for: episodeID)?.versions)
        #expect(invalidated.history.undoActionName == "Invalidate Edit Map")
        #expect(before.editMaps(for: episodeID)?.selectedRevision == 1)
        #expect(invalidated.validationIssues().isEmpty)
        // A pure selection is not a permission grant; the document store requires a fresh proof.
        #expect(try invalidated.selectingEditMap(1, in: episodeID, actionName: "Restore")
            .editMaps(for: episodeID)?.selectedRevision == 1)
        var aligned = before
        aligned.episodes[0].alignment?.acceptedRevision = nil
        #expect(aligned.invalidatingChangedEditMaps(from: before).editMaps(for: episodeID)?.selectedRevision == nil)
    }

    @Test func removingEpisodeRemovesItsEditAuthority() throws {
        let before = try model().recordingEditMap(version(), in: episodeID, actionName: "Shorten")
        let removed = try before.removingEpisode(episodeID)
        #expect(removed.editMaps.isEmpty)
        #expect(removed.validationIssues().isEmpty)
    }
}
