import SwiftUI
import WWCore

struct AudioClipInspector: View {
    @Bindable var editor: AudioClipEditorModel
    let playhead: Double?
    @State private var name = ""
    @State private var position = ""
    @State private var trimStart = ""
    @State private var trimEnd = ""
    @State private var track: AudioTrackID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.selected == nil ? "Audio Track" : "Audio Clip").font(.headline)
            if let selectedTrack = editor.selectedTrack,
               let current = editor.tracks.first(where: { $0.id == selectedTrack }) {
                TextField("Track name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { editor.renameTrack(current.id, name: name) }
                    .accessibilityIdentifier("ww.audioClip.trackName")
                Button("Rename Track") { editor.renameTrack(current.id, name: name) }
                    .accessibilityIdentifier("ww.audioClip.renameTrack")
            }
            if let selected = editor.selected {
                Text(editor.episode?.source(selected.clip.source)?.displayNameHint ?? "Audio Clip")
                    .font(.callout).textSelection(.enabled)
                LabeledContent("Program start (seconds)") {
                    TextField("Program start", text: $position).frame(width: 110)
                        .accessibilityIdentifier("ww.audioClip.start")
                }
                Picker("Audio Track", selection: Binding(
                    get: { track ?? selected.clip.track },
                    set: { track = $0 }
                )) {
                    ForEach(editor.tracks) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("ww.audioClip.destination")
                Button("Move Clip") {
                    editor.moveSelected(start: position, track: track ?? selected.clip.track)
                }.accessibilityIdentifier("ww.audioClip.move")
                Toggle("Pinned to program time", isOn: Binding(get: {
                    if case .absolute = selected.clip.anchor { return true }
                    return false
                }, set: { editor.pinSelected($0) }))
                    .accessibilityIdentifier("ww.audioClip.pinned")
                Text("Unpinned clips follow dialogue edits. Pinning preserves their current resolved position.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Owned output frames (48 kHz)").font(.caption)
                HStack {
                    TextField("Start frame", text: $trimStart).accessibilityIdentifier("ww.audioClip.trimStart")
                    Text("to")
                    TextField("Exclusive end frame", text: $trimEnd).accessibilityIdentifier("ww.audioClip.trimEnd")
                }.textFieldStyle(.roundedBorder)
                Button("Apply Edge Trim") { editor.resizeSelected(start: trimStart, end: trimEnd) }
                    .accessibilityIdentifier("ww.audioClip.trim")
                Text("Retained original source support: \(selected.clip.trim.startFrame)..<\(selected.clip.trim.endFrame) native frames at \(selected.asset.sampleRate) Hz. Crops preserve SRC phase and fades. Extending a discarded fade curve is refused.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Split at Playhead") {
                    if let playhead { editor.splitSelected(atProgramSeconds: playhead) }
                    else { editor.refuse("Show cut's removed audio is review-only. Choose a production position before splitting an Audio Clip.") }
                }
                    .accessibilityIdentifier("ww.audioClip.split")
                Button("Duplicate Clip") { editor.duplicateSelected() }
                    .accessibilityIdentifier("ww.audioClip.duplicate")
                Button("Delete Clip", role: .destructive) { editor.deleteSelected() }
                    .accessibilityIdentifier("ww.audioClip.delete")
                Text("Delete removes only this placement, never the source file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = editor.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
        }
        .disabled(!editor.store.canEdit)
        .onChange(of: editor.selected, initial: true) { _, _ in load() }
        .onChange(of: editor.selectedTrack) { _, _ in load() }
        .onChange(of: editor.tracks.first { $0.id == editor.selectedTrack }?.name) { _, current in
            name = current ?? ""
        }
    }

    private func load() {
        name = editor.tracks.first { $0.id == editor.selectedTrack }?.name ?? ""
        guard let selected = editor.selected else { return }
        position = String(format: "%.9f", Double(selected.programFrames.lowerBound) / 48_000)
        track = selected.clip.track
        if let frames = selected.clip.ownedOutputFrames(asset: selected.asset) {
            trimStart = String(frames.lowerBound)
            trimEnd = String(frames.upperBound)
        }
    }
}
