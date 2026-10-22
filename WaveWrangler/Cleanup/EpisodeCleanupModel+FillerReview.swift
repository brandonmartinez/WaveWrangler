import Foundation
import WWCore
import WWSpeech

enum FillerTimingEdge { case start, end }

extension EpisodeCleanupModel {
    var fillerReviews: [FillerTimingReview] { episode?.cleanup?.fillerReviews ?? [] }
    var selectedFiller: FillerTimingReview? { fillerReviews.first { $0.id == selectedFillerID } }
    var canReviewFillers: Bool {
        state.canEdit && !isBusy && !isRefreshing && plan?.lanes.isEmpty == false
            && plan?.alignmentRevision != nil && plan?.alignmentRevision == episode?.alignment?.acceptedRevision
    }

    func visibleFillers(for lane: CleanupSpeakerLane) -> [FillerTimingReview] {
        fillerReviews.filter {
            $0.speaker == lane.speaker && cut(for: $0) == nil
                && displayRange(start: $0.bounds.alignedStart, end: $0.bounds.alignedEnd).map {
                    $0.upperBound > windowStart && $0.lowerBound < windowStart + visibleDuration
                } == true && fillerIssue($0) == nil
        }
    }

    /// Inactive history is inspectable, never projected or implicitly rebound to another word/map.
    func fillerIssue(_ review: FillerTimingReview) -> String? {
        guard review.isValid else { return "Invalid review data." }
        guard let lane = plan?.lanes.first(where: { $0.speaker == review.speaker }),
              let identity = identities[lane.primary.sourceID] else {
            return "Source and accepted timing must be verified."
        }
        guard review.alignmentRevision == plan?.alignmentRevision,
              review.alignmentRevision == episode?.alignment?.acceptedRevision,
              review.primary == lane.primary, review.sourceRate == lane.sourceRate,
              review.sourceIdentity == identity,
              episode?.speakerAssignments.contains(where: {
                  $0.speakerID == review.speaker && $0.primary == review.primary && $0.primaryConfirmation == .userConfirmed
              }) == true,
              episode?.source(review.primary.sourceID)?.role == .primary,
              episode?.source(review.primary.sourceID)?.roleConfirmation == .userConfirmed,
              episode?.cleanup?.workingRange.map({ $0.alignmentRevision == review.alignmentRevision }) != false else {
            return "Source, Primary/channel or alignment changed. Original review retained; no automatic rebase."
        }
        if let transcriptID = review.transcriptID {
            if fillerWordIndexGeneration != state.store.modelGeneration {
                fillerWordIndex = Dictionary(uniqueKeysWithValues: (episode?.cleanup?.transcripts ?? []).map {
                    ($0.id, Dictionary(uniqueKeysWithValues: $0.words.map { ($0.id, $0) }))
                })
                fillerWordIndexGeneration = state.store.modelGeneration
            }
            guard let transcript = episode?.cleanup?.transcripts.first(where: { $0.id == transcriptID }),
                  review.matchesOrigin(of: transcript),
                  review.word.map({ fillerWordIndex[transcriptID]?[$0.id] == $0 }) != false else {
                return "Transcript or captured word changed. Original review retained; no automatic reassociation."
            }
        }
        guard review.bounds.alignedStart >= max(lane.start, episode?.cleanup?.workingRange?.tracksIn ?? lane.start),
              review.bounds.alignedEnd <= min(lane.end, episode?.cleanup?.workingRange?.tracksOut ?? lane.end) else {
            return "Outside the current Tracks In / Out range. Original review retained."
        }
        guard let mapped = mappedFillerBounds(review, start: review.bounds.alignedStart, end: review.bounds.alignedEnd),
              mapped == review.bounds,
              let initial = lane.sourceRange(start: review.initialBounds.alignedStart, end: review.initialBounds.alignedEnd),
              initial == review.initialBounds.sourceStartFrame..<review.initialBounds.sourceEndFrame else {
            return "Captured source frames are not supported by the current timing."
        }
        return nil
    }

    func mappedFillerBounds(_ review: FillerTimingReview, start: Double, end: Double) -> FillerTimingBounds? {
        guard start.isFinite, end.isFinite, end > start, abs(start) <= 86_400, abs(end) <= 86_400,
              let lane = plan?.lanes.first(where: { $0.speaker == review.speaker }),
              start >= lane.start, end <= lane.end,
              start >= (review.analyzedRange?.tracksIn ?? -.infinity),
              end <= (review.analyzedRange?.tracksOut ?? .infinity),
              lane.sourceRange(start: min(start, review.initialBounds.alignedStart),
                               end: max(end, review.initialBounds.alignedEnd)) != nil,
              let frames = lane.sourceRange(start: start, end: end) else { return nil }
        return FillerTimingBounds(sourceStartFrame: frames.lowerBound, sourceEndFrame: frames.upperBound,
                                  alignedStart: start, alignedEnd: end)
    }

    func proposeFillers() {
        guard canReviewFillers, let cleanup = episode?.cleanup else { return }
        // Only current witnessed transcripts may introduce new proposals.
        let current = plan?.lanes.compactMap { transcript(for: $0) } ?? []
        var proposed = cleanup
        proposed.transcripts = current
        proposed = proposed.proposingFillers()
        proposed.transcripts = cleanup.transcripts
        guard proposed != cleanup else { return }
        saveFillerCleanup(proposed, action: "Find filler timing candidates")
    }

    func selectFiller(_ id: UUID, reveal: Bool = true, movePlayhead: Bool = true) {
        guard let review = fillerReviews.first(where: { $0.id == id }) else { return }
        stopPlayback()
        listening.selectionToolsPresented = true
        selectedFillerID = id
        selectedManualCutID = nil
        selectedSpeaker = review.speaker
        selectedWord = review.word
        updateFillerDrafts()
        if fillerIssue(review) == nil {
            let start = cutTimeline.editedTime(forAlignedTime: review.bounds.alignedStart)
            let end = cutTimeline.editedTime(forAlignedTime: review.bounds.alignedEnd)
            if movePlayhead { _ = previewSeek(to: start, revealing: false) }
            if reveal, start < windowStart {
                setWindow(start: start, duration: visibleDuration)
            } else if reveal, end > windowStart + visibleDuration {
                setWindow(start: min(start, end - visibleDuration), duration: visibleDuration)
            }
        }
    }

    func zoomToFiller(_ id: UUID) {
        guard canNavigate, let review = fillerReviews.first(where: { $0.id == id }),
              fillerIssue(review) == nil else {
            error = "Select a current filler interval before zooming to it."
            return
        }
        let start = cutTimeline.editedTime(forAlignedTime: review.bounds.alignedStart)
        let end = cutTimeline.editedTime(forAlignedTime: review.bounds.alignedEnd)
        guard let window = AlignmentWaveformProjection.rulerZoom(
            duration: (end - start) * 2, playhead: start + (end - start) / 2,
            magnification: 1, bounds: bounds, maximumDuration: maximumDuration
        ) else {
            error = "The selected filler interval cannot be shown within the available timeline."
            return
        }
        setWindow(start: window.start, duration: window.duration)
    }

    func updateFillerDrafts() {
        fillerStartText = selectedFiller.map { String(format: "%.6f", $0.bounds.alignedStart) } ?? ""
        fillerEndText = selectedFiller.map { String(format: "%.6f", $0.bounds.alignedEnd) } ?? ""
    }

    func setFillerBounds(_ id: UUID, start: Double, end: Double) {
        guard let review = editableFiller(id) else { return }
        guard let bounds = mappedFillerBounds(review, start: start, end: end) else {
            error = "Audible-word start must precede end and stay in the same supported source/timing region and analyzed range."
            return
        }
        changeFiller(id, action: "Adjust filler audible-word timing") {
            $0.humanBounds = bounds
            $0.decision = .reviewed
        }
    }

    func applyFillerText(reviewID: UUID? = nil) {
        guard let id = selectedFillerID, reviewID == nil || reviewID == id,
              let start = Double(fillerStartText), let end = Double(fillerEndText) else {
            error = "Enter finite audible-word start and end in aligned seconds."
            return
        }
        let original = selectedFiller?.bounds
        setFillerBounds(id,
            start: original.map { fillerStartText == String(format: "%.6f", $0.alignedStart) ? $0.alignedStart : start } ?? start,
            end: original.map { fillerEndText == String(format: "%.6f", $0.alignedEnd) ? $0.alignedEnd : end } ?? end)
    }

    func nudgeFiller(_ id: UUID, edge: FillerTimingEdge, seconds: Double) {
        guard let review = editableFiller(id) else { return }
        setFillerBounds(id, start: review.bounds.alignedStart + (edge == .start ? seconds : 0),
                       end: review.bounds.alignedEnd + (edge == .end ? seconds : 0))
    }

    func decideFiller(_ id: UUID, decision: FillerReviewDecision) {
        guard editableFiller(id) != nil else { return }
        changeFiller(id, action: decision == .rejected ? "Reject filler candidate" : "Review filler timing") {
            $0.decision = decision
        }
    }

    func revertFiller(_ id: UUID) {
        guard let review = editableFiller(id), review.detectedBounds != nil else { return }
        changeFiller(id, action: "Revert to detected filler timing") { $0.revertToDetected() }
    }

    func addManualFiller(speaker: SpeakerID, start: Double, end: Double) {
        guard canReviewFillers, let lane = plan?.lanes.first(where: { $0.speaker == speaker }),
              let revision = plan?.alignmentRevision,
              let identity = identities[lane.primary.sourceID],
              start >= lane.start, end <= lane.end,
              let frames = lane.sourceRange(start: start, end: end) else {
            error = "Choose a speaker Primary and a finite audible-word interval inside supported Tracks In / Out."
            return
        }
        let transcript = transcript(for: lane)
        let word = transcript?.words.first { $0.id == selectedWord?.id }
        let bounds = FillerTimingBounds(sourceStartFrame: frames.lowerBound, sourceEndFrame: frames.upperBound,
                                        alignedStart: start, alignedEnd: end)
        let review = FillerTimingReview(origin: .manual, speaker: speaker, primary: lane.primary,
            sourceRate: lane.sourceRate, sourceIdentity: identity, alignmentRevision: revision,
            transcriptID: transcript?.id, word: word, modelRecipe: transcript?.model,
            analyzedRange: transcript?.workingRange, initialBounds: bounds)
        guard review.isValid else { error = "The manual filler interval is invalid."; return }
        if let issue = fillerIssue(review) { error = issue; return }
        var cleanup = episode?.cleanup ?? EpisodeCleanup()
        cleanup.fillerReviews = fillerReviews + [review]
        if saveFillerCleanup(cleanup, action: "Mark missed filler manually") { selectFiller(review.id) }
    }

    func markMissedFiller() {
        if let review = selectedFiller, fillerIssue(review) != nil {
            error = "Select a current waveform or word; historical review timing cannot seed a new manual interval."
            return
        }
        guard let speaker = selectedSpeaker else {
            error = "Select a speaker's waveform or word before marking a missed filler."
            return
        }
        addManualFiller(speaker: speaker,
            start: selectedWord?.alignedStart ?? cutTimeline.alignedTime(forEditedTime: playhead),
            end: selectedWord?.alignedEnd ?? cutTimeline.alignedTime(forEditedTime: playhead + 0.2))
    }

    func fillerAuditionRange(_ review: FillerTimingReview, context: Double) -> ClosedRange<Double>? {
        guard context.isFinite, context >= 0, context <= 2, fillerIssue(review) == nil,
              let lane = plan?.lanes.first(where: { $0.speaker == review.speaker }) else { return nil }
        let a = review.bounds.alignedStart, b = review.bounds.alignedEnd
        var lo = a, hi = b
        // Extend only through connected accepted pieces; never extrapolate across an adaptive gap.
        for region in lane.regions.reversed() where region.alignedStart < lo && region.alignedEnd >= lo {
            let next = max(lane.start, a - context, region.alignedStart)
            if lane.sourceRange(start: next, end: hi) != nil { lo = next }
        }
        for region in lane.regions where region.alignedStart <= hi && region.alignedEnd > hi {
            let next = min(lane.end, b + context, region.alignedEnd)
            if lane.sourceRange(start: lo, end: next) != nil { hi = next }
        }
        return lo...hi
    }

    func auditionFiller(_ id: UUID, context: Double = 0.5) {
        guard let review = editableFiller(id) else { return }
        guard canNavigate, let interval = fillerAuditionRange(review, context: context) else {
            error = "Verify current source access and accepted timing before auditioning."
            return
        }
        guard interval.lowerBound < interval.upperBound - 1 / 48_000 else {
            error = "This audible-word interval is too short to audition alone. Use With context or widen the bounds."
            return
        }
        error = nil
        guard let display = displayRange(start: interval.lowerBound, end: interval.upperBound) else {
            error = "This interval has been cut. Restore the cut to audition the original audio."
            return
        }
        play(interval: display, loop: loopsFillerAudition)
    }

    private func editableFiller(_ id: UUID) -> FillerTimingReview? {
        guard canReviewFillers, let review = fillerReviews.first(where: { $0.id == id }) else {
            error = "Filler timing review is unavailable while the document is read-only, busy or unverified."
            return nil
        }
        if let issue = fillerIssue(review) { error = issue; return nil }
        return review
    }

    private func changeFiller(_ id: UUID, action: String, _ edit: (inout FillerTimingReview) -> Void) {
        guard var cleanup = episode?.cleanup, let index = cleanup.fillerReviews?.firstIndex(where: { $0.id == id }) else { return }
        edit(&cleanup.fillerReviews![index])
        if saveFillerCleanup(cleanup, action: action) {
            selectFiller(id, reveal: false, movePlayhead: false)
            if let review = selectedFiller {
                listening.selection = displayRange(start: review.bounds.alignedStart, end: review.bounds.alignedEnd)
            }
        }
    }

    @discardableResult
    private func saveFillerCleanup(_ cleanup: EpisodeCleanup, action: String) -> Bool {
        stopPlayback()
        isEditingFillerReview = true
        defer { isEditingFillerReview = false }
        guard state.store.apply(action, { document throws(DomainError) in
            try document.settingCleanup(cleanup, in: episodeID)
        }) else {
            error = "Filler timing review could not be saved: \(String(describing: state.store.lastError))."
            return false
        }
        fillerPublicationGeneration = state.store.modelGeneration
        if isLoadingWaveforms || isLoadingOverview {
            cancelWaveforms()
            loadWaveforms()
            if overviewStrokes.isEmpty { loadWaveforms(overview: true) }
        }
        error = nil
        return true
    }
}
