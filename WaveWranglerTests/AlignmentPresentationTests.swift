import Foundation
import Testing
import WWAlignPipeline
import WWCore
import WWDecode
import WWTimeMap

@Suite("Alignment presentation")
struct AlignmentPresentationTests {
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
            .cancelled, .notFound, .permissionDenied, .notARegularFile, .notOpenedReadOnly,
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
        #expect(rows.first?.state.heading == "Unsupported — not attempted")
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
