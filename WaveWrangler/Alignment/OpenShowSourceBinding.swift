import AppKit
import Foundation
import WWAlignPipeline
import WWCore
import WWPersistence

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

    private init(document: ShowDocument, url: URL, model: ShowDocumentModel, base: RevisionFingerprint) {
        self.document = document
        self.url = url
        self.model = model
        self.base = base
    }

    static func capture(for document: ShowDocument) throws -> OpenShowSourceBinding {
        guard let snapshot = document.currentSourcePublication else {
            throw EpisodeSourceAccessRefusal.changedDuringVerification
        }
        let binding = OpenShowSourceBinding(
            document: document, url: snapshot.url, model: snapshot.model, base: snapshot.base
        )
        try binding.requireOpenAndUnchanged()
        return binding
    }

    /// Synchronous main-actor check after all suspensions, including registration, unique ShowID, Save As,
    /// dirty state, model/base changes and closure. On-disk identity is checked separately by `current()`.
    func requireOpenAndUnchanged() throws {
        guard let document,
              let present = document.currentSourcePublication,
              present.url == url, present.model == model, present.base == base
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
