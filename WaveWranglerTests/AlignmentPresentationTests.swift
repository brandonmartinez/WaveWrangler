import Foundation
import Testing
import WWAlignPipeline
import WWCore
import WWDecode
import WWTimeMap

@Suite("Alignment presentation")
struct AlignmentPresentationTests {
    @Test func anAcceptedFileCorrectionDoesNotReportMissingRecordingTiming() {
        let group = AlignmentStateCopy(
            heading: "Timing not set — not attempted", evidence: "No recorder timing was attempted.",
            remedies: ["Edit Numerically…"], isBlocked: true)
        let correction = SourceTimingCorrection(
            source: SourceID(), group: RecorderGroupID(), epoch: RecordingEpochID(), reference: SourceID(),
            sourceRate: 8000, sourceFrames: 160_000, channelCount: 1,
            analysisDigest: String(repeating: "a", count: 64), processing: PitchPreservingAudio.identifier,
            segments: [SourceTimingSegment(sourceStart: 0, sourceEnd: 20, alignedStart: 5, rateRatio: 1)])
        let copy = AlignmentPresentation.recordingTimingState(groupState: group, correction: correction)
        #expect(copy.heading == "Adaptive file timing accepted · pitch preserved")
        #expect(!copy.isBlocked && copy.evidence.contains("playback and comparison"))
        #expect(copy.evidence.contains("Recorder-group timing is separate"))
        #expect(copy.details?.contains(group.heading) == true)
        #expect(AlignmentPresentation.recordingTimingState(groupState: group, correction: nil) == group)
        var invalid = correction
        invalid.version = 99
        #expect(AlignmentPresentation.recordingTimingState(groupState: group, correction: invalid) == group)
    }

    @Test func acceptanceFailureExplainsTheCurrentTimingAndRecoveryWithoutAnOpaqueErrorCode() {
        let error = AlignmentAcceptanceError.staleSnapshot
        let message = AlignmentPresentation.errorDescription(error)
        #expect(message.contains("no longer matches the current timing"))
        #expect(message.contains("Refresh audio"))
        #expect(!message.contains("WWAlignPipeline") && !message.contains("error 17"))
        let detail = "The speaker channel changed. Run Align Tracks again."
        #expect(AlignmentPresentation.errorDescription(AlignmentAcceptanceError.invalidMap(detail)).contains(detail))
    }

    @Test func missingSpeakerChannelsAreSetupRequirementsNotInternalEncodingErrors() {
        let detail = "Choose the speaker's channel for Teams.aiff (2 channels) in Recordings & Speakers."
        let copy = AlignmentPresentation.copy(for: .unsupported(.notAttempted, .analysisFailed(.setupRequired(detail))))
        #expect(copy.heading == "Alignment needs setup" && copy.evidence == detail)
        #expect(copy.remedies.contains("Recordings & Speakers…"))
        #expect(!copy.evidence.contains("encoding("))
    }

    @Test func varyingDelayDoesNotClaimPhysicalRecorderDrift() {
        let copy = AlignmentPresentation.copy(for: .unsupported(.nonlinear, .analysisPending))
        #expect(copy.heading == "Unsupported — no single offset/rate")
        #expect(copy.evidence.contains("adaptive timing"))
        #expect(copy.evidence.contains("without claiming recorder-clock drift"))
    }

    @Test func adaptiveConsentSeparatesSupportedPlaybackFromUnverifiedGapEstimates() {
        let supported = AlignmentPresentation.adaptiveAcceptanceWarning(includeEstimated: false)
        #expect(supported.contains("independently measured"))
        #expect(supported.contains("anchor-guided acoustic matches"))
        #expect(supported.contains("verified quiet-only transitions"))
        #expect(supported.contains("Unmatched intervals will be silent"))
        #expect(!supported.contains("gaps will play"))
        let estimated = AlignmentPresentation.adaptiveAcceptanceWarning(includeEstimated: true)
        #expect(estimated.contains("ESTIMATED timing"))
        #expect(estimated.contains("no acoustic confirmation"))
        #expect(estimated.contains("misaligned speech"))
        #expect(estimated.contains("All source audio will be retained"))
        #expect(estimated.contains("End timing is extrapolated"))
        #expect(!estimated.contains("remain silent"))
        for warning in [supported, estimated] {
            #expect(warning.contains("All channels"))
            #expect(warning.contains("originals stay unchanged"))
            #expect(warning.contains("fixed reference is not moved"))
            #expect(warning.contains("saved and undoable"))
        }
    }

    @Test func selectingANextReferenceDoesNotLabelItAsTheCurrentReference() {
        let current = RecorderGroup(name: "Current recorder")
        var next = RecorderGroup(name: "Next recorder")
        next.preferredAlignmentReference = true
        let episode = Episode(title: "References", recorderGroups: [current, next])
        let selection = TimingReferenceSelection(episode: episode, currentGroup: current.id)
        #expect(selection.currentGroup == current.id && selection.nextGroup == next.id)
        #expect(selection.status(for: current.id) == "Current timing reference")
        #expect(selection.status(for: next.id) == "Next alignment reference")
        #expect(selection.changesReference && !selection.canSelect(next.id) && selection.canSelect(current.id))
        #expect(selection.detail.contains("Current reference: Current recorder. Next alignment: Next recorder."))
        #expect(selection.detail.contains("stay unchanged until acceptance"))
    }

    @Test func anAcceptedReferenceRemainsTheDefaultUntilAnotherRecorderIsSelected() {
        let current = RecorderGroup(name: "Current recorder")
        let other = RecorderGroup(name: "Other recorder")
        let episode = Episode(title: "References", recorderGroups: [current, other])
        let selection = TimingReferenceSelection(episode: episode, currentGroup: current.id)
        #expect(selection.nextGroup == current.id && !selection.changesReference)
        #expect(selection.status(for: current.id) == "Timing reference")
        #expect(selection.status(for: other.id) == nil && selection.canSelect(other.id))
        #expect(!selection.canSelect(current.id))
    }

    @Test func aFirstSelectionAndUnavailableTimingAreNotPresentedAsAcceptedTiming() {
        var next = RecorderGroup(name: "Selected recorder")
        next.preferredAlignmentReference = true
        let episode = Episode(title: "References", recorderGroups: [next])
        let selection = TimingReferenceSelection(episode: episode)
        #expect(selection.currentGroup == nil && selection.nextGroup == next.id)
        #expect(selection.status(for: next.id) == "Next alignment reference")
        let unreadable = TimingReferenceSelection(episode: episode, error: "Saved timing is unreadable.")
        #expect(unreadable.detail == "Saved timing is unreadable." && !unreadable.canSelect(RecorderGroupID()))
        let missing = TimingReferenceSelection.read(model: nil, episodeID: episode.id)
        #expect(missing.error != nil && !missing.canSelect(next.id))
    }

    @Test func recordingSegmentWordingPreservesGapRemediesAndEvidence() {
        let reference = AlignmentPresentation.copy(for: .reference)
        let unresolved = AlignmentPresentation.copy(for: .unsupported(.notAttempted, .analysisPending))
        let disconnected = AlignmentPresentation.copy(for: .disconnected(.analysisPending))
        for copy in [reference, unresolved, disconnected, AlignmentPresentation.gap] {
            #expect(copy.evidence.contains("recording segment"))
            #expect(!copy.evidence.localizedCaseInsensitiveContains("epoch"))
        }
        #expect(AlignmentPresentation.gap.remedies == [
            "Go to Recording Segment Before", "Go to Recording Segment After",
        ])
    }

    @Test func wholeTrackIndexingIsNotPresentedAsContinuousFineVerification() {
        let copy = AlignmentPresentation.automaticMethod(fingerprintSeconds: [4500, 4400])
        #expect(copy.contains("both complete speaker channels"))
        #expect(copy.contains("01:15:00.000"))
        #expect(copy.contains("No initial anchor is required"))
        #expect(!copy.contains("every frame"))
        #expect(!AlignmentPresentation.automaticMethod(fingerprintSeconds: nil).contains("Indexed"))
    }

    @Test func automaticEvidenceSeparatesMeasuredDelaysFromAnAcceptedFit() {
        let proposed = AlignmentPresentation.automaticEvidence(
            usable: 15, total: 16, attempts: 48, rejected: 1, start: 40, end: 4400, hasProposal: true,
            statuses: [String](repeating: "eligible", count: 45) + ["weak", "sharedSilence", "inconsistentMethods"]
        )
        #expect(proposed.contains("15/16 regions agree"))
        #expect(proposed.contains("48 fresh window attempts, 1 isolated outlier excluded"))
        #expect(proposed.contains("00:00:40.000"))
        #expect(proposed.contains("45 passed local checks"))
        #expect(proposed.contains("1 shared silence"))
        #expect(proposed.contains("1 weak"))
        #expect(proposed.contains("1 methods disagree"))
        let refused = AlignmentPresentation.automaticEvidence(
            usable: 16, total: 16, attempts: 48, rejected: 0, start: 40, end: 4400, hasProposal: false
        )
        #expect(refused.contains("regions supplied usable delays"))
        #expect(!refused.contains("regions agree"))
        #expect(!refused.localizedCaseInsensitiveContains("clock approved"))
    }

    @Test func analysisCompensationIsNotPresentedAsAcceptedClockOrPolarityCorrection() {
        let copy = AlignmentPresentation.automaticMethod(fingerprintSeconds: [4500, 4400], refinementRatePPM: -145.25)
        #expect(copy.contains("-145.2 ppm analysis-only"))
        #expect(copy.contains("coarse search estimate, not accepted timing"))
        #expect(copy.contains("polarity-aware"))
        let evidence = AlignmentPresentation.automaticEvidence(
            usable: 14, total: 16, attempts: 144, rejected: 0, start: 0, end: 4400, hasProposal: true,
            reversedRegions: 14
        )
        #expect(evidence.contains("14 usable regions matched opposite polarity"))
        #expect(evidence.contains("recordings were not inverted"))
    }

    @Test func wordingCatalogUsesEvidenceNotProbability() throws {
        let segment = try AffineClockSegment(
            groupClockStart: .zero,
            groupClockEnd: .one,
            rateRatio: .one,
            alignedOffset: .zero
        )
        let proposal = ProposalRecord(
            segment: segment,
            ppm: 0,
            offsetAtCenterSeconds: 0,
            acousticResidualP95Milliseconds: 1,
            acousticResidualMaxMilliseconds: 2,
            provenance: try AcousticConsistencyProposal(estimator: "Synthetic estimator")
        )
        let copy = AlignmentPresentation.copy(for: .proposed(proposal))
        #expect(copy.heading == "Proposed — not confirmed")
        #expect(copy.evidence.contains("This is a proposal, not a confirmed clock correction."))
        #expect(!copy.evidence.localizedCaseInsensitiveContains("probability"))
        #expect(!copy.evidence.contains("%"))
    }

    @Test func manualBasisSentencesAreExact() {
        let numeric = AlignmentPresentation.copy(for: .manual(.numericEntry, revision: 2))
        let anchors = AlignmentPresentation.copy(for: .manual(.anchors, revision: 3))
        let accepted = AlignmentPresentation.copy(for: .manual(.acceptedAcousticProposal, revision: 4))
        #expect(numeric.heading == "Set by you")
        #expect(numeric.evidence.contains("You typed the rate and offset."))
        #expect(anchors.evidence.contains("Fitted from the anchors you placed."))
        #expect(accepted.evidence.contains("You reviewed and accepted WaveWrangler's proposal."))
    }

    @Test func signConventionsAndCoordinateLabelsAreExplicit() {
        #expect(AlignmentPresentation.rateLabel(12).contains("positive means this recorder clock runs slow"))
        #expect(AlignmentPresentation.offsetLabel(25).contains("positive moves this recorder later"))
        #expect(
            AlignmentPresentation.timeLabel(sourceSeconds: 1, groupSeconds: 2, alignedSeconds: 3)
                == "Source 00:00:01.000 · Group 00:00:02.000 · Aligned 00:00:03.000"
        )
    }

    @Test func everyDecodeFailureIsFullyBlocking() {
        let failures: [DecodeFailure] = [
            .canceled, .notFound, .permissionDenied, .notARegularFile, .notOpenedReadOnly,
            .notMaterialized, .residencyUnknown, .metadataUnavailable(nil), .emptyFile,
            .unreadableContainer(status: -1), .unsupported(.channelCount(99)), .missingAudioData,
            .truncated(declaredBytes: 10, availableBytes: 2),
            .incompleteContent(expectedFrames: 10, decodedFrames: 2),
            .inconsistentStream(.invalidDeclaredCount("x")), .decodeFailed(status: -1, atStreamFrame: 0),
            .readFailed(errno: 5), .sourceIdentityMismatch, .sourceChangedDuringDecode, .sinkFailed("x"),
        ]
        for failure in failures {
            let isUnsupported: Bool
            if case .unsupported = failure { isUnsupported = true } else { isUnsupported = false }
            let block: SourceBlock = switch failure {
            case .notFound, .permissionDenied, .notMaterialized, .residencyUnknown:
                .needsSetup(.decode(failure))
            default:
                failure.isContentDamage || isUnsupported ? .cannotDecode(failure) : .readFailed(.decode(failure))
            }
            let copy = AlignmentPresentation.copy(
                for: .sourceBlocked(SourceID(), block), fileName: "synthetic.wav"
            )
            #expect(copy.isBlocked)
            #expect(copy.heading == "Can't read this file" || copy.heading == "Source unavailable")
        }
    }

    @Test func gapAndOutsideCoverageNeverGuessTimes() {
        #expect(AlignmentPresentation.gap.heading == "Gap — clock restarted")
        #expect(AlignmentPresentation.gap.evidence.contains("never bridges or guesses"))
        #expect(AlignmentPresentation.gap.symbol == "arrow.triangle.branch")
        #expect(AlignmentPresentation.outsideCoverage.heading == "Outside the mapped range")
        #expect(AlignmentPresentation.outsideCoverage.evidence.contains("never guesses beyond"))
        #expect(AlignmentPresentation.outsideCoverage.symbol == "arrow.up.and.down.and.arrow.left.and.right")
    }

    @Test func blockedDecodeWordingNamesTheSourceAndRemedy() {
        let unsupported = AlignmentPresentation.copy(
            for: .sourceBlocked(SourceID(), .cannotDecode(.unsupported(.sampleRate(12_345)))),
            fileName: "synthetic.wav"
        )
        #expect(unsupported.evidence == "WaveWrangler can't decode “synthetic.wav” for alignment: unsupported sample rate.")
        #expect(unsupported.remedies.isEmpty)

        let unavailable = AlignmentPresentation.copy(
            for: .sourceBlocked(SourceID(), .needsSetup(.decode(.notFound))),
            fileName: "missing.wav"
        )
        #expect(unavailable.evidence.contains("Resolve this source's availability in Setup before it can be timed."))
        #expect(unavailable.remedies == ["Go to Setup"])
    }

    @Test func viewModelRowsProjectGroupsEpochsSourcesAndUnsupportedState() {
        let epoch = RecordingEpoch(label: "Take 2")
        let group = RecorderGroup(name: "Remote recorder", epochs: [epoch])
        let source = SourceRecord(
            displayNameHint: "synthetic.wav",
            placement: SourcePlacement(recorderGroupID: group.id, epochID: epoch.id)
        )
        let episode = Episode(
            title: "Synthetic", number: 1,
            recorderGroups: [group], sources: [source]
        )
        let model = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [episode])
        let rows = AlignmentRowsProjection.makeRows(model: model, episodeID: episode.id, states: [])
        #expect(rows.count == 1)
        #expect(rows.first?.groupName == "Remote recorder")
        #expect(rows.first?.epochLabel == "Take 2")
        #expect(rows.first?.sourceNames == "synthetic.wav")
        #expect(rows.first?.state.heading == "Timing not set — not attempted")
    }

    @MainActor
    @Test func replacementUndoRegistrationRepeatsTheApplyCallback() {
        final class Probe {
            var value = 0
        }
        let probe = Probe()
        let undoManager = UndoManager()
        var applied: [Int] = []

        func replace(with value: Int) {
            let previous = probe.value
            probe.value = value
            AppUndoRegistration.register(
                with: undoManager,
                target: probe,
                actionName: "Edit Alignment"
            ) { _ in
                replace(with: previous)
            }
            applied.append(value)
        }

        replace(with: 1)
        #expect(probe.value == 1)
        undoManager.undo()
        #expect(probe.value == 0)
        undoManager.redo()
        #expect(probe.value == 1)
        #expect(applied == [1, 0, 1])
    }

    @Test func editorDefaultsPreserveExistingCorrectionsAndAnchorPairs() {
        let row = AlignmentRow(
            groupID: RecorderGroupID(),
            epochID: RecordingEpochID(),
            groupName: "Remote",
            epochLabel: "Take",
            sourceNames: "synthetic.wav",
            state: AlignmentPresentation.copy(for: .unsupported(.notAttempted, .analysisPending)),
            ratePPM: 12.04,
            offsetMilliseconds: 84.2
        )
        let numeric = AlignmentEditorDefaults.numeric(row: row)
        #expect(numeric.ratePPM == 12.04)
        #expect(numeric.offsetMilliseconds == 84.2)
        let existing = [
            AlignmentAnchorRow(id: 0, sourceSeconds: 1, groupSeconds: 0, alignedSeconds: 3),
            AlignmentAnchorRow(id: 1, sourceSeconds: 4, groupSeconds: 3, alignedSeconds: 6),
            AlignmentAnchorRow(id: 2, sourceSeconds: 7, groupSeconds: 6, alignedSeconds: 9),
        ]
        #expect(AlignmentEditorDefaults.anchors(existing: existing, map: nil, row: row) == [
            AlignmentAnchor(sourceSeconds: 1, alignedSeconds: 3),
            AlignmentAnchor(sourceSeconds: 4, alignedSeconds: 6),
            AlignmentAnchor(sourceSeconds: 7, alignedSeconds: 9),
        ])
    }

    @Test func auditionBoundsRejectOverflowMemoryAndUnboundedSeekMutations() throws {
        #expect(throws: AlignmentAuditionRequestError.invalidStart) {
            _ = try AlignmentAuditionRequest.frameRange(
                startSeconds: .infinity,
                durationSeconds: 1,
                sampleRate: 48_000,
                availableFrames: 48_000
            )
        }
        #expect(throws: AlignmentAuditionRequestError.durationTooLong(maximumSeconds: 30)) {
            _ = try AlignmentAuditionRequest.frameRange(
                startSeconds: 0,
                durationSeconds: 30.001,
                sampleRate: 48_000,
                availableFrames: 48_000 * 60
            )
        }
        #expect(throws: AlignmentAuditionRequestError.seekTooDistant(maximumSeconds: 86_400)) {
            _ = try AlignmentAuditionRequest.frameRange(
                startSeconds: 86_400.001,
                durationSeconds: 1,
                sampleRate: 48_000,
                availableFrames: 48_000 * 90_000
            )
        }
        #expect(throws: AlignmentAuditionRequestError.unsupportedSampleRate(maximum: 384_000)) {
            _ = try AlignmentAuditionRequest.frameRange(
                startSeconds: 1,
                durationSeconds: 1,
                sampleRate: .greatestFiniteMagnitude,
                availableFrames: .max
            )
        }
        #expect(throws: AlignmentAuditionRequestError.tooManyFrames(maximum: 1_500_000)) {
            _ = try AlignmentAuditionRequest.frameRange(
                startSeconds: 0,
                durationSeconds: 30,
                sampleRate: 96_000,
                availableFrames: 96_000 * 30
            )
        }
        #expect(try AlignmentAuditionRequest.frameRange(
            startSeconds: 4_500,
            durationSeconds: 2,
            sampleRate: 48_000,
            availableFrames: 48_000 * 4_600
        ) == 216_000_000..<216_096_000)
        #expect(AlignmentAuditionRequest.seekProgress(position: 24_000, target: 48_000) == 0.5)
    }

    @Test func gapAndOutsideCoverageMapResultsReachInspectionPresentation() throws {
        let groupID = RecorderGroupID()
        let firstEpoch = RecordingEpochID()
        let secondEpoch = RecordingEpochID()
        let occurrence = try SourceOccurrence(
            id: SourceOccurrenceID(),
            source: SourceID(),
            nominalRate: NominalRate(10),
            frameCount: 50
        )
        let reference = TimelineReference(
            group: groupID,
            epoch: firstEpoch,
            occurrence: occurrence.id
        )
        let spanEnd = try ExactRational(numerator: 2, denominator: 1)
        let identity = try AffineClockSegment(
            groupClockStart: .zero,
            groupClockEnd: spanEnd,
            rateRatio: .one,
            alignedOffset: .zero
        )
        let shifted = try AffineClockSegment(
            groupClockStart: .zero,
            groupClockEnd: spanEnd,
            rateRatio: .one,
            alignedOffset: try ExactRational(numerator: 3, denominator: 1)
        )
        let group = try GroupTimeMap(
            group: groupID,
            reference: reference,
            epochs: [
                EpochClockMap(
                    epoch: firstEpoch,
                    mapping: .mapped(segments: [identity], provenance: .timelineReference)
                ),
                EpochClockMap(
                    epoch: secondEpoch,
                    mapping: .mapped(
                        segments: [shifted],
                        provenance: .manual(ManualCorrection(basis: .numericEntry))
                    )
                ),
            ],
            placements: [OccurrencePlacement(
                occurrence: occurrence,
                spans: [
                    EpochSpan(
                        startFrame: 0,
                        endFrame: 20,
                        epoch: firstEpoch,
                        groupClockOffset: .zero
                    ),
                    EpochSpan(
                        startFrame: 30,
                        endFrame: 50,
                        epoch: secondEpoch,
                        groupClockOffset: try ExactRational(numerator: -3, denominator: 1)
                    ),
                ]
            )]
        )
        let map = try AlignedTimelineMap(reference: reference, groups: [group])
        let row = AlignmentRow(
            groupID: groupID,
            epochID: firstEpoch,
            groupName: "Recorder",
            epochLabel: "Take 1",
            sourceNames: "synthetic.wav",
            state: AlignmentPresentation.gap
        )

        let gap = try #require(AlignmentRegionProjection.project(
            map: map,
            row: row,
            sourceSeconds: 2.5
        ))
        #expect(gap.copy == AlignmentPresentation.gap)
        #expect(gap.precedingEpoch == firstEpoch)
        #expect(gap.followingEpoch == secondEpoch)

        let outside = try #require(AlignmentRegionProjection.project(
            map: map,
            row: row,
            sourceSeconds: 8
        ))
        #expect(outside.copy == AlignmentPresentation.outsideCoverage)
        #expect(outside.nearestSourceSeconds == 4.9)
        guard let nearest = outside.nearestSourceSeconds else {
            Issue.record("expected a mapped remedy")
            return
        }
        let nearestFrame = Int64((nearest * 10).rounded())
        guard case .aligned? = try? map.alignedTime(
            ofFrame: nearestFrame,
            in: occurrence.id
        ) else {
            Issue.record("nearest remedy did not map forward")
            return
        }
    }
}
