import SwiftUI
import WWCore

struct AudioImportReviewSheet: View {
    @State var review: AudioImportReview
    let cancel: () -> Void
    let apply: (AudioImportReview) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Audio").font(.title2)
            Text("Selection is metadata-only. Import explicitly authorizes read-only local audio qualification. No originals are copied, changed, or silently downloaded.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            if review.scan.uncountedSkips.unreadable > 0 {
                Label("\(review.scan.uncountedSkips.unreadable) selections could not be read and are not included. Choose accessible originals again to include them.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if review.scan.uncountedSkips.notRecordings + review.scan.uncountedSkips.hidden
                + review.scan.uncountedSkips.duplicates > 0 {
                Text("Ignored: \(review.scan.uncountedSkips.notRecordings) non-audio, \(review.scan.uncountedSkips.hidden) hidden, \(review.scan.uncountedSkips.duplicates) duplicate selections.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(review.scan.candidates) { candidate in
                        Toggle(isOn: Binding(get: { review.selected.contains(candidate.id) }, set: {
                            if $0 { review.selected.insert(candidate.id) } else { review.selected.remove(candidate.id) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(candidate.displayName)
                                Text(candidate.alreadyInEpisode ? "Already referenced; use Duplicate Clip." : "Type from file name; audio details are not read yet.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(candidate.alreadyInEpisode || !candidate.isRecording)
                        .accessibilityIdentifier("ww.addAudio.candidate.\(candidate.id)")
                    }
                }
            }.frame(maxHeight: 180)
            Picker("Audio Track", selection: $review.track) {
                ForEach(review.tracks) { Text($0.name).tag(Optional($0.id)) }
                Text("New Audio Track").tag(Optional<AudioTrackID>.none)
            }.accessibilityIdentifier("ww.addAudio.track")
            if review.track == nil {
                TextField("New track name", text: $review.newTrackName)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("ww.addAudio.trackName")
            }
            LabeledContent("Program start (seconds)") {
                TextField("Program start", text: $review.programSeconds)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
                    .accessibilityIdentifier("ww.addAudio.position")
            }
            Text("Selected clips overlay at this position. Placement does not insert or ripple time.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("ww.addAudio.cancel")
                Spacer()
                Button("Import") { apply(review) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(review.selected.isEmpty)
                    .accessibilityIdentifier("ww.addAudio.import")
            }
        }
        .padding(20).frame(width: 510)
    }
}
