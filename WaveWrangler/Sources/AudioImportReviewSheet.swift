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
                + review.scan.uncountedSkips.duplicates + review.scan.uncountedSkips.folders
                + review.scan.uncountedSkips.symbolicLinks > 0 {
                Text("Refused: \(review.scan.uncountedSkips.notRecordings) non-audio, \(review.scan.uncountedSkips.folders) folders (not scanned), \(review.scan.uncountedSkips.symbolicLinks) symlinks, \(review.scan.uncountedSkips.hidden) hidden, \(review.scan.uncountedSkips.duplicates) duplicate selections. These items will not be added.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(review.orderedCandidates) { candidate in
                        HStack {
                            Toggle(isOn: Binding(get: { review.selected.contains(candidate.id) }, set: {
                                if $0 { review.selected.insert(candidate.id) } else { review.selected.remove(candidate.id) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(candidate.displayName)
                                    Text(caption(candidate.id))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(review.choices[candidate.id]?.canImport != true || !candidate.isRecording)
                            .accessibilityIdentifier("ww.addAudio.candidate.\(candidate.id)")
                            if review.layout == .sequential {
                                Text("\((review.order.firstIndex(of: candidate.id) ?? 0) + 1)")
                                    .font(.caption.monospacedDigit())
                                Button("Earlier", systemImage: "arrow.up") { review.move(candidate.id, by: -1) }
                                    .disabled(review.order.first == candidate.id)
                                    .accessibilityIdentifier("ww.addAudio.earlier.\(candidate.id)")
                                Button("Later", systemImage: "arrow.down") { review.move(candidate.id, by: 1) }
                                    .disabled(review.order.last == candidate.id)
                                    .accessibilityIdentifier("ww.addAudio.later.\(candidate.id)")
                            }
                        }
                    }
                }
            }.frame(maxHeight: 180)
            Picker("Audio Track", selection: $review.track) {
                ForEach(review.tracks) { Text($0.name).tag(AudioImportTrackIntent.existing($0.id)) }
                Text("New Audio Track").tag(AudioImportTrackIntent.newTrack)
            }.accessibilityIdentifier("ww.addAudio.track")
            if review.track == .newTrack {
                TextField("New track name", text: $review.newTrackName)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("ww.addAudio.trackName")
            }
            LabeledContent("Program start (seconds)") {
                TextField("Program start", text: $review.programSeconds)
                    .textFieldStyle(.roundedBorder).frame(width: 140)
                    .accessibilityIdentifier("ww.addAudio.position")
            }
            Picker("Multiple files", selection: $review.layout) {
                Text("Sequential, in the order above").tag(AudioImportLayout.sequential)
                Text("Overlay at the same position").tag(AudioImportLayout.overlay)
            }.accessibilityIdentifier("ww.addAudio.layout")
            Text(review.layout == .sequential
                ? "Selected clips play consecutively in the order above, using their verified durations after qualification. No time is inserted."
                : "Selected clips overlay at this position. Placement does not insert or ripple time.")
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

    private func caption(_ id: UUID) -> String {
        switch review.choices[id] {
        case .newSource: "New audio reference. Type from file name; audio is not read yet."
        case .reuse: "Reuse this episode's verified asset. Adds a clip, not another source or permission."
        case let .copy(_, _, title):
            "Reference the verified audio from \"\(title)\" with a new episode-owned source. Import explicitly confirms this reuse; original bytes remain shared and unchanged."
        case let .blocked(reason): reason
        case nil: "The audio selection is no longer available."
        }
    }
}
