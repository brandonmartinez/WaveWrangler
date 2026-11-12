import AppKit
import SwiftUI
import WWCore
import WWExport

struct EpisodeExportSheet: View {
    @Bindable var model: EpisodeExportPresentation
    let document: ShowDocument
    @State private var metadataExpanded = false
    @State private var choosingArtwork = false
    @State private var confirmingCancel = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export Episode").font(.headline)
                    Text(model.resolved?.title ?? "Episode unavailable").foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }.padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result = model.result {
                        completion(result)
                    } else if model.isRunning {
                        progress
                    } else {
                        range
                        formatOptions
                        normalization
                        destination
                        metadata
                        omissions
                    }
                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("ww.export.message")
                    }
                }.padding()
            }.accessibilityIdentifier("ww.export.scroll")
            Divider()
            footer.padding()
        }
        .frame(width: 660, height: 620)
        .interactiveDismissDisabled(model.isRunning)
        .accessibilityIdentifier("ww.export.sheet")
        .task(id: document.store.modelGeneration) { await model.prepare() }
        .confirmationDialog("Cancel this export?", isPresented: $confirmingCancel) {
            Button("Cancel Export", role: .destructive) { model.cancel() }
            Button("Keep Exporting", role: .cancel) {}
        } message: {
            Text("Wait for cleanup before closing. Any files already published remain in the destination.")
        }
        .fileImporter(isPresented: $choosingArtwork, allowedContentTypes: [.jpeg, .png]) { result in
            switch result {
            case .success(let url): model.importArtwork(url)
            case .failure(let error): model.message = EpisodeExportWording.error(error)
            }
        }
    }

    private var range: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let frames = model.frames {
                HStack(spacing: 24) {
                    time("Episode Start", frames.lowerBound)
                    time("Episode End", frames.upperBound)
                    time("Duration", frames.upperBound - frames.lowerBound)
                }
                .accessibilityIdentifier("ww.export.range")
                Text("Whole production episode, including edits and mixer effects. No additional tail.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if model.preparing {
                ProgressView("Resolving Episode Start and End…").controlSize(.small)
            } else {
                Text(model.preparationError ?? "Episode range unavailable. Review Episode Start and End in the editor.")
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }

    private func time(_ title: String, _ frames: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.3f s", Double(frames) / 48_000)).monospacedDigit()
        }
    }

    private var formatOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Formats").font(.headline)
            HStack(spacing: 24) {
                ForEach(EpisodeExportFormat.allCases) { format in
                    Toggle(format.title, isOn: Binding(
                        get: { model.options.formats.contains(format) },
                        set: { enabled in
                            if enabled { model.options.formats.insert(format) }
                            else { model.options.formats.remove(format) }
                        }))
                        .accessibilityIdentifier("ww.export.format.\(format.rawValue)")
                }
            }
            if model.options.formats.contains(.wave) {
                GroupBox("WAV / PCM") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Bit depth", selection: $model.options.waveBits) {
                                Text("16-bit").tag(16)
                                Text("24-bit").tag(24)
                                Text("32-bit float").tag(32)
                            }.accessibilityIdentifier("ww.export.wave.bits")
                            ratePicker($model.options.waveRate, highRates: true, id: "wave")
                            channelPicker($model.options.waveChannels, id: "wave")
                        }
                        if model.options.waveBits != 32 {
                            Picker("Dither", selection: $model.options.waveDither) {
                                Text("None").tag(false)
                                Text("TPDF").tag(true)
                            }.frame(maxWidth: 250).accessibilityIdentifier("ww.export.wave.dither")
                        } else {
                            Text("Float32 preserves finite levels above 0 dBFS when normalization is off. Other players may clip.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(4)
                }
            }
            if model.options.formats.contains(.mp3) {
                GroupBox("MP3") {
                    VStack(spacing: 8) {
                        HStack {
                            Picker("Mode", selection: $model.options.mp3VBR) {
                                Text("Constant bitrate").tag(false)
                                Text("Variable bitrate").tag(true)
                            }.accessibilityIdentifier("ww.export.mp3.mode")
                            if model.options.mp3VBR {
                                Picker("Quality", selection: $model.options.mp3Quality) {
                                    ForEach(0...9, id: \.self) {
                                        Text($0 == 0 ? "0 (highest)" : $0 == 9 ? "9 (lowest)" : "\($0)").tag($0)
                                    }
                                }.accessibilityIdentifier("ww.export.mp3.quality")
                            } else {
                                bitratePicker($model.options.mp3Bitrate, values: EpisodeExportOptions.mp3Bitrates, id: "mp3")
                            }
                        }
                        HStack {
                            ratePicker($model.options.mp3Rate, highRates: false, id: "mp3")
                            channelPicker($model.options.mp3Channels, id: "mp3")
                        }
                    }.padding(4)
                }
            }
            if model.options.formats.contains(.m4a) {
                GroupBox("M4A / AAC-LC") {
                    HStack {
                        bitratePicker($model.options.aacBitrate, values: EpisodeExportOptions.aacBitrates, id: "m4a")
                        ratePicker($model.options.aacRate, highRates: false, id: "m4a")
                        channelPicker($model.options.aacChannels, id: "m4a")
                    }.padding(4)
                }
            }
        }
    }

    private func ratePicker(_ binding: Binding<Int>, highRates: Bool, id: String) -> some View {
        Picker("Sample rate", selection: binding) {
            Text("44.1 kHz").tag(44_100)
            Text("48 kHz").tag(48_000)
            if highRates {
                Text("88.2 kHz").tag(88_200)
                Text("96 kHz").tag(96_000)
            }
        }.accessibilityIdentifier("ww.export.\(id).rate")
    }

    private func channelPicker(_ binding: Binding<Int>, id: String) -> some View {
        Picker("Channels", selection: binding) {
            Text("Mono").tag(1)
            Text("Stereo").tag(2)
        }.accessibilityIdentifier("ww.export.\(id).channels")
    }

    private func bitratePicker(_ binding: Binding<Int>, values: [Int], id: String) -> some View {
        Picker("Bitrate", selection: binding) {
            ForEach(values, id: \.self) { Text("\($0) kbps").tag($0) }
        }.accessibilityIdentifier("ww.export.\(id).bitrate")
    }

    private var normalization: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Loudness normalization", selection: $model.options.normalization) {
                Text("Off (preserve levels)").tag(EpisodeExportOptions.Normalization.off)
                Text("Podcast").tag(EpisodeExportOptions.Normalization.podcast)
                Text("Custom").tag(EpisodeExportOptions.Normalization.custom)
            }.accessibilityIdentifier("ww.export.normalization")
            if model.options.normalization == .custom {
                HStack {
                    TextField("Target LUFS", value: $model.options.targetLUFS, format: .number)
                        .accessibilityIdentifier("ww.export.targetLUFS")
                    TextField("Ceiling dBTP", value: $model.options.ceilingDBTP, format: .number)
                        .accessibilityIdentifier("ww.export.ceilingDBTP")
                }.textFieldStyle(.roundedBorder)
            }
            Text(model.options.normalization == .off
                 ? "Integer WAV, MP3, and AAC require headroom; overload stops export rather than clipping."
                 : "Podcast: −16 LUFS stereo / −19 LUFS mono, −1 dBTP ceiling. Fixed gain, not a limiter; peaks or the +24 dB boost cap may prevent reaching a target.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Base filename", text: $model.baseName).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ww.export.filename")
            Text(EpisodeExportFormat.allCases.filter { model.options.formats.contains($0) }
                .map { "\(model.baseName).\($0.fileExtension)" }.joined(separator: ", "))
                .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(model.directory?.path ?? "No export folder selected")
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .help(model.directory?.path ?? "Choose a destination folder")
                    .accessibilityIdentifier("ww.export.directory")
                Spacer()
                Button("Choose Folder…") { model.chooseDirectory() }
                    .accessibilityIdentifier("ww.export.chooseDirectory")
            }
            Text("Existing files are never replaced. For another export, choose a different base name or folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var metadata: some View {
        DisclosureGroup("Metadata & Artwork (export only)", isExpanded: $metadataExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Starts with the episode's resolved publication information. Edits here affect only this export, not the show. Private Notes are never included.")
                    .font(.caption).foregroundStyle(.secondary)
                exportText("Title", value: $model.titleOverride, inherited: model.resolved?.title, id: "title")
                exportText("Album / show", value: $model.albumOverride, inherited: model.resolved?.album, id: "album")
                exportText("Creator / artist", value: $model.overrides.creator, inherited: model.resolved?.metadata.creator, id: "artist")
                exportText("Public description", value: $model.overrides.publicDescription,
                           inherited: model.resolved?.metadata.publicDescription, id: "description", multiline: true)
                exportText("Copyright", value: $model.overrides.copyright, inherited: model.resolved?.metadata.copyright, id: "copyright")
                exportText("Genre", value: $model.overrides.genre, inherited: model.resolved?.metadata.genre, id: "genre")
                exportText("Publication date (YYYY-MM-DD)", value: $model.dateOverride,
                           inherited: model.resolved?.publicationDate?.description, id: "date")
                exportText("Episode number", value: $model.episodeNumberOverride,
                           inherited: model.resolved?.episodeNumber.map(String.init), id: "number")
                HStack(alignment: .top, spacing: 12) {
                    if let artwork = model.artwork, let image = NSImage(data: artwork.data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 72, height: 72)
                            .accessibilityLabel("Export artwork")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.artwork == nil ? "No artwork" : "Artwork: \(model.artwork?.pixelWidth ?? 0) × \(model.artwork?.pixelHeight ?? 0)")
                        Text(model.overrides.artwork == nil ? "Inherited publication artwork" : "Export-only artwork selection")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Choose Image…") { choosingArtwork = true }
                            Button("Omit") { model.overrides.artwork = PublicationArtworkSelection.none }
                            Button("Inherit") { model.overrides.artwork = nil }
                        }
                        Text("Original JPEG/PNG; embedded artwork must be at most 8 MiB. No automatic shrinking.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(model.importingArtwork)
                if model.importingArtwork { ProgressView("Importing artwork…").controlSize(.small) }
                Text("Reusable defaults belong in the existing Show / Episode Info Publication sections.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
        .accessibilityIdentifier("ww.export.metadata")
    }

    private func exportText(_ label: String, value: Binding<String?>, inherited: String?, id: String,
                            multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text(value.wrappedValue == nil ? "Inherited" : value.wrappedValue == "" ? "Omitted" : "Export only")
                    .font(.caption).foregroundStyle(.secondary)
                if value.wrappedValue != nil { Button("Inherit") { value.wrappedValue = nil }.font(.caption) }
                Button("Omit") { value.wrappedValue = "" }.font(.caption)
            }
            TextField(label, text: Binding(get: { value.wrappedValue ?? inherited ?? "" },
                                         set: { value.wrappedValue = $0 }), axis: multiline ? .vertical : .horizontal)
                .textFieldStyle(.roundedBorder).lineLimit(multiline ? 3...8 : 1...1)
                .accessibilityIdentifier("ww.export.metadata.\(id)")
        }
    }

    @ViewBuilder private var omissions: some View {
        switch omissionPreview {
        case .success(let previews):
            let omissions = Set(previews.flatMap { $0.preview.omissions })
            if !omissions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Metadata omissions").font(.headline)
                    ForEach(previews, id: \.format) { item in
                        if !item.preview.omissions.isEmpty {
                            Text(item.format.title).fontWeight(.medium)
                            ForEach(item.preview.omissions.sorted { $0.field < $1.field }, id: \.self) { omission in
                                Text("\(omission.field): \(omission.reason)")
                                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Toggle("I accept the listed metadata omissions for all selected formats", isOn: Binding(
                        get: { omissions.isSubset(of: model.acceptedOmissions) },
                        set: { model.acceptedOmissions = $0 ? omissions : [] }))
                        .accessibilityIdentifier("ww.export.acceptOmissions")
                }
            }
        case .failure(let error):
            Text(EpisodeExportWording.error(error)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var omissionPreview: Result<[(format: EpisodeExportFormat, preview: ExportMetadataPreview)], Error> {
        Result { try model.previews }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            let value = model.service?.progress
            Text(value.map { EpisodeExportWording.phase($0.phase) } ?? "Preparing export…")
                .font(.headline).accessibilityIdentifier("ww.export.progress.phase")
            if let value, value.totalFrames > 0 {
                ProgressView(value: Double(value.completedFrames), total: Double(value.totalFrames))
            } else {
                ProgressView().controlSize(.small)
            }
            Text("Outputs: " + EpisodeExportFormat.allCases.filter { model.options.formats.contains($0) }
                .map(\.title).joined(separator: ", "))
            Text("You can cancel. Keep this window open until verification and cleanup finish.")
                .foregroundStyle(.secondary)
        }
    }

    private func completion(_ result: ExportJobResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(EpisodeExportWording.resultTitle(result)).font(.headline)
                .accessibilityIdentifier("ww.export.result")
            if let problem = result.problem {
                Text(problem.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(result.cleanupErrors, id: \.self) { error in
                Text("Cleanup problem: \(error)").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !result.succeeded {
                Text("Only the files listed below were published. Nothing was overwritten. For collisions, use a different base name or folder.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(result.published, id: \.url) { file in
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.url.lastPathComponent).fontWeight(.medium).textSelection(.enabled)
                    Text(EpisodeExportWording.loudness(file.loudness)).font(.caption)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text("Encoder input: \(file.inputFrames) frames; decoded: \(file.decodedFrames) frames; \(file.byteCount) bytes.")
                        .font(.caption).foregroundStyle(.secondary)
                    if file.settings.codec.fileExtension != "wav" {
                        Text("Lossy decoding may include encoder priming or padding; decoded duration is not exact production timing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        Button("Open") {
                            if !NSWorkspace.shared.open(file.url) {
                                model.message = "No application could open \(file.url.lastPathComponent). Reveal it in Finder instead."
                            }
                        }
                    }
                }
                Divider()
            }
        }
    }

    private var footer: some View {
        HStack {
            if !model.isRunning, model.result == nil, let reason = model.validationMessage {
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            }
            Spacer()
            if model.isRunning {
                Button("Cancel Export…") { confirmingCancel = true }
                    .accessibilityIdentifier("ww.export.cancel")
            } else {
                Button(model.result == nil ? "Cancel" : "Done") { model.dismiss() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("ww.export.close")
                if model.result == nil {
                    Button("Export") { model.start() }.keyboardShortcut(.defaultAction)
                        .disabled(model.validationMessage != nil)
                        .accessibilityIdentifier("ww.export.start")
                }
            }
        }
    }
}
