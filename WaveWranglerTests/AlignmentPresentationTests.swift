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
        let rows = EpisodeAlignmentModel.makeRows(model: model, episodeID: episode.id, states: [])
        #expect(rows.count == 1)
        #expect(rows.first?.groupName == "Remote recorder")
        #expect(rows.first?.epochLabel == "Take 2")
        #expect(rows.first?.sourceNames == "synthetic.wav")
        #expect(rows.first?.state.heading == "Unsupported — not attempted")
    }

    @MainActor
    @Test func completeReplacementUndoRedoRepeatsPersistenceCallback() throws {
        let document = ShowDocument()
        var original = ShowDocumentModel.untitled(title: "Before")
        original.episodes = [Episode(title: "Synthetic", number: 1)]
        document.store.replaceLoadedModel(original)
        var revised = original
        revised.show.title = "After"
        var callbackTitles: [String] = []

        #expect(document.store.applyReplacement(
            "Edit Alignment",
            model: revised,
            afterChange: { callbackTitles.append($0.show.title) }
        ))
        #expect(document.store.model.show.title == "After")
        let undoManager = try #require(document.undoManager)
        undoManager.undo()
        #expect(document.store.model.show.title == "Before")
        undoManager.redo()
        #expect(document.store.model.show.title == "After")
        #expect(callbackTitles == ["After", "Before", "After"])
    }
}
