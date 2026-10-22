import Foundation
import WWAlignPipeline
import WWCore

enum ManualCutAudition: Equatable { case removed, original, join }

struct ManualCutReviewFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

extension EpisodeCleanupModel {
    var manualCuts: [ManualEpisodeCut] { episode?.cleanup?.manualCuts ?? [] }
    var activeManualCuts: [ManualEpisodeCut] { episode?.activeManualCuts ?? [] }
    var cutTimeline: ManualCutTimeline { workspaceCutTimeline }
    var selectedManualCut: ManualEpisodeCut? {
        activeManualCuts.first { $0.id == selectedManualCutID }
    }
    var expandedManualCut: ManualEpisodeCut? {
        activeManualCuts.first { $0.id == listening.expandedManualCutID }
    }
    var manualCutSelection: ClosedRange<Double>? {
        guard let cut = selectedManualCut else { return nil }
        let start = cutTimeline.editedTime(forAlignedTime: cut.alignedStart)
        return start...max(start, cutTimeline.editedTime(forAlignedTime: cut.alignedEnd))
    }

    func zoomToManualCut(_ id: UUID) {
        guard let cut = activeManualCuts.first(where: { $0.id == id }),
              workspaceAlignment != nil || canNavigate,
              workspaceAlignment?.pendingWaveformMove == nil,
              workspaceAlignment?.groupDraftMilliseconds ?? 0 == 0 else {
            error = "Select an active cut and finish any recorder move before zooming to it."
            return
        }
        let start = cutTimeline.editedTime(forAlignedTime: cut.alignedStart)
        let end = cutTimeline.editedTime(forAlignedTime: cut.alignedEnd)
        guard let window = AlignmentWaveformProjection.rulerZoom(
            duration: (cut.alignedEnd - cut.alignedStart) * 2,
            playhead: start + (end - start) / 2, magnification: 1,
            bounds: workspaceAlignment?.waveformViewingBounds ?? bounds,
            maximumDuration: workspaceAlignment?.maximumWaveformDuration ?? maximumDuration
        ) else {
            error = "The selected cut cannot be shown within the available timeline."
            return
        }
        setWindow(start: window.start, duration: window.duration)
    }

    func showManualCut(_ id: UUID, expanded: Bool) {
        guard activeManualCuts.contains(where: { $0.id == id }) else {
            error = "This cut is no longer active at the current accepted alignment."
            return
        }
        stopPlayback()
        selectedManualCutID = id
        listening.selectionToolsPresented = true
        selectedFillerID = nil
        listening.expandedManualCutID = expanded ? id : nil
        synchronizeCutTimeline()
        refreshManualCutSelection()
        if expanded, let range = manualCutSelection,
           range.lowerBound < windowStart || range.upperBound > windowStart + visibleDuration {
            let duration = min(maximumDuration, max(1, (range.upperBound - range.lowerBound) * 2))
            setWindow(start: max(bounds.lowerBound, (range.lowerBound + range.upperBound - duration) / 2),
                      duration: duration)
        }
    }

    func refreshManualCutSelection() {
        if listening.expandedManualCutID != nil, expandedManualCut == nil {
            listening.expandedManualCutID = nil
        }
        if selectedManualCutID == nil { selectedManualCutID = expandedManualCut?.id }
        guard let cut = selectedManualCut else {
            selectedManualCutID = nil
            return
        }
        listening.selection = expandedManualCut?.id == cut.id ? manualCutSelection : nil
    }

    func clearManualCutSelection() {
        if let id = expandedManualCut?.id { showManualCut(id, expanded: false) }
        selectedManualCutID = nil
        listening.selection = nil
        listening.selectedTranscriptText = nil
    }
    var originalCutBounds: ClosedRange<Double>? {
        if let bounds = workspaceAlignment?.manualCutBounds { return bounds }
        let regions = plan?.lanes.flatMap(\.regions) ?? []
        guard let start = regions.map(\.alignedStart).min(), let end = regions.map(\.alignedEnd).max(),
              end > start else { return nil }
        return start...end
    }

    var canEditManualCuts: Bool {
        state.canEdit && !isBusy && !isRefreshing
            && (workspaceAlignment?.canApplyManualCuts ?? canReviewFillers)
    }

    func cut(for review: FillerTimingReview) -> ManualEpisodeCut? {
        activeManualCuts.first { $0.markerID == review.id }
    }

    func displayRange(start: Double, end: Double) -> ClosedRange<Double>? {
        let lo = cutTimeline.editedTime(forAlignedTime: start)
        let hi = cutTimeline.editedTime(forAlignedTime: end)
        return hi > lo ? lo...hi : nil
    }

    var canApplyManualCut: Bool {
        guard selectedManualCut == nil, state.canEdit, !isBusy, !isRefreshing, listening.selection != nil,
              workspaceAlignment?.canApplyManualCuts ?? canReviewFillers else { return false }
        return selectedFiller.map { canReviewFillers && fillerIssue($0) == nil && cut(for: $0) == nil } ?? true
    }

    func applyManualCut() {
        guard canApplyManualCut, let selection = listening.selection,
              let revision = episode?.alignment?.acceptedRevision else {
            error = "Select a current marker or timeline interval with accepted alignment before cutting."
            return
        }
        let start = selectedFiller?.bounds.alignedStart
            ?? cutTimeline.alignedTime(forEditedTime: selection.lowerBound)
        let end = selectedFiller?.bounds.alignedEnd
            ?? cutTimeline.alignedTime(forEditedTime: selection.upperBound)
        let regions = plan?.lanes.flatMap(\.regions) ?? []
        let alignedStart = workspaceAlignment?.manualCutBounds?.lowerBound ?? regions.map(\.alignedStart).min() ?? .infinity
        let alignedEnd = workspaceAlignment?.manualCutBounds?.upperBound ?? regions.map(\.alignedEnd).max() ?? -.infinity
        guard start.isFinite, end.isFinite, abs(start) <= 86_400, abs(end) <= 86_400,
              start >= alignedStart, end <= alignedEnd,
              start >= (episode?.cleanup?.workingRange?.tracksIn ?? -.infinity),
              end <= (episode?.cleanup?.workingRange?.tracksOut ?? .infinity) else {
            error = "The cut must stay inside the current aligned Tracks In / Out range."
            return
        }
        let cut = ManualEpisodeCut(markerID: selectedFillerID, alignmentRevision: revision,
            startFrame: Int64(floor(start * Double(ManualEpisodeCut.frameRate) + 0.5)),
            endFrame: Int64(floor(end * Double(ManualEpisodeCut.frameRate) + 0.5)))
        guard cut.isValid else { error = "A cut must remove at least one aligned audio frame."; return }
        var cleanup = episode?.cleanup ?? EpisodeCleanup()
        cleanup.manualCuts = manualCuts + [cut]
        guard saveManualCuts(cleanup, action: "Cut across aligned tracks") else { return }
        selectedFillerID = nil
        selectedWord = nil
        selectedManualCutID = cut.id
        listening.selectionToolsPresented = true
        listening.selection = nil
        listening.selectedTranscriptText = nil
        message = "Cut applied across every aligned track, including hidden and muted tracks. Undo or Restore cut recovers the original audio."
    }

    func restoreManualCut(_ id: UUID) {
        guard state.canEdit, !isBusy, !isRefreshing,
              var cleanup = episode?.cleanup, cleanup.manualCuts?.contains(where: { $0.id == id }) == true else {
            error = "The selected cut cannot be restored while the document is read-only or busy."
            return
        }
        guard let cut = cleanup.manualCuts?.first(where: { $0.id == id }) else { return }
        cleanup.manualCuts?.removeAll { $0.id == id }
        if cleanup.manualCuts?.isEmpty == true { cleanup.manualCuts = nil }
        guard saveManualCuts(cleanup, action: "Restore cross-track cut") else { return }
        selectedManualCutID = nil
        if let markerID = cut.markerID, let marker = fillerReviews.first(where: { $0.id == markerID }),
           fillerIssue(marker) == nil {
            selectFiller(markerID, reveal: false, movePlayhead: false)
        }
        listening.selection = displayRange(start: cut.alignedStart, end: cut.alignedEnd)
        message = "Cut restored on every aligned track. Originals were never changed."
    }

    @discardableResult
    func adjustManualCut(_ original: ManualEpisodeCut, start: Double, end: Double) -> Bool {
        guard canEditManualCuts, activeManualCuts.contains(original),
              var cleanup = episode?.cleanup, let bounds = originalCutBounds else {
            error = "This cut changed or its alignment is unavailable. Reopen the cut before adjusting it."
            return false
        }
        guard start.isFinite, end.isFinite, abs(start) <= 86_400, abs(end) <= 86_400,
              start >= max(bounds.lowerBound, cleanup.workingRange?.tracksIn ?? -.infinity),
              end <= min(bounds.upperBound, cleanup.workingRange?.tracksOut ?? .infinity) else {
            error = "Cut boundaries must stay inside the current aligned Tracks In / Out range."
            return false
        }
        let updated = ManualEpisodeCut(id: original.id, markerID: original.markerID,
            alignmentRevision: original.alignmentRevision,
            startFrame: Int64(floor(start * Double(ManualEpisodeCut.frameRate) + 0.5)),
            endFrame: Int64(floor(end * Double(ManualEpisodeCut.frameRate) + 0.5)))
        guard updated.isValid else {
            error = "Cut start must precede cut end by at least one aligned audio frame."
            return false
        }
        if let markerID = original.markerID {
            guard var reviews = cleanup.fillerReviews,
                  let index = reviews.firstIndex(where: { $0.id == markerID }),
                  fillerIssue(reviews[index]) == nil,
                  let markerBounds = mappedFillerBounds(reviews[index],
                    start: updated.alignedStart, end: updated.alignedEnd) else {
                error = "These boundaries cannot be restored as current markers in the original source/timing region."
                return false
            }
            reviews[index].humanBounds = markerBounds
            cleanup.fillerReviews = reviews
        }
        cleanup.manualCuts = manualCuts.map { $0.id == original.id ? updated : $0 }
        if updated == original { error = nil; return true }
        guard saveManualCuts(cleanup, action: "Adjust cross-track cut boundaries") else { return false }
        selectedManualCutID = updated.id
        refreshManualCutSelection()
        message = "Cut boundaries adjusted across every aligned track. Undo restores the previous cut."
        return true
    }

    func auditionManualCut(_ id: UUID, mode: ManualCutAudition) {
        guard let cut = activeManualCuts.first(where: { $0.id == id }), let bounds = originalCutBounds else {
            error = "This cut is no longer active at the current accepted alignment."
            return
        }
        let range: ClosedRange<Double>?
        showManualCut(id, expanded: mode != .join)
        switch mode {
        case .removed:
            range = displayRange(start: cut.alignedStart, end: cut.alignedEnd)
        case .original:
            range = displayRange(start: max(bounds.lowerBound, cut.alignedStart - 0.5),
                end: min(bounds.upperBound, cut.alignedEnd + 0.5))
        case .join:
            let seam = cutTimeline.editedTime(forAlignedTime: cut.alignedStart)
            let lo = max(cutTimeline.editedTime(forAlignedTime: bounds.lowerBound), seam - 0.5)
            let hi = min(cutTimeline.editedTime(forAlignedTime: bounds.upperBound), seam + 0.5)
            range = hi > lo ? lo...hi : nil
        }
        guard let range else {
            error = "No retained audio remains around this join. Listen to the removed audio or restore the cut."
            return
        }
        error = nil
        play(interval: range, loop: false)
    }

    func selectManualCut(_ id: UUID) {
        stopPlayback()
        listening.selectionToolsPresented = true
        if let expanded = expandedManualCut, expanded.id != id {
            showManualCut(expanded.id, expanded: false)
        }
        selectedFillerID = nil
        listening.selection = nil
        listening.selectedTranscriptText = nil
        selectedManualCutID = id
        refreshManualCutSelection()
    }

    private func saveManualCuts(_ cleanup: EpisodeCleanup, action: String) -> Bool {
        stopPlayback()
        guard state.store.apply(action, { model throws(DomainError) in
            try model.settingCleanup(cleanup, in: episodeID)
        }) else {
            error = "The cut could not be saved: \(String(describing: state.store.lastError))."
            return false
        }
        synchronizeCutTimeline()
        error = nil
        return true
    }
}
