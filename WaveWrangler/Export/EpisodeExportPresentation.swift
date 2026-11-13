import AppKit
import Observation
import WWCommonEdit
import WWCore
import WWExport

/// One presentation per document; other windows cannot start a second sheet or orphan its task.
@MainActor @Observable
final class EpisodeExportPresentation {
    private weak var document: ShowDocument?
    private weak var owner: ShowWindowState?
    private(set) var episodeID: EpisodeID?
    private(set) var frames: Range<Int64>?
    private(set) var preparing = false
    private(set) var preparationError: String?
    private(set) var starting = false
    private(set) var importingArtwork = false
    private(set) var result: ExportJobResult?
    var message: String?
    var options = EpisodeExportOptions() { didSet { acceptedOmissions = [] } }
    var baseName = ""
    var directory: URL?
    var titleOverride: String? { didSet { acceptedOmissions = [] } }
    var albumOverride: String? { didSet { acceptedOmissions = [] } }
    var dateOverride: String? { didSet { acceptedOmissions = [] } }
    var episodeNumberOverride: String? { didSet { acceptedOmissions = [] } }
    var overrides = PublicationMetadata() { didSet { acceptedOmissions = [] } }
    var acceptedOmissions: Set<ExportMetadataOmission> = []
    @ObservationIgnored private var runtime: AlignmentRuntime?
    @ObservationIgnored private var preparedModel: ShowDocumentModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var presentationID = UUID()
    @ObservationIgnored private var preparationID = UUID()

    init(document: ShowDocument) { self.document = document }
    var service: EpisodeExportService? { document?.exportJobs }
    var isRunning: Bool { starting || service?.isRunning == true }
    var isPresented: Bool { owner != nil }
    var resolved: ResolvedPublicationMetadata? {
        guard let document, let episodeID else { return nil }
        return try? document.store.model.resolvedPublication(for: episodeID)
    }
    var artwork: PublicationArtwork? { overrides.artwork?.image ?? (overrides.artwork == nil ? resolved?.metadata.artwork?.image : nil) }

    func present(from state: ShowWindowState) {
        if let owner {
            owner.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard state.exportUnavailableReason == nil, let id = state.selectedEpisodeID, let document else { return }
        owner = state
        presentationID = UUID()
        episodeID = id
        options = .init()
        directory = nil
        baseName = EpisodeExportOptions.suggestedBaseName(state.selectedEpisode?.title ?? "Episode")
        titleOverride = nil; albumOverride = nil; dateOverride = nil; episodeNumberOverride = nil
        overrides = .init(); acceptedOmissions = []; result = nil; message = nil; preparationError = nil
        do {
            if let saved = try preferences(document).load() {
                options = saved.options
                directory = saved.directory
            }
        } catch { message = "Could not restore export choices: \(EpisodeExportWording.error(error))" }
        state.exportPresented = true
    }

    func dismiss() {
        guard !isRunning else { explainCloseBlock(); return }
        task?.cancel()
        artworkTask?.cancel()
        artworkTask = nil
        importingArtwork = false
        presentationID = UUID()
        preparationID = UUID()
        preparing = false
        owner?.exportPresented = false
        owner = nil
        runtime = nil
        preparedModel = nil
        frames = nil
    }

    func explainCloseBlock() {
        message = "This show is exporting. Use Cancel Export, wait for cleanup, then close the export sheet."
        owner?.window?.makeKeyAndOrderFront(nil)
    }

    func prepare() async {
        guard !isRunning, result == nil, let document, let episodeID else { return }
        let preparation = UUID()
        preparationID = preparation
        preparing = true
        preparationError = nil
        frames = nil
        preparedModel = nil
        acceptedOmissions = []
        defer { if preparationID == preparation { preparing = false } }
        let snapshot = document.store.model
        do {
            let active = try await AlignmentRuntimeProvider.runtime(for: document, episode: episodeID)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "WWUITestHooks"),
               UserDefaults.standard.bool(forKey: "WWUITestExportSlowValidation") {
                await active.setProductionValidationHookForTesting {
                    try await Task.sleep(for: .seconds(120))
                }
            }
            #endif
            let composition = try await active.programComposition(model: snapshot, episode: episodeID)
            guard let episode = snapshot.episode(episodeID),
                  let range = try EpisodeProductionProjection(episode: episode, composition: composition).episodeFrames,
                  !range.isEmpty else {
                throw ExportFailure.invalidSettings("Set a resolved Episode Start and Episode End before exporting.")
            }
            try Task.checkCancellation()
            guard preparationID == preparation, isPresented, snapshot == document.store.model else { return }
            runtime = active
            frames = range
            preparedModel = snapshot
        } catch is CancellationError {
            return
        } catch {
            if preparationID == preparation { preparationError = EpisodeExportWording.error(error) }
        }
    }

    func selections() throws -> [EpisodeExportDelivery] {
        guard let resolved else { throw ExportFailure.invalidMetadata("The episode is no longer available.") }
        guard !options.formats.isEmpty else { throw ExportFailure.invalidSettings("Select at least one format.") }
        return try EpisodeExportFormat.allCases.filter { options.formats.contains($0) }.map { format in
            var value = try options.delivery(format, baseName: baseName)
            value.titleOverride = titleOverride
            value.albumOverride = albumOverride
            value.dateOverride = dateOverride
            value.episodeNumberOverride = episodeNumberOverride
            value.overrides = overrides
            value.confirmedOmissions = acceptedOmissions
            _ = try ExportMetadataAdapter.preview(resolved, delivery: value)
            return value
        }
    }

    var previews: [(format: EpisodeExportFormat, preview: ExportMetadataPreview)] {
        get throws {
            guard let resolved else { throw ExportFailure.invalidMetadata("The episode is no longer available.") }
            return try selections().map {
                let format: EpisodeExportFormat
                switch $0.settings.codec {
                case .wave: format = .wave
                case .mp3: format = .mp3
                case .aacLC: format = .m4a
                }
                return (format, try ExportMetadataAdapter.preview(resolved, delivery: $0))
            }
        }
    }

    var allOmissions: Set<ExportMetadataOmission> {
        get throws { Set(try previews.flatMap { $0.preview.omissions }) }
    }

    var validationMessage: String? {
        guard !preparing, frames != nil else { return preparationError ?? "Waiting for a resolved episode range." }
        guard directory != nil else { return "Choose an export folder." }
        guard !importingArtwork else { return "Wait for artwork to finish importing." }
        do {
            let selections = try selections()
            guard let resolved else { return "The episode is no longer available." }
            for selection in selections { _ = try ExportMetadataAdapter.delivery(resolved, selection: selection) }
            return nil
        } catch { return EpisodeExportWording.error(error) }
    }

    func chooseDirectory() {
        guard !isRunning, let window = owner?.window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        let presentation = presentationID
        panel.beginSheetModal(for: window.attachedSheet ?? window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, self.presentationID == presentation, self.isPresented,
                      response == .OK, let url = panel.url else { return }
                self.directory = url
            }
        }
    }

    func importArtwork(_ url: URL) {
        guard !isRunning, !importingArtwork else { return }
        let presentation = presentationID
        importingArtwork = true
        artworkTask = Task {
            defer {
                if presentationID == presentation { importingArtwork = false; artworkTask = nil }
            }
            do {
                let image = try await PublicationArtworkImport.read(url)
                try Task.checkCancellation()
                guard presentationID == presentation else { return }
                overrides.artwork = .image(image)
            } catch is CancellationError {
                return
            } catch {
                if presentationID == presentation { message = EpisodeExportWording.error(error) }
            }
        }
    }

    func start() {
        guard !isRunning, validationMessage == nil, let document, let episodeID, let directory,
              let runtime, preparedModel == document.store.model else {
            message = "Export is not ready. Check the range, folder, and metadata omissions."
            return
        }
        do {
            let values = try selections()
            let savedOptions = options
            starting = true
            message = nil
            task = Task {
                defer { starting = false; task = nil }
                do {
                    let completed = try await document.exportJobs.run(episode: episodeID, runtime: runtime,
                        userSelectedDirectory: directory, deliveries: values)
                    result = completed
                    message = nil
                    do {
                        try preferences(document).save(savedOptions, directory: directory, succeeded: completed.succeeded)
                    } catch { message = "Files exported, but choices could not be remembered: \(EpisodeExportWording.error(error))" }
                } catch is CancellationError {
                    message = "Export canceled. No delivery result was returned."
                } catch { message = EpisodeExportWording.error(error) }
            }
        } catch { message = EpisodeExportWording.error(error) }
    }

    func cancel() {
        guard isRunning else { return }
        message = "Canceling export; waiting for cleanup."
        task?.cancel()
        Task { await service?.cancel() }
    }

    private func preferences(_ document: ShowDocument) -> EpisodeExportPreferenceStore {
        .init(defaults: PersistenceEnvironment.preferences, show: document.store.model.show.id)
    }
}

extension ShowWindowState {
    var exportUnavailableReason: String? {
        guard let document = store.document, let episode = selectedEpisode else { return "Open an episode to export it." }
        if document.exportInterface.isRunning { return "An export is already running for this show." }
        if document.exportInterface.isPresented { return "The export sheet is open in another window of this show." }
        if recordingsPresented { return "Close Recordings & Speakers before exporting." }
        if document.mixerTransactions.isClosed { return "This show is closing." }
        if document.verifiedModel?.hasSameMediaInputs(as: store.model, in: episode.id) != true {
            return "Save the show to verify its current recordings before exporting."
        }
        return nil
    }

    func requestExport() { store.document?.exportInterface.present(from: self) }
}
