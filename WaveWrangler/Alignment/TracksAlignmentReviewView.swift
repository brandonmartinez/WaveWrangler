import SwiftUI
import WWCore

struct TracksAlignmentReviewView: View {
    @Bindable var model: EpisodeAlignmentModel
    let setup: () -> Void
    let advanced: (AlignmentRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Tracks Alignment").font(.title2)
            Text("Nothing has moved. Select the measured proposals you accept. Unselected tracks and audio outside measured intervals remain unresolved; there is no automatic extension.")
                .fixedSize(horizontal: false, vertical: true)
            if model.hasAcceptedRevision {
                Text("Accepting replacement alignment resets active transcription, reviews, cuts and episode IN/OUT together. Undo restores the previous timing and work. Non-reference locks are honored outside this confirmed replacement operation.")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.tracksReviewRows.isEmpty {
                        Text("No recorder epochs are available. Add recordings to recorder groups and identify shared speaker channels in Recordings & Speakers.")
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
                    model.acceptTracksReview()
                }
                .disabled(!model.canAcceptTracksReview)
                .accessibilityIdentifier("ww.workflow.acceptAlignment")
            }
        }
        .padding(20)
        .frame(minWidth: 600, idealWidth: 720, minHeight: 420, idealHeight: 600)
        .disabled(model.isWorking)
        .interactiveDismissDisabled(model.isWorking)
    }
}
