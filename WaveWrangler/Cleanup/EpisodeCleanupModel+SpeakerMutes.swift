import Foundation
import WWCore

extension EpisodeCleanupModel {
    var activeSpeakerMuteRegions: [SpeakerMuteRegion] { episode?.activeSpeakerMuteRegions ?? [] }

    var selectedSpeakerMute: SpeakerMuteRegion? {
        guard let selection = listening.selection, selectedManualCut == nil, selectedFiller == nil else { return nil }
        return activeSpeakerMuteRegions.first {
            $0.id == selectedSpeakerMuteID && displayRange(start: $0.alignedStart, end: $0.alignedEnd) == selection
        }
    }

    func canMuteSelection(for speaker: SpeakerID) -> Bool {
        canEditManualCuts && listening.selection != nil && selectedManualCut == nil
            && selectedSpeakerMute == nil && episode?.assignment(for: speaker) != nil
            && workspaceAlignment?.isSourceTimePreview != true
    }

    func muteSelection(for speaker: SpeakerID) {
        guard canMuteSelection(for: speaker), let selection = listening.selection,
              let revision = episode?.alignment?.acceptedRevision, let bounds = originalCutBounds else {
            error = "Select a speaker's aligned audio interval before muting it."
            return
        }
        guard workspaceAlignment?.selectionHasDialogueOnly(selection) != false else {
            error = "A speaker mute cannot include insertion-only or outside-dialogue program time."
            return
        }
        let start = cutTimeline.originalTime(forDisplayTime: selection.lowerBound) ?? .nan
        let end = cutTimeline.originalTime(forExclusiveDisplayEnd: selection.upperBound) ?? .nan
        guard start.isFinite, end.isFinite, start >= bounds.lowerBound, end <= bounds.upperBound,
              abs(start) <= 86_400, abs(end) <= 86_400 else {
            error = "The mute region must stay inside the current aligned audio."
            return
        }
        let region = SpeakerMuteRegion(speaker: speaker, alignmentRevision: revision,
            startFrame: Int64((start * 48_000).rounded()), endFrame: Int64((end * 48_000).rounded()))
        guard region.isValid else {
            error = "A mute region must contain at least one aligned audio frame."
            return
        }
        var cleanup = episode?.cleanup ?? EpisodeCleanup()
        cleanup.speakerMuteRegions = (cleanup.speakerMuteRegions ?? []) + [region]
        guard saveTimelineEdit(cleanup, action: "Mute speaker region") else { return }
        selectSpeakerMute(region.id)
        message = "Region muted for this speaker only. No time was removed. Remove mute or Undo restores the audio."
    }

    func selectSpeakerMute(_ id: UUID) {
        guard let region = activeSpeakerMuteRegions.first(where: { $0.id == id }),
              let range = displayRange(start: region.alignedStart, end: region.alignedEnd) else {
            error = "This mute region is no longer visible at the current accepted alignment."
            return
        }
        selectedManualCutID = nil
        selectedFillerID = nil
        selectedWord = nil
        selectedSpeaker = region.speaker
        selectedSpeakerMuteID = id
        listening.selection = range
        listening.selectionToolsPresented = true
        listening.selectedTranscriptText = nil
    }

    func removeSpeakerMute(_ id: UUID) {
        guard state.canEdit, !isBusy, !isRefreshing, var cleanup = episode?.cleanup,
              cleanup.speakerMuteRegions?.contains(where: { $0.id == id }) == true else {
            error = "The mute region cannot be removed while the document is read-only or busy."
            return
        }
        cleanup.speakerMuteRegions?.removeAll { $0.id == id }
        if cleanup.speakerMuteRegions?.isEmpty == true { cleanup.speakerMuteRegions = nil }
        guard saveTimelineEdit(cleanup, action: "Remove speaker mute") else { return }
        selectedSpeakerMuteID = nil
        message = "Speaker mute removed. Other mute regions and tracks are unchanged."
    }
}
