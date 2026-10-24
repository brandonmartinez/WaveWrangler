import SwiftUI
import WWCore

struct TracksAlignmentReviewView: View {
    @Bindable var model: EpisodeAlignmentModel
    let setup: () -> Void
    let advanced: (AlignmentRow) -> Void
    @State private var confirmingAdaptiveAcceptance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Tracks Alignment").font(.title2)
            Text("Nothing has moved. Select recorder timing or adaptive file timing to accept. With the same reference, unselected recordings keep their saved timing. Changing the reference leaves unselected recordings unresolved. There is no automatic extension.")
                .fixedSize(horizontal: false, vertical: true)
            Text("File timing uses its chosen reference recording, not a device-quality assumption. If recorder timing is also accepted, the file correction uses that final reference placement.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let reference = model.tracksReviewReferenceName {
                Text("Alignment reference: \(reference). Current timing and edits remain unchanged until acceptance.")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ww.workflow.timingReference")
            }
            if model.hasAcceptedRevision {
                Text("Accepting replacement alignment resets active transcription, reviews, cuts and episode IN/OUT together. Undo restores the previous timing and work. Non-reference locks are honored outside this confirmed replacement operation.")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.tracksReviewRows.isEmpty {
                        Text("No recording segments are available. Add recordings to recorder groups and identify shared speaker channels in Recordings & Speakers.")
                    }
                    ForEach(model.tracksReviewRows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(row.groupName) · \(row.epochLabel)").font(.headline)
                            Text(row.sourceNames).font(.caption)
                            Label(row.state.heading, systemImage: row.state.symbol)
                            Text(row.state.evidence).font(.caption)
                            if let details = row.state.details {
                                Text(details).font(.caption).textSelection(.enabled)
                            }
                            if model.tracksReviewProposals.contains(row.epochID) {
                                Toggle("Accept measured interval", isOn: Binding(
                                    get: { model.selectedTracksProposals.contains(row.epochID) },
                                    set: { selected in
                                        if selected { model.selectedTracksProposals.insert(row.epochID) }
                                        else { model.selectedTracksProposals.remove(row.epochID) }
                                    }
                                ))
                                .accessibilityIdentifier("ww.workflow.acceptEpoch.\(row.epochID)")
                            }
                            if let adaptive = model.tracksAdaptiveRecord(for: row.epochID),
                               !adaptive.timing.regions.isEmpty {
                                Toggle("Accept supported file timing", isOn: Binding(
                                    get: { model.selectedTracksAdaptive.contains(row.epochID) },
                                    set: { selected in
                                        if selected { model.selectedTracksAdaptive.insert(row.epochID) }
                                        else {
                                            model.selectedTracksAdaptive.remove(row.epochID)
                                            model.estimatedTracksAdaptive.remove(row.epochID)
                                        }
                                    }
                                ))
                                .accessibilityIdentifier("ww.workflow.acceptAdaptive.\(row.epochID)")
                                let estimates = adaptive.playbackIntervals(includeEstimated: true).filter { $0.kind == .estimated }
                                if !estimates.isEmpty {
                                    Toggle("Keep bounded gaps using estimated timing", isOn: Binding(
                                        get: { model.estimatedTracksAdaptive.contains(row.epochID) },
                                        set: { selected in
                                            if selected { model.estimatedTracksAdaptive.insert(row.epochID) }
                                            else { model.estimatedTracksAdaptive.remove(row.epochID) }
                                        }
                                    ))
                                    .disabled(!model.selectedTracksAdaptive.contains(row.epochID))
                                    .accessibilityIdentifier("ww.workflow.estimatedAdaptive.\(row.epochID)")
                                    Text("\(String(format: "%.1f", estimates.reduce(0) { $0 + $1.sourceEnd - $1.sourceStart })) s of estimated gap timing is available. Off by default; retained audio is not verified alignment.")
                                        .font(.caption)
                                }
                                Text("Pitch-preserving timing affects only this file, not its recorder group. Unsupported gaps and ends remain silent.")
                                    .font(.caption)
                            }
                            HStack {
                                Button("Recordings & Speakers…", action: setup)
                                Button("Advanced / manual timing…") { advanced(row) }
                            }
                            .controlSize(.small)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    ForEach(model.ungroupedSources) { source in
                        Label("\(source.displayNameHint): Ungrouped. Add to a recorder group in Recordings & Speakers before alignment.",
                              systemImage: "exclamationmark.triangle")
                    }
                }
            }
            if let error = model.lastError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { model.discardTracksReview() }.keyboardShortcut(.cancelAction)
                Button("Recordings & Speakers…", action: setup)
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button(model.hasAcceptedRevision ? "Accept Replacement Alignment" : "Accept Alignment") {
                    if model.selectedTracksAdaptive.isEmpty { model.acceptTracksReview() }
                    else { confirmingAdaptiveAcceptance = true }
                }
                .disabled(!model.canAcceptTracksReview)
                .accessibilityIdentifier("ww.workflow.acceptAlignment")
            }
        }
        .padding(20)
        .frame(minWidth: 600, idealWidth: 720, maxWidth: .infinity,
               minHeight: 420, idealHeight: 600, maxHeight: .infinity)
        .presentationSizing(.fitted)
        .disabled(model.isWorking)
        .interactiveDismissDisabled(model.isWorking)
        .confirmationDialog("Apply selected adaptive file timing?", isPresented: $confirmingAdaptiveAcceptance) {
            Button("Accept selected alignment") { model.acceptTracksReview() }
            Button("Keep review only", role: .cancel) {}
        } message: {
            Text(AlignmentPresentation.adaptiveAcceptanceWarning(
                includeEstimated: !model.estimatedTracksAdaptive.intersection(model.selectedTracksAdaptive).isEmpty
            ))
        }
    }
}
