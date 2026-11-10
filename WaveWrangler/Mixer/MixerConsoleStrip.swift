import SwiftUI
import WWCore
import WWMix

struct MixerConsoleStrip: View {
    @Bindable var presentation: EpisodeMixerPresentation
    let bus: MixerBus
    var minimumHeight: CGFloat = 0
    @State private var showingInput = false
    private var identifier: String { "ww.mixer.strip.\(bus.identifier)" }
    private var canEdit: Bool {
        presentation.canEdit && presentation.state?.store.document?.mixerTransactions.isBusy != true
    }
    private var speaker: Speaker? {
        guard case .speaker(let id) = bus else { return nil }
        return presentation.state?.store.model.speaker(id)
    }
    private var name: String {
        switch bus {
        case .speaker: speaker?.name ?? "Unknown speaker"
        case .audioTrack(let id): presentation.episode?.audioArrangement?.tracks.first { $0.id == id }?.name ?? "Audio track"
        case .master: "Master"
        }
    }
    private var appearance: SpeakerAppearance? {
        guard let speaker else { return nil }
        return presentation.state?.store.model.speakerAppearance(speaker.id, in: presentation.episode?.id)
    }
    private var color: Color { appearance?.color.swiftUIColor ?? (bus == .master ? .secondary : .teal) }
    private var gain: Binding<Double> {
        Binding(get: {
            switch bus {
            case .speaker(let id): presentation.mix.state(for: id).gainDB
            case .audioTrack(let id): presentation.mix.state(for: id).gainDB
            case .master: presentation.mix.master.gainDB
            }
        }, set: { presentation.setFader($0, bus: bus) })
    }
    private var levels: [MixerConsoleLevel] { presentation.controller?.consoleMeters.levels[bus] ?? [] }

    var body: some View {
        MixerStripHeightLayout(minimumHeight: minimumHeight) { stripContent }
            .background(.quaternary.opacity(bus == .master ? 0.6 : 0.2))
            .overlay(alignment: .trailing) { Rectangle().fill(.separator).frame(width: 1) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(name) mixer strip")
            .accessibilityIdentifier(identifier)
    }

    private var stripContent: some View {
        VStack(spacing: 0) {
            Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 32).padding(.horizontal, 6)
                .background(color.opacity(0.2))
                .help(name).accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("\(identifier).name")
            VStack(spacing: 8) {
                identity
                HStack(spacing: 6) {
                    if bus != .master {
                        Toggle(isOn: listening(solo: true)) {
                            Text("S").foregroundStyle(listening(solo: true).wrappedValue ? Color.black : Color.primary)
                        }.tint(.yellow)
                            .accessibilityLabel("Solo \(name)").accessibilityIdentifier("\(identifier).solo")
                    }
                    Toggle(isOn: listening(solo: false)) {
                        Text("M").foregroundStyle(listening(solo: false).wrappedValue ? Color.black : Color.primary)
                    }.tint(.orange)
                        .accessibilityLabel("Mute \(name)").accessibilityIdentifier("\(identifier).mute")
                }
                .toggleStyle(.button).controlSize(.small).frame(height: 24)
                inputGain.frame(height: 96)
                Divider()
                MixerConsoleRack(presentation: presentation, bus: bus)
                Divider()
                pan.frame(height: 96)
                output
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 12)
        }
    }

    private var identity: some View {
        Button { showingInput.toggle() } label: {
            HStack(spacing: 5) {
                if let speaker, let appearance {
                    SpeakerAvatarView(name: speaker.name, appearance: appearance, size: 28)
                } else {
                    Image(systemName: bus == .master ? "speaker.wave.2.fill" : "waveform")
                        .font(.title3).foregroundStyle(color).frame(width: 28, height: 28)
                }
                if inputWarning != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain).frame(height: 30)
        .accessibilityLabel("\(name) input information\(speaker == nil ? "" : " and appearance")\(inputWarning.map { ": \($0)" } ?? "")")
        .accessibilityIdentifier("\(identifier).input")
        .help(inputWarning ?? inputDescription)
        .popover(isPresented: $showingInput) {
            VStack(alignment: .leading, spacing: 8) {
                Text(name).font(.headline)
                Text(inputDescription).textSelection(.enabled)
                if let inputWarning { Text(inputWarning).foregroundStyle(.red) }
                if let speaker, let state = presentation.state, let episode = presentation.episode {
                    Divider()
                    SpeakerAppearanceEditor(store: state.store, episodeID: episode.id, speakerID: speaker.id,
                                            showsHostMembership: false)
                        .disabled(!canEdit)
                }

            }.padding(16).frame(width: 300)
        }
    }

    private var inputWarning: String? {
        guard case .speaker(let id) = bus else { return nil }
        guard let episode = presentation.episode, let assignment = episode.assignment(for: id),
              let primary = assignment.primary, episode.source(primary.sourceID) != nil else {
            return "No Primary selected. Choose and confirm one in Recordings & Speakers."
        }
        if primary.resolvedChannel(in: episode) == nil {
            return "Choose an explicit input channel in Recordings & Speakers."
        }
        return assignment.primaryConfirmation == .userConfirmed ? nil : "Confirm this Primary before production listening."
    }

    private var inputDescription: String {
        if case .speaker(let id) = bus, let episode = presentation.episode,
           let primary = episode.assignment(for: id)?.primary, let source = episode.source(primary.sourceID) {
            let channel = primary.resolvedChannel(in: episode).map { "Channel \($0 + 1)" } ?? "Channel unresolved"
            return "Primary: \(source.displayNameHint)\n\(channel)\nInput gain is applied before inserts; the original recording is unchanged."
        }
        return bus == .master ? "Stereo program sum. Master gain follows its inserts." : "Stereo clip sum. Balance attenuates the opposite channel; center preserves both channels."
    }

    @ViewBuilder private var inputGain: some View {
        if case .speaker(let id) = bus, let episode = presentation.episode,
           let primary = episode.assignment(for: id)?.primary,
           let channel = primary.resolvedChannel(in: episode), let store = presentation.state?.store {
            MixerConsoleDial(title: "Input Gain", value: Binding(
                get: { presentation.mix.inputGainDB(for: primary.sourceID, channel: channel) },
                set: { store.setRecordingInputGain($0, reference: .init(sourceID: primary.sourceID, statedChannel: channel),
                                                  in: episode.id) }),
                range: EpisodeMixState.gainRangeDB, identifier: "\(identifier).inputGain", endEditing: endEditing)
                .disabled(!canEdit)
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    @ViewBuilder private var pan: some View {
        switch bus {
        case .speaker(let id):
            MixerConsoleDial(title: "Pan", value: Binding(get: { presentation.mix.state(for: id).pan },
                set: { presentation.setPan($0, speaker: id) }), range: -1...1,
                identifier: "\(identifier).pan", endEditing: endEditing).disabled(!canEdit)
        case .audioTrack(let id):
            MixerConsoleDial(title: "Balance", value: Binding(get: { presentation.mix.state(for: id).balance },
                set: { presentation.setBalance($0, track: id) }), range: -1...1,
                identifier: "\(identifier).balance", endEditing: endEditing).disabled(!canEdit)
        case .master:
            Color.clear.accessibilityHidden(true)
        }
    }

    private var output: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                MixerNumberControl(title: "Output (dB)", value: gain, range: EpisodeMixState.gainRangeDB,
                    identifier: "\(identifier).gain", endEditing: endEditing, compact: true)
                    .disabled(!canEdit)
                Button {
                    presentation.controller?.resetMeterPeaks(for: bus)
                } label: {
                    let peak = levels.map(\.heldPeakDB).max() ?? -.infinity
                    Text(peak.isFinite ? String(format: "%.1f", peak) : "--")
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                        .foregroundStyle(levels.contains(where: \.clipped) ? .red : .secondary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain).accessibilityLabel("Reset held peak and clip indicator")
                .accessibilityIdentifier("\(identifier).peak")
                .help("Held sample peak in dBFS. Click to reset the peak and latched overload.")
            }
            HStack(spacing: 8) {
                MixerConsoleFader(value: gain, identifier: identifier, endEditing: endEditing).disabled(!canEdit)
                MixerConsoleMeterView(levels: levels, updatedAt: presentation.controller?.metersUpdatedAt ?? .now,
                                      playing: presentation.controller?.state == .playing,
                                      identifier: "\(identifier).level")
            }
            Text("dB / dBFS").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func endEditing() { presentation.state?.store.endCoalescing() }

    private func listening(solo: Bool) -> Binding<Bool> {
        Binding(get: {
            guard let controller = presentation.controller else { return false }
            switch bus {
            case .speaker(let id): return (solo ? controller.soloedSpeakers : controller.mutedSpeakers).contains(id)
            case .audioTrack(let id): return (solo ? controller.soloedAudioTracks : controller.mutedAudioTracks).contains(id)
            case .master: return controller.masterMuted
            }
        }, set: { value in
            guard let controller = presentation.controller else { return }
            switch bus {
            case .speaker(let id):
                if solo {
                    if value { controller.soloedSpeakers.insert(id) } else { controller.soloedSpeakers.remove(id) }
                } else {
                    if value { controller.mutedSpeakers.insert(id) } else { controller.mutedSpeakers.remove(id) }
                }
            case .audioTrack(let id):
                if solo {
                    if value { controller.soloedAudioTracks.insert(id) } else { controller.soloedAudioTracks.remove(id) }
                } else {
                    if value { controller.mutedAudioTracks.insert(id) } else { controller.mutedAudioTracks.remove(id) }
                }
            case .master: controller.masterMuted = value
            }
        })
    }
}

private struct MixerStripHeightLayout: Layout {
    let minimumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let intrinsic = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? intrinsic.width, height: max(minimumHeight, intrinsic.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
