import SwiftUI
import WWCommonEdit
import WWCore

struct AudioInsertionControls: View {
    @Bindable var editor: AudioClipEditorModel
    let programPlayhead: Double?

    var body: some View {
        Group {
            Button("Insert Intro…") {
                editor.requestInsertion(intro: true, programSeconds: nil)
            }
            .accessibilityIdentifier("ww.audioInsertion.intro")
            Button("Insert & Ripple…") {
                editor.requestInsertion(intro: false, programSeconds: programPlayhead)
            }
            .accessibilityIdentifier("ww.audioInsertion.insert")
            Menu("Inserted Time", systemImage: "rectangle.expand.vertical") {
                if let regions = editor.composition?.timeline.insertions, !regions.isEmpty {
                    ForEach(regions, id: \.region.id) { insertion in
                        Button("\(AudioInsertionSheet.seconds(insertion.programFrames.lowerBound)) s · \(AudioInsertionSheet.seconds(insertion.region.durationFrames)) s") {
                            editor.requestInsertionEdit(insertion.region.id)
                        }
                        .accessibilityIdentifier("ww.audioInsertion.region.\(insertion.region.id)")
                    }
                } else {
                    Text(editor.composition == nil ? "Program placement unavailable" : "No inserted time")
                }
            }
            .help("Review, move, resize, or remove inserted program time without deleting clip audio.")
            .accessibilityValue("\(editor.composition?.timeline.insertions.count ?? 0) regions")
            .accessibilityIdentifier("ww.audioInsertion.regions")
        }
        .disabled(!editor.store.canEdit)
    }
}

struct AudioInsertionSheet: View {
    @Bindable var editor: AudioClipEditorModel
    let session: AudioInsertionSession
    @State private var position: String
    @State private var length: String
    @State private var usingEnd = false
    @State private var retarget: Bool
    @State private var removing = false

    init(editor: AudioClipEditorModel, session: AudioInsertionSession) {
        self.editor = editor
        self.session = session
        _position = State(initialValue: Self.seconds(session.position))
        _length = State(initialValue: Self.seconds(session.duration))
        _retarget = State(initialValue: false)
    }

    static func seconds(_ frame: Int64) -> String {
        String(format: "%.9f", Double(frame) / 48_000)
    }

    private var isEditing: Bool {
        if case .edit = session.purpose { return true }
        return false
    }

    private var preview: Result<AudioInsertionEditing.Edit, Error> {
        Result {
            try editor.insertionPreview(session, position: position, length: length,
                usingEnd: usingEnd, retarget: retarget, removing: removing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title).font(.title2)
            Text("Explicit inserted program time, not an overlay or a recorder-clock edit.")
                .foregroundStyle(.secondary)
            if case .intro = session.purpose {
                Text("Default start: \(Self.seconds(session.position)) s, the first retained program boundary, including negative-time content. All retained dialogue follows it. Other pinned clips stay fixed.")
                    .accessibilityIdentifier("ww.audioInsertion.default")
            }
            if let range = session.editing.episode.cleanup?.workingRange {
                Text("Current original-aligned IN: \(range.tracksIn.map { String($0) } ?? "recording start") s; OUT: \(range.tracksOut.map { String($0) } ?? "recording end") s. These saved source boundaries are not rewritten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(isEditing ? "Program destination (seconds)" : "Program insertion start (seconds)")
                    TextField("Program insertion start", text: $position)
                        .accessibilityIdentifier("ww.audioInsertion.position")
                }
                GridRow {
                    Picker("Length", selection: $usingEnd) {
                        Text("Duration (seconds)").tag(false)
                        Text("End (program seconds)").tag(true)
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("ww.audioInsertion.lengthMode")
                    TextField(usingEnd ? "Program insertion end" : "Inserted duration", text: $length)
                        .accessibilityIdentifier("ww.audioInsertion.length")
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(removing)
            .onChange(of: usingEnd) { _, new in
                if let start = try? AudioClipEditorModel.programFrame(position),
                   let value = try? AudioClipEditorModel.programFrame(length) {
                    length = Self.seconds(new ? start + value : value - start)
                }
            }
            if isEditing {
                Text("A moved destination is measured with this region removed. Leave its current start unchanged to retain saved same-boundary order. Region-relative clips follow a move; starts in a removed tail clamp to the new end.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Remove this inserted time; retain all clip audio", isOn: $removing)
                    .accessibilityIdentifier("ww.audioInsertion.remove")
            } else if let clip = session.clip,
                      let selected = session.editing.composition.clips.first(where: { $0.clip.id == clip }) {
                Toggle("Move selected clip to insertion start", isOn: $retarget)
                    .accessibilityIdentifier("ww.audioInsertion.retarget")
                Text(retarget ? "Gap plus an explicit move of the selected clip." : "Gap only. The selected clip follows its normal placement rules; no explicit move.")
                    .font(.caption).bold()
                Text(selected.clip.anchor.isProgramPinned
                    ? "When checked, the selected pinned clip moves to the shown start and KEEPS its pin. Other pinned clips stay fixed."
                    : "When checked, the selected clip starts at region offset 0. Its full \(Self.seconds(Int64(selected.programFrames.count))) s of audio may overhang this independently chosen lead-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch preview {
                    case .success(let edit): affectedContent(edit)
                    case .failure(let error):
                        Label((error as? LocalizedError)?.errorDescription ?? "Inserted-time edit refused: \(error)",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("ww.audioInsertion.refusal")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140, maxHeight: .infinity)
            if let error = editor.error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("ww.audioInsertion.error")
            }
            HStack {
                Text("One Undo action. Temporary selection/cycle clears; playback stops on apply, never on preview. Originals, maps, transcripts, cuts, fades, and routing stay unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { editor.dismissInsertion() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("ww.audioInsertion.cancel")
                Button(removing ? "Remove & Ripple" : "Apply & Ripple") {
                    editor.commitInsertion(session, position: position, length: length,
                        usingEnd: usingEnd, retarget: retarget, removing: removing)
                }
                .keyboardShortcut(.defaultAction)
                .disabled({ if case .failure = preview { return true }; return false }())
                .accessibilityIdentifier("ww.audioInsertion.apply")
            }
        }
        .padding(20)
        .frame(minWidth: 650, idealWidth: 740, minHeight: 530, idealHeight: 650)
    }

    @ViewBuilder
    private func affectedContent(_ edit: AudioInsertionEditing.Edit) -> some View {
        let insertion = edit.after.timeline.insertions.first { $0.region.id == edit.regionID }
        Text(insertion.map {
            "PROGRAM insertion: \(Self.seconds($0.programFrames.lowerBound)) to \(Self.seconds($0.programFrames.upperBound)) s (\(Self.seconds($0.region.durationFrames)) s)"
        } ?? "Remove PROGRAM time at \(Self.seconds(edit.position)) s; starts inside it clamp to this seam.")
        .font(.headline)
        .accessibilityIdentifier("ww.audioInsertion.preview")
        Text("All \(session.editing.episode.alignmentSources.count) recording lanes, including hidden, muted, and backups, use the same downstream projection. A spanning supplemental clip stays whole.")
            .font(.caption)
        ForEach(Array(edit.after.timeline.dialogueSpans.enumerated()), id: \.offset) { _, span in
            Text("Dialogue \(Self.seconds(span.originalFrames.lowerBound))…\(Self.seconds(span.originalFrames.upperBound)) s → program \(Self.seconds(span.programFrames.lowerBound))…\(Self.seconds(span.programFrames.upperBound)) s")
                .font(.caption).monospacedDigit()
        }
        ForEach(edit.after.clips, id: \.clip.id) { next in
            let prior = edit.before.clips.first { $0.clip.id == next.clip.id }
            let name = session.editing.episode.source(next.clip.source)?.displayNameHint ?? "Audio Clip"
            let note = edit.clampedClips.contains(next.clip.id) ? "clamp to seam; all audio retained"
                : edit.retargetedClip == next.clip.id
                    ? (next.clip.anchor.isProgramPinned ? "explicit move; pin retained; all audio retained"
                        : "explicitly move selected clip; all audio retained")
                : next.clip.anchor.isProgramPinned ? "pinned; fixed" : "whole clip; follows its start"
            Text("\(name): \(Self.seconds(prior?.programFrames.lowerBound ?? next.programFrames.lowerBound)) → \(Self.seconds(next.programFrames.lowerBound)) s; \(note). Duration \(Self.seconds(Int64(next.programFrames.count))) s.")
                .font(.caption).monospacedDigit()
        }
        ForEach(edit.after.timeline.insertions, id: \.region.id) { next in
            let prior = edit.before.timeline.insertions.first { $0.region.id == next.region.id }
            Text("Inserted region: \(prior.map { Self.seconds($0.programFrames.lowerBound) } ?? "new") → \(Self.seconds(next.programFrames.lowerBound)) s; duration \(Self.seconds(next.region.durationFrames)) s.")
                .font(.caption).monospacedDigit()
        }
    }
}

private extension AudioPlacementAnchor {
    var isProgramPinned: Bool {
        if case .absolute = self { return true }
        return false
    }
}
