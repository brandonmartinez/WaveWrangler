import SwiftUI
import WWCore
import WWMix

struct MixerView: View {
    @Bindable var presentation: EpisodeMixerPresentation
    var detached = false

    var body: some View {
        VStack(spacing: 0) {
            if detached {
                HStack {
                    Spacer(minLength: 4)
                    Button("Reattach", systemImage: "rectangle.bottomthird.inset.filled") { presentation.reattach() }
                        .accessibilityIdentifier("ww.mixer.reattach")
                }.padding(8)
                Divider()
            }
            if let error = presentation.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    .accessibilityIdentifier("ww.mixer.error")
            }
            if case let .failed(message) = presentation.controller?.state, message != presentation.error {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    .accessibilityIdentifier("ww.mixer.processorError")
            }
            if presentation.canDiscardEditorChanges {
                Button("Discard Unsaved Effect Changes...") { presentation.discardFailedEditorChanges() }
                    .accessibilityIdentifier("ww.mixer.discardEditorChanges")
                    .help("Requires confirmation. Reloads the last document state without capturing the failed editor.")
            }
            if presentation.episode != nil {
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(presentation.episode?.speakerAssignments ?? [], id: \.speakerID) { assignment in
                                MixerConsoleStrip(presentation: presentation, bus: .speaker(assignment.speakerID))
                                    .frame(width: 144)
                            }
                            ForEach(presentation.episode?.audioArrangement?.tracks ?? []) { track in
                                MixerConsoleStrip(presentation: presentation, bus: .audioTrack(track.id))
                                    .frame(width: 144)
                            }
                            if presentation.episode?.speakerAssignments.isEmpty == true
                                && presentation.episode?.audioArrangement?.tracks.isEmpty != false {
                                ContentUnavailableView("No mixer tracks", systemImage: "person.wave.2",
                                    description: Text("Assign confirmed speaker Primaries or add supplemental audio tracks."))
                                    .frame(width: 240)
                            }
                        }
                    }
                    .accessibilityIdentifier("ww.mixer.speakers")
                    Divider()
                    MixerConsoleStrip(presentation: presentation, bus: .master)
                        .frame(width: 144)
                        .background(.bar)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("ww.mixer.console")
            } else {
                ContentUnavailableView("Episode unavailable", systemImage: "waveform.badge.exclamationmark")
            }
            Divider()
            Text(status)
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(5)
                .accessibilityIdentifier("ww.mixer.status")
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Production mixer")
        .accessibilityIdentifier(detached ? "ww.mixer.detached" : "ww.mixer.docked")
        .task { presentation.discoverEffects() }
        .onChange(of: presentation.controller?.instanceRevision) { presentation.instanceDidChange() }
        .onCommand(Selector(("undo:")),
                   perform: presentation.state?.store.document?.undoManager?.canUndo == true
                       ? { presentation.state?.store.document?.undoManager?.undo() } : nil)
        .onCommand(Selector(("redo:")),
                   perform: presentation.state?.store.document?.undoManager?.canRedo == true
                       ? { presentation.state?.store.document?.undoManager?.redo() } : nil)
    }

    private var status: String {
        if presentation.state?.isReadOnly == true { return "Read-only show. Mixer editing is disabled." }
        if presentation.state?.store.document?.mixerTransactions.isBusy == true { return "Completing mixer transaction..." }
        if presentation.controller?.state == .loading { return "Loading Audio Units..." }
        return "48 kHz stereo. Sample peak + RMS meters. Solo/Mute is not saved."
    }
}

struct RecordingInputGainControl: View {
    let store: ShowDocumentStore
    let episodeID: EpisodeID
    let reference: ChannelReference
    var enabled: Bool
    var identifier: String

    var body: some View {
        if let channel = reference.channel.value {
            MixerNumberControl(title: "Input gain (dB)", value: Binding(
                get: { store.model.episode(episodeID)?.mix?.inputGainDB(for: reference.sourceID, channel: channel) ?? 0 },
                set: { gain in
                    guard enabled, store.canEdit else { return }
                    store.setRecordingInputGain(gain, reference: reference, in: episodeID)
                }), range: EpisodeMixState.gainRangeDB, identifier: identifier, endEditing: { store.endCoalescing() })
                .disabled(!enabled || !store.canEdit)
                .help("Saved gain for this recording and channel, before inserts. Original audio, waveforms, alignment, and transcripts are unchanged.")
            if let error = store.lastError {
                Text(EpisodeSetupModel.describe(error)).font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("\(identifier).error")
            }
        }
    }
}

struct MixerNumberControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let identifier: String
    let endEditing: () -> Void
    var compact = false
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var synchronizedDraft = ""
    @State private var draftIsDirty = false
    @State private var pendingValues: [Double] = []
    @State private var inputError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if !compact {
                    Text(title).font(.caption)
                    Spacer()
                }
                TextField(title, text: $draft)
                    .multilineTextAlignment(.trailing).frame(width: 65)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityIdentifier(identifier)
                    .onSubmit { if draftIsDirty { applyDraft(ending: true) }; endEditing() }
            }
            if !compact, range.lowerBound < range.upperBound {
                Slider(value: $value, in: range, onEditingChanged: { if !$0 { endEditing() } })
                    .accessibilityLabel(title).accessibilityIdentifier("\(identifier).slider")
            }
            if let inputError { Text(inputError).font(.caption2).foregroundStyle(.red) }
        }
        .onAppear { resetDraft() }
        .onChange(of: value) { _, value in
            // Async AU acknowledgments preserve typing; Undo or another window replaces the draft.
            if let index = pendingValues.firstIndex(where: { abs($0 - value) <= max(0.000001, abs(value) * 0.000001) }) {
                pendingValues.removeSubrange(...index)
                if !focused || !draftIsDirty { resetDraft() }
            } else {
                pendingValues = []
                draftIsDirty = false
                resetDraft()
            }
        }
        .onChange(of: draft) { _, _ in
            if focused, draft != synchronizedDraft {
                draftIsDirty = true
                applyDraft(ending: false)
            }
        }
        .onChange(of: focused) { _, focused in
            if !focused {
                if draftIsDirty { applyDraft(ending: true) }
                draftIsDirty = false
                endEditing()
            }
        }
    }

    private func resetDraft() {
        synchronizedDraft = value.formatted(.number.precision(.fractionLength(2)))
        draft = synchronizedDraft
    }

    private func applyDraft(ending: Bool) {
        do {
            let number = try Double(draft, format: .number)
            guard number.isFinite, range.contains(number) else {
                if ending { inputError = "Enter a value from \(range.lowerBound) to \(range.upperBound)." }
                return
            }
            inputError = nil
            if number != value {
                pendingValues.append(number)
                value = number
            }
        } catch {
            if ending { inputError = "Enter a finite number." }
        }
    }
}

struct MixerParameterView: View {
    @Bindable var presentation: EpisodeMixerPresentation
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Audio Unit Parameters").font(.headline)
                if let error = presentation.error { Text(error).foregroundStyle(.red).font(.caption) }
                if presentation.error != nil {
                    Button("Discard Unsaved Editor Changes...") { presentation.discardFailedEditorChanges() }
                        .accessibilityIdentifier("ww.mixer.editor.discard")
                }
                if presentation.parameters.isEmpty { Text("This unit exposes no generic parameters.") }
                ForEach(presentation.parameters.filter(\.readable), id: \.address) { parameter in
                    MixerNumberControl(title: parameter.name, value: Binding(
                        get: { Double(presentation.parameters.first { $0.address == parameter.address }?.value ?? parameter.value) },
                        set: { presentation.setParameter(parameter, value: $0) }),
                        range: Double(parameter.minimum)...Double(parameter.maximum),
                        identifier: "ww.mixer.parameter.\(parameter.address)",
                        endEditing: { presentation.state?.store.endCoalescing() })
                        .disabled(!parameter.writable || !presentation.canEdit)
                }
                Button("Done") { presentation.requestCloseEditor() }
                    .accessibilityIdentifier("ww.mixer.editor.done")
            }.padding(16)
        }
        .frame(minWidth: 360, minHeight: 220)
        .accessibilityIdentifier("ww.mixer.parameters")
    }
}
