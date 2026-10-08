import Observation
import SwiftUI
import WWOrganizer

@MainActor
@Observable
final class TranscriptReviewState {
    var selectedOccurrenceID: String? = TranscriptReviewShellPresentation.occurrences.first?.id
    var filterText = ""

    var visibleOccurrences: [TranscriptReviewShellOccurrence] {
        guard !filterText.isEmpty else { return TranscriptReviewShellPresentation.occurrences }
        return TranscriptReviewShellPresentation.occurrences.filter {
            $0.title.localizedCaseInsensitiveContains(filterText)
        }
    }

    var selectedOccurrence: TranscriptReviewShellOccurrence? {
        TranscriptReviewShellPresentation.occurrences.first { $0.id == selectedOccurrenceID }
    }
}

struct TranscriptReviewView: View {
    @Bindable var state: TranscriptReviewState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcript and timeline review")
                    .wwFont(.title2)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("ww.review.heading")
                Text("Provisional UI shell · synthetic fixture only · no media read or speech analysis.")
                    .wwFont(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ww.review.provisionalNotice")
            }
            .accessibilityElement(children: .contain)

            Text(TranscriptReviewShellPresentation.noLiveSourceReason)
                .wwFont(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .accessibilityLabel("Review blocked")
                .accessibilityValue(TranscriptReviewShellPresentation.noLiveSourceReason)
                .accessibilityIdentifier("ww.review.blockedReason")

            GeometryReader { geometry in
                if geometry.size.width < 620 {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            transcriptPane
                                .frame(minHeight: 210, idealHeight: 250)
                            timelinePane
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        transcriptPane
                            .frame(minWidth: 230, maxWidth: .infinity)
                        timelinePane
                            .frame(minWidth: 250, maxWidth: .infinity)
                    }
                }
            }
        }
        .wwFont(.body)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.review.workspace")
    }

    private var transcriptPane: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Filter synthetic occurrences", text: $state.filterText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter synthetic transcript")
                    .accessibilityHint("Filtering is local to this synthetic fixture.")
                    .accessibilityIdentifier("ww.review.filter")

                List(selection: $state.selectedOccurrenceID) {
                    ForEach(state.visibleOccurrences) { occurrence in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(occurrence.title)
                                .wwFont(.body)
                            Text(occurrence.note)
                                .wwFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(occurrence.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(occurrence.title)
                        .accessibilityValue(occurrence.note)
                        .accessibilityIdentifier("ww.review.occurrence.\(occurrence.id)")
                    }
                }
                .listStyle(.inset)
                .accessibilityLabel("Transcript occurrences")
                .accessibilityValue("\(state.visibleOccurrences.count) synthetic occurrences; none analyzed")
                .accessibilityIdentifier("ww.review.occurrences")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Transcript occurrences")
                .wwFont(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityIdentifier("ww.review.transcriptPane")
    }

    private var timelinePane: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("List alternative; no waveform position is inferred.")
                    .wwFont(.body)
                    .fixedSize(horizontal: false, vertical: true)

                Text(state.selectedOccurrence?.title ?? "No occurrence selected")
                    .wwFont(.body)
                    .accessibilityLabel("Timeline selection")
                    .accessibilityValue(state.selectedOccurrence?.title ?? "No occurrence selected")
                    .accessibilityIdentifier("ww.review.timeline.selectedOccurrence")

                ForEach(TranscriptReviewShellPresentation.lanes) { lane in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lane.label)
                            .wwFont(.body)
                            .fontWeight(.medium)
                        Text(lane.state)
                            .wwFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(lane.label)
                    .accessibilityValue(lane.state)
                    .accessibilityIdentifier("ww.review.lane.\(lane.id)")
                }

                Divider()
                ForEach(TranscriptReviewShellPresentation.timeDomains, id: \.0) { domain in
                    LabeledContent(domain.1) {
                        Text(TranscriptReviewShellPresentation.timeNotEstablished)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(domain.1)
                    .accessibilityValue(TranscriptReviewShellPresentation.timeNotEstablished)
                    .accessibilityIdentifier("ww.review.timeline.domain.\(domain.0)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Timeline and lane list")
                .wwFont(.headline)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityIdentifier("ww.review.timelinePane")
    }
}

struct TranscriptReviewInspector: View {
    @Bindable var state: TranscriptReviewState
    let goToSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review Inspector")
                .wwFont(.headline)
                .accessibilityAddTraits(.isHeader)

            actionButton("Accept Shorten when safe", id: "acceptShorten", reason: TranscriptReviewShellPresentation.acceptBlockedReason)
            actionButton("Lift — preserve timing", id: "lift", reason: TranscriptReviewShellPresentation.liftBlockedReason)
            actionButton("Reject proposal", id: "reject", reason: TranscriptReviewShellPresentation.rejectBlockedReason)

            Button("Go to Setup", action: goToSetup)
                .accessibilityHint("Choose or confirm a Primary source in Setup. Keyboard alternative: View, Setup, Command-1.")
                .accessibilityIdentifier("ww.review.remedy.setup")
            Text("Keyboard: View > Setup (⌘1).")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Keyboard alternative: View > Setup (Command-1)")
                .accessibilityIdentifier("ww.review.remedy.keyboard")

            Divider()

            LabeledContent("Selection") {
                Text(state.selectedOccurrence?.title ?? "No occurrence selected")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Selected occurrence")
            .accessibilityValue(state.selectedOccurrence?.title ?? "No occurrence selected")
            .accessibilityIdentifier("ww.review.inspector.selection")

            LabeledContent("Occurrence ID") {
                Text(state.selectedOccurrence?.id ?? "None")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Occurrence ID")
            .accessibilityValue(state.selectedOccurrence?.id ?? "None")
            .accessibilityIdentifier("ww.review.inspector.occurrenceID")

            LabeledContent("Token stub ID") {
                Text(state.selectedOccurrence?.tokenStubID ?? "None")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Token stub ID")
            .accessibilityValue(state.selectedOccurrence?.tokenStubID ?? "None")
            .accessibilityIdentifier("ww.review.inspector.tokenID")

            LabeledContent("Proposal selection") {
                Text(TranscriptReviewShellPresentation.noProposalState)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Proposal selection")
            .accessibilityValue(TranscriptReviewShellPresentation.noProposalState)
            .accessibilityIdentifier("ww.review.inspector.proposal")

            Text("Analysis state: None")
                .accessibilityLabel("Analysis state")
                .accessibilityValue("None — this shell contains no analysis")
                .accessibilityIdentifier("ww.review.inspector.analysisState")

            Text("Primary role: synthetic example, not analyzed")
                .accessibilityIdentifier("ww.review.inspector.primaryState")
            Text("Backup role: synthetic example, not analyzed; no transcript")
                .accessibilityIdentifier("ww.review.inspector.backupState")

            ForEach(TranscriptReviewShellPresentation.timeDomains, id: \.0) { domain in
                LabeledContent(domain.1) {
                    Text(TranscriptReviewShellPresentation.timeNotEstablished)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(domain.1)
                .accessibilityValue(TranscriptReviewShellPresentation.timeNotEstablished)
                .accessibilityIdentifier("ww.review.inspector.domain.\(domain.0)")
            }

            Text("Default proposal mode: Shorten when safe. No proposal is active.")
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ww.review.inspector.defaultMode")

            actionButton(
                "Single-lane audition — not a full preview",
                id: "singleLaneAudition",
                reason: TranscriptReviewShellPresentation.singleLaneAuditionBlockedReason
            )
            actionButton(
                "Preview complete episode",
                id: "fullPreview",
                reason: TranscriptReviewShellPresentation.fullPreviewBlockedReason
            )

            Text(TranscriptReviewShellPresentation.fullPreviewBlockedReason)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Complete preview blocked")
                .accessibilityValue(TranscriptReviewShellPresentation.fullPreviewBlockedReason)
                .accessibilityIdentifier("ww.review.inspector.previewBlockedReason")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.review.inspector")
    }

    private func actionButton(_ title: String, id: String, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(title) {}
                .disabled(true)
                .help(reason)
                .accessibilityLabel(title)
                .accessibilityValue(reason)
                .accessibilityHint("Unavailable in this provisional review shell.")
                .accessibilityIdentifier("ww.review.action.\(id)")

            Text(reason)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(title) blocked")
                .accessibilityValue(reason)
                .accessibilityIdentifier("ww.review.action.\(id).reason")
        }
    }
}
