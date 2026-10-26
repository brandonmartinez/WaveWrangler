import SwiftUI
import WWCore
import WWMix

struct MixerView: View {
    @Bindable var presentation: EpisodeMixerPresentation
    var detached = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mixer").font(.headline)
                Button("Play Mix", systemImage: "play.fill") { playMix() }
                    .disabled(presentation.model == nil || presentation.episode?.speakerAssignments.isEmpty != false)
                    .accessibilityIdentifier("ww.mixer.play")
                    .help("Play only confirmed speaker Primaries through the production mixer. Source audition is unchanged.")
                Button("Stop", systemImage: "stop.fill") { presentation.model?.stopAudition() }
                    .disabled(presentation.model?.canStopAudition != true)
                    .accessibilityIdentifier("ww.mixer.stop")
                Spacer(minLength: 4)
                if detached {
                    Button("Reattach", systemImage: "rectangle.bottomthird.inset.filled") { presentation.reattach() }
                        .accessibilityIdentifier("ww.mixer.reattach")
                } else {
                    Button("Pop Out", systemImage: "macwindow.on.rectangle") { presentation.detach() }
                        .accessibilityIdentifier("ww.mixer.detach")
                }
            }
            .padding(8)
            Divider()
            if let error = presentation.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    .accessibilityIdentifier("ww.mixer.error")
            }
            if case let .failed(message) = presentation.controller?.state {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
                    .accessibilityIdentifier("ww.mixer.processorError")
            }
            if presentation.episode != nil {
                HStack(spacing: 0) {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(presentation.episode?.speakerAssignments ?? [], id: \.speakerID) { assignment in
                                MixerStrip(presentation: presentation, bus: .speaker(assignment.speakerID))
                                    .frame(width: 218)
                            }
                            if presentation.episode?.speakerAssignments.isEmpty == true {
                                ContentUnavailableView("No speakers", systemImage: "person.wave.2",
                                    description: Text("Assign speakers and confirm their Primary recordings in Recordings & Speakers."))
                                    .frame(width: 240)
                            }
                        }
                        .padding(8)
                    }
                    .accessibilityIdentifier("ww.mixer.speakers")
                    Divider()
                    MixerStrip(presentation: presentation, bus: .master)
                        .frame(width: 218).padding(8)
                        .background(.bar)
                }
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
    }

    private var status: String {
        if presentation.state?.isReadOnly == true { return "Read-only show. Mixer editing is disabled." }
        if presentation.state?.store.document?.mixerTransactions.isBusy == true { return "Completing mixer transaction..." }
        if presentation.controller?.state == .loading { return "Loading Audio Units..." }
        return "Buffered production listening - 48 kHz stereo. Levels show prepared PCM, not acoustic output. Solo/Mute is not saved."
    }

    private func playMix() {
        guard let document = presentation.state?.store.document else { return }
        Task {
            do {
                try await document.mixerTransactions.barrier(replacingInstances: true) {
                    guard let model = presentation.model, !presentation.isClosed else { throw MixerFailure.staleDependencies }
                    model.playProductionMix()
                }
            } catch { document.mixerTransactions.report(error) }
        }
    }
}

private struct MixerStrip: View {
    @Bindable var presentation: EpisodeMixerPresentation
    let bus: MixerBus

    private var identifier: String { "ww.mixer.strip.\(bus.identifier)" }
    private var gain: Double {
        switch bus {
        case .speaker(let id): presentation.mix.state(for: id).gainDB
        case .master: presentation.mix.master.gainDB
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                Text(name).font(.headline).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("\(identifier).name")
                input
                Divider()
                HStack {
                    Text("Inserts").font(.subheadline)
                    Spacer()
                    Menu("Add") {
                        ForEach(presentation.components) { component in
                            Button(component.name) {
                                presentation.changeInserts(bus, action: "Add Audio Unit") {
                                    $0 + [AudioUnitSlot(component: component.identity,
                                        productName: component.name, version: String(component.version))]
                                }
                            }
                        }
                        if presentation.components.isEmpty { Text("No installed effects found") }
                    }
                    .accessibilityIdentifier("\(identifier).add")
                    .disabled(!canEdit || presentation.inserts(bus).count >= EpisodeMixState.maximumInsertsPerBus)
                }
                ForEach(Array(presentation.inserts(bus).enumerated()), id: \.element.id) { index, slot in
                    MixerInsertView(presentation: presentation, bus: bus, slot: slot, index: index)
                }
                if presentation.inserts(bus).isEmpty { Text("No inserts").font(.caption).foregroundStyle(.secondary) }
                Divider()
                MixerNumberControl(title: "Output (dB)", value: Binding(get: { gain },
                    set: { presentation.setFader($0, bus: bus) }),
                    range: EpisodeMixState.gainRangeDB, identifier: "\(identifier).gain",
                    endEditing: { presentation.state?.store.endCoalescing() })
                    .disabled(!canEdit)
                if case .speaker(let speaker) = bus {
                    MixerNumberControl(title: "Pan", value: Binding(
                        get: { presentation.mix.state(for: speaker).pan },
                        set: { presentation.setPan($0, speaker: speaker) }),
                        range: -1...1, identifier: "\(identifier).pan",
                        endEditing: { presentation.state?.store.endCoalescing() })
                        .disabled(!canEdit)
                    HStack {
                        Toggle("Solo", isOn: listeningBinding(speaker: speaker, solo: true))
                            .accessibilityIdentifier("\(identifier).solo")
                        Toggle("Mute", isOn: listeningBinding(speaker: speaker, solo: false))
                            .accessibilityIdentifier("\(identifier).mute")
                    }.toggleStyle(.button)
                    MixerLevelView(meters: presentation.controller?.meters?.speakerMeters[speaker].map { [$0] } ?? [],
                                   identifier: "\(identifier).level")
                } else {
                    Toggle("Mute Master", isOn: Binding(
                        get: { presentation.controller?.masterMuted ?? false },
                        set: { presentation.controller?.masterMuted = $0 }))
                        .toggleStyle(.button)
                        .accessibilityIdentifier("\(identifier).mute")
                    MixerLevelView(meters: presentation.controller?.meters?.masterMeters ?? [],
                                   identifier: "\(identifier).level")
                }
            }
            .padding(10)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name) mixer strip")
        .accessibilityIdentifier(identifier)
    }

    private var canEdit: Bool {
        presentation.canEdit && presentation.state?.store.document?.mixerTransactions.isBusy != true
    }

    private var name: String {
        switch bus {
        case .speaker(let id): presentation.state?.store.model.speaker(id)?.name ?? "Unknown speaker"
        case .master: "Master"
        }
    }

    @ViewBuilder private var input: some View {
        if case .speaker(let speaker) = bus, let episode = presentation.episode,
           let state = presentation.state {
            if let assignment = episode.assignment(for: speaker), let primary = assignment.primary,
               let source = episode.source(primary.sourceID) {
                Text("Primary: \(source.displayNameHint)").font(.caption).lineLimit(3)
                    .accessibilityIdentifier("\(identifier).input")
                if let channel = primary.resolvedChannel(in: episode) {
                    Text("Channel \(channel + 1)").font(.caption).foregroundStyle(.secondary)
                    RecordingInputGainControl(store: state.store, episodeID: episode.id,
                        reference: ChannelReference(sourceID: source.id, statedChannel: channel),
                        enabled: canEdit, identifier: "\(identifier).inputGain")
                } else {
                    Text("Choose an explicit input channel in Recordings & Speakers.")
                        .font(.caption).foregroundStyle(.red)
                }
                if assignment.primaryConfirmation != .userConfirmed {
                    Text("Confirm this Primary before production listening.").font(.caption).foregroundStyle(.red)
                }
            } else {
                Text("No Primary selected. Choose and confirm one in Recordings & Speakers.")
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("\(identifier).input")
            }
        } else {
            Text("Stereo speaker sum").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func listeningBinding(speaker: SpeakerID, solo: Bool) -> Binding<Bool> {
        Binding(
            get: {
                (solo ? presentation.controller?.soloedSpeakers : presentation.controller?.mutedSpeakers)?
                    .contains(speaker) ?? false
            },
            set: { value in
                guard let controller = presentation.controller else { return }
                if solo {
                    if value { controller.soloedSpeakers.insert(speaker) } else { controller.soloedSpeakers.remove(speaker) }
                } else {
                    if value { controller.mutedSpeakers.insert(speaker) } else { controller.mutedSpeakers.remove(speaker) }
                }
            })
    }
}

private struct MixerInsertView: View {
    @Bindable var presentation: EpisodeMixerPresentation
    let bus: MixerBus
    let slot: AudioUnitSlot
    let index: Int
    private var identifier: String { "ww.mixer.slot.\(slot.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(index + 1). \(slot.productName ?? "Audio Unit")").font(.caption.weight(.semibold))
            if !presentation.components.contains(where: { $0.identity == slot.component }) {
                Text("Not installed. Saved state retained. Install this unit or remove the slot.")
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("\(identifier).missing")
            } else if let status = presentation.controller?.unitStatuses.first(where: { $0.slot == slot.id }) {
                Text("\(status.loadedInProcess ? "In process" : "Out of process") - \(status.latencyFrames) latency frames")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Not loaded").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Editor") { presentation.openEditor(slot) }
                    .accessibilityIdentifier("\(identifier).editor")
                Menu {
                    Button("Generic Parameters") { presentation.openEditor(slot, generic: true) }
                        .accessibilityIdentifier("\(identifier).generic")
                    Button("Move Earlier") { move(-1) }.disabled(index == 0)
                        .accessibilityIdentifier("\(identifier).earlier")
                    Button("Move Later") { move(1) }.disabled(index + 1 == presentation.inserts(bus).count)
                        .accessibilityIdentifier("\(identifier).later")
                    Button("Remove") {
                        presentation.changeInserts(bus, action: "Remove Audio Unit") { $0.filter { $0.id != slot.id } }
                    }.accessibilityIdentifier("\(identifier).remove")
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("Actions for \(slot.productName ?? "Audio Unit")")
                    .accessibilityIdentifier("\(identifier).actions")
            }
            Toggle("Bypass", isOn: Binding(get: { slot.bypassed }, set: { bypass in
                presentation.changeInserts(bus, action: "Bypass Audio Unit") { slots in
                    slots.map { value in
                        var value = value
                        if value.id == slot.id { value.bypassed = bypass }
                        return value
                    }
                }
            }))
            .accessibilityIdentifier("\(identifier).bypass")
        }
        .disabled(!presentation.canEdit || presentation.state?.store.document?.mixerTransactions.isBusy == true)
        .padding(6)
        .background(.background, in: RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func move(_ delta: Int) {
        presentation.changeInserts(bus, action: "Reorder Audio Units") { slots in
            guard let current = slots.firstIndex(where: { $0.id == slot.id }),
                  slots.indices.contains(current + delta) else { return slots }
            var next = slots
            next.swapAt(current, current + delta)
            return next
        }
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
                    guard enabled else { return }
                    store.apply("Adjust Recording Input Gain", coalescing: "inputGain.\(episodeID).\(reference.sourceID).\(channel)") {
                        model throws(DomainError) in try model.settingInputGain(gain, for: reference, in: episodeID)
                    }
                }), range: EpisodeMixState.gainRangeDB, identifier: identifier, endEditing: { store.endCoalescing() })
                .disabled(!enabled)
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
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var synchronizedDraft = ""
    @State private var draftIsDirty = false
    @State private var pendingValues: [Double] = []
    @State private var inputError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                TextField(title, text: $draft)
                    .multilineTextAlignment(.trailing).frame(width: 65)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityIdentifier(identifier)
                    .onSubmit { if draftIsDirty { applyDraft(ending: true) }; endEditing() }
            }
            if range.lowerBound < range.upperBound {
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

private struct MixerLevelView: View {
    let meters: [MixerMeter]
    let identifier: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(meters.enumerated()), id: \.offset) { index, meter in
                ProgressView(value: min(1, Double(meter.peak)))
                    .tint(meter.clipped ? .red : .green)
                    .accessibilityLabel("Prepared level \(index + 1)")
                Text("Peak \(db(meter.peak)) / RMS \(db(meter.rms))\(meter.clipped ? " - CLIP" : "")")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(meter.clipped ? Color.red : .secondary)
            }
            if meters.isEmpty { Text("No prepared levels").font(.caption2).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
    }
    private func db(_ amplitude: Float) -> String {
        amplitude == 0 ? "-inf dBFS" : String(format: "%.1f dBFS", 20 * log10(Double(amplitude)))
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
