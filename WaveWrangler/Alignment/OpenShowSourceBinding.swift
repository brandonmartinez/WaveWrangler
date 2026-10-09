import AppKit
import Foundation
import WWAlignPipeline
import WWCore
import WWDerived
import WWPersistence
import WWTimeMap

/// The only app-owned binding of a source inventory to the canonical document that AppKit actually has
/// open. Callers cannot provide a URL, model, base, stamp, or arbitrary document callback here.
/// The weak owner and identity checks prevent a copied file or another window with the same ShowID from
/// representing this open document. This is a short-lived readback, never a file or grant lease.
@MainActor
final class OpenShowSourceBinding {
    private weak var document: ShowDocument?
    private let url: URL
    private let model: ShowDocumentModel
    private let base: RevisionFingerprint
    private let mutationGeneration: UInt64

    private init(
        document: ShowDocument, url: URL, model: ShowDocumentModel,
        base: RevisionFingerprint, mutationGeneration: UInt64
    ) {
        self.document = document
        self.url = url
        self.model = model
        self.base = base
        self.mutationGeneration = mutationGeneration
    }

    static func capture(for document: ShowDocument) throws -> OpenShowSourceBinding {
        guard let snapshot = document.currentSourcePublication,
              let generation = document.store.captureMutationGeneration() else {
            throw EpisodeSourceAccessRefusal.changedDuringVerification
        }
        let binding = OpenShowSourceBinding(
            document: document, url: snapshot.url, model: snapshot.model, base: snapshot.base,
            mutationGeneration: generation
        )
        try binding.requireOpenAndUnchanged()
        return binding
    }

    /// Synchronous main-actor check after all suspensions, including registration, unique ShowID, Save As,
    /// dirty state, model/base changes and closure. On-disk identity is checked separately by `current()`.
    func requireOpenAndUnchanged() throws {
        guard let document,
              let present = document.currentSourcePublication,
              present.url == url, present.model == model, present.base == base,
              document.store.isCurrentMutationGeneration(mutationGeneration)
        else { throw EpisodeSourceAccessRefusal.changedDuringVerification }
        let matches = NSDocumentController.shared.documents
            .compactMap { $0 as? ShowDocument }
            .filter { $0.store.model.show.id == model.show.id }
        guard matches.count == 1, matches[0] === document else {
            throw EpisodeSourceAccessRefusal.changedDuringVerification
        }
    }

    /// Coordinated, whole-envelope read of the *bound* URL; a caller has no old-copy URL parameter.
    func current() async throws -> EpisodeSourceSurveyInput {
        try Task.checkCancellation()
        try requireOpenAndUnchanged()
        let url = self.url
        let model = self.model
        let base = self.base
        let document = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let opener = DocumentOpener(
                coder: JSONEnvelopeCoder<ShowDocumentModel>.show, recovery: nil,
                identityOf: { .show($0.show.id) }
            )
            guard case let .editable(decoded, fingerprint) = opener.open(
                url, key: .show(model.show.id)
            ), fingerprint == base, decoded.publication == base.publication,
               decoded.payload == model
            else { throw EpisodeSourceAccessRefusal.changedDuringVerification }
            try Task.checkCancellation()
            return EpisodeSourceSurveyInput(model: decoded.payload, publication: decoded.publication)
        }.value
        try Task.checkCancellation()
        try requireOpenAndUnchanged()
        return document
    }
}

enum SelectedPrimarySourceReadRefusal: Error, Equatable, Sendable {
    case selectionUnavailable
    case acceptedMapUnavailable
    case windowOutsideMappedEpoch
    case accessChanged
    case changedDuringVerification
    case trustedSourceOpenUnavailable
}

/// A future checked result; only the issuer may ever construct one.
struct SelectedPrimaryPCMWindow: Sendable {
    let channel: Int
    let sourceFrames: Range<Int64>
    let samples: [Float]

    private init(channel: Int, sourceFrames: Range<Int64>, samples: [Float]) {
        self.channel = channel
        self.sourceFrames = sourceFrames
        self.samples = samples
    }
}

/// App-only preparation; it cannot issue PCM. Neither the metadata inventory nor a cached access
/// record can authorize the decoder's open descriptor, so the last step remains an explicit refusal.
@MainActor
enum SelectedPrimarySourceReadIssuer {
    #if DEBUG
    enum Phase: Equatable {
        case afterIntentCapture
        case beforeDescriptorOpen
        case beforePublication
    }

    static var debugPhaseObserver: (@MainActor (Phase) async throws -> Void)?
    static var debugSourceOpenObserver: (@MainActor (SourceID) -> Void)?
    #endif

    static func readCheckedPrimaryWindow(
        for document: ShowDocument, in window: NSWindow, startingAt start: Int64
    ) async throws -> SelectedPrimaryPCMWindow {
        return try await requireSourceReadAuthority(for: document, in: window, startingAt: start)
    }

    static func requireSourceReadAuthority(
        for document: ShowDocument, in window: NSWindow, startingAt start: Int64
    ) async throws -> Never {
        try Task.checkCancellation()
        let binding = try OpenShowSourceBinding.capture(for: document)
        guard window.isKeyWindow,
              document.windowControllers.contains(where: { $0.window === window }),
              let state = ShowWindowRegistry.state(for: window),
              state.store === document.store, state.destination == .setup,
              let windowGeneration = state.captureSourceReadGeneration(),
              let controller = EpisodeSetupViewController.controller(for: window),
              controller.model.store === document.store,
              state.selectedEpisodeID == controller.model.episodeID
        else { throw SelectedPrimarySourceReadRefusal.selectionUnavailable }
        let selection = try controller.model.captureSelectedPrimarySource()
        let current = try await binding.current()
        try Task.checkCancellation()
        guard state.isCurrentSourceReadGeneration(windowGeneration),
              controller.model.isCurrentSelectedPrimarySource(selection) else {
            throw SelectedPrimarySourceReadRefusal.selectionUnavailable
        }
        try validatePortableMapWindow(
            model: current.model, selection: selection, startingAt: start
        )
        #if DEBUG
        try await debugPhaseObserver?(.afterIntentCapture)
        #endif
        _ = try await binding.current()
        try Task.checkCancellation()
        guard window.isKeyWindow, state.destination == .setup,
              state.selectedEpisodeID == selection.episode,
              state.isCurrentSourceReadGeneration(windowGeneration),
              EpisodeSetupViewController.controller(for: window) === controller,
              controller.model.isCurrentSelectedPrimarySource(selection)
        else { throw SelectedPrimarySourceReadRefusal.selectionUnavailable }
        throw SelectedPrimarySourceReadRefusal.trustedSourceOpenUnavailable
    }

    /// A portable-map shape check only; an active map/source revision and opened descriptor still need proof.
    static func validatePortableMapWindow(
        model: ShowDocumentModel, selection: SelectedPrimarySourceIntent, startingAt start: Int64
    ) throws {
        guard let episode = model.episode(selection.episode),
              let revision = episode.alignment?.acceptedRevision,
              let applicability = try? episode.applicability(ofMapRevision: revision),
              applicability.isCurrent,
              let map = try? model.timeMap(revision: revision, in: selection.episode),
              let source = episode.source(selection.channel.sourceID),
              source.placement.epochID == selection.epoch,
              let groupID = source.placement.recorderGroupID,
              let group = map.groups.first(where: { $0.group == groupID }),
              group.epochs.filter({ $0.epoch == selection.epoch }).count == 1,
              let epoch = group.epochs.first(where: { $0.epoch == selection.epoch }),
              case .mapped = epoch.mapping
        else { throw SelectedPrimarySourceReadRefusal.acceptedMapUnavailable }
        let placements = map.groups.flatMap { $0.placements.filter { $0.occurrence.source == source.id } }
        guard placements.count == 1, let placement = placements.first,
              group.placements.contains(where: { $0.occurrence.id == placement.occurrence.id }),
              placement.spans.count == 1, let span = placement.spans.first,
              span.epoch == selection.epoch, span.startFrame == 0,
              span.endFrame == placement.occurrence.frameCount,
              placement.occurrence.nominalRate.framesPerSecond == 16_000
        else { throw SelectedPrimarySourceReadRefusal.acceptedMapUnavailable }
        let (end, overflow) = start.addingReportingOverflow(32_000)
        guard !overflow, start >= 0, end <= span.endFrame else {
            throw SelectedPrimarySourceReadRefusal.windowOutsideMappedEpoch
        }
    }
}

/// An app-private, non-Codable snapshot. A package inventory alone can never produce this type.
/// No selected-source, protection, fade, cut, render, or atomic-publication authorization follows.
@MainActor
final class OpenEpisodeSourceSnapshot {
    let inventory: EpisodeSourceInventory
    private let binding: OpenShowSourceBinding
    private let surveyor: EpisodeSourceInventorySurveyor

    private init(
        inventory: EpisodeSourceInventory, binding: OpenShowSourceBinding,
        surveyor: EpisodeSourceInventorySurveyor
    ) {
        self.inventory = inventory
        self.binding = binding
        self.surveyor = surveyor
    }

    static func issue(
        for document: ShowDocument, episode: EpisodeID
    ) async throws -> OpenEpisodeSourceSnapshot {
        let binding = try OpenShowSourceBinding.capture(for: document)
        _ = try await binding.current()
        let runtime = try await AlignmentRuntimeProvider.runtime(for: document, episode: episode)
        try Task.checkCancellation()
        try binding.requireOpenAndUnchanged()
        let surveyor = EpisodeSourceInventorySurveyor(
            showID: document.store.model.show.id, coordinator: runtime.coordinator,
            accessStore: SetupEngineProvider.store, access: SetupEngineProvider.context
        )
        let inventory = try await surveyor.survey(episode: episode) { try await binding.current() }
        // The surveyor checks store/ready key after its last store read. A final coordinated
        // readback catches a show replaced during that store read. Neither is an atomic lease.
        try await surveyor.resurvey(inventory) { try await binding.current() }
        _ = try await binding.current()
        try Task.checkCancellation()
        try binding.requireOpenAndUnchanged()
        return OpenEpisodeSourceSnapshot(inventory: inventory, binding: binding, surveyor: surveyor)
    }

    /// Must be used after future awaits and before any hypothetical edit admission. Still not an
    /// authorization: independent protection/fade and an atomic map/history publication remain absent.
    func reverify() async throws {
        try await surveyor.resurvey(inventory) { try await binding.current() }
        _ = try await binding.current()
        try Task.checkCancellation()
        try binding.requireOpenAndUnchanged()
    }
}
