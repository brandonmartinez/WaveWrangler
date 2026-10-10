import Foundation
import WWAlignPipeline
import WWCore
import WWDecode
import WWDerived
import WWSources
import WWTimeMap

enum PrimaryPCMRefusal: Error, Equatable {
    case selectionChanged
    case accessMissing
    case accessChanged
    case sourceUnverified
    case sourceChanged
    case unmappedPrimary
    case decodedSourceMismatch
}

/// App-owned, synthetic-only integration of a registered ShowDocument and the live selected speaker
/// with the decoder's checked-descriptor reader. No production call site or model entry point exists:
/// a selected row and a bookmark do not themselves grant transcription of arbitrary recordings.
/// Document, decode and window failures propagate separately from PrimaryPCMRefusal; no caller may
/// interpret a returned failure as permission to use another source or to infer without a model gate.
@MainActor
enum OpenSelectedPrimaryPCMSource {
    #if DEBUG
    static func issueSynthetic(
        for setup: EpisodeSetupModel, accessStore: any DeviceAccessSnapshotStore,
        access: SourceAccessContext = SourceAccessContext()
    ) async throws -> WitnessBoundPCMWindow {
        try Task.checkCancellation()
        guard let document = setup.store.document,
              let state = ShowWindowRegistry.state(for: setup.window()),
              let selection = setup.captureSelectedPrimaryTranscriptReviewBinding()
        else { throw PrimaryPCMRefusal.selectionChanged }
        let documentBinding = try OpenShowSourceBinding.capture(for: document)
        func checkSelection() throws {
            try Task.checkCancellation()
            try documentBinding.requireOpenAndUnchanged()
            guard state.isCurrentSelectedPrimaryTranscript(selection) else {
                throw PrimaryPCMRefusal.selectionChanged
            }
        }
        try checkSelection()
        let initial = try await documentBinding.current()
        try checkSelection()
        let mapped = try mappedWindow(model: initial.model, selection: selection)
        let key = DeviceAccessKey(showID: selection.showID, sourceID: selection.primary.sourceID)
        let original = try await accessStore.snapshot(for: key)
        try checkSelection()
        guard let original else { throw PrimaryPCMRefusal.accessMissing }
        guard original.mutationGeneration != nil else { throw PrimaryPCMRefusal.accessChanged }
        let record = original.record
        guard record.key == key,
              let confirmed = record.recordedIdentity,
              confirmed.confirmation == .userConfirmed,
              let witness = confirmed.rawWitness,
              let bookmark = record.bookmark
        else { throw PrimaryPCMRefusal.sourceUnverified }
        guard case let .resolved(url, isStale) = access.io.resolveBookmark(bookmark), !isStale else {
            throw PrimaryPCMRefusal.sourceChanged
        }
        try requireAvailableSource(url, fingerprint: confirmed.fingerprint, access: access)
        let beforeRead = try await documentBinding.current()
        try checkSelection()
        guard try mappedWindow(model: beforeRead.model, selection: selection) == mapped else {
            throw PrimaryPCMRefusal.unmappedPrimary
        }
        let checked = try await accessStore.snapshot(for: key)
        try checkSelection()
        guard checked == original else { throw PrimaryPCMRefusal.accessChanged }
        try requireAvailableSource(url, fingerprint: confirmed.fingerprint, access: access)

        let window = try await WitnessBoundPCMWindowReader(access: access).read(
            url, source: key.sourceID, matching: witness,
            channel: mapped.channel, startFrame: mapped.firstFrame
        )
        try checkSelection()
        let afterRead = try await documentBinding.current()
        try checkSelection()
        guard try mappedWindow(model: afterRead.model, selection: selection) == mapped,
              window.sourceFrameCount == mapped.frameCount,
              window.channelCount == mapped.channelCount,
              confirmed.fingerprint.compare(to: window.sourceFingerprint) == .matches
        else { throw PrimaryPCMRefusal.decodedSourceMismatch }
        let final = try await accessStore.snapshot(for: key)
        try checkSelection()
        guard final == original else { throw PrimaryPCMRefusal.accessChanged }
        // A checked descriptor can have been valid during decoding even if its bookmarked location
        // was later replaced; never return that window as the current selected source.
        try requireAvailableSource(url, fingerprint: confirmed.fingerprint, access: access)
        try checkSelection()
        return window
    }

    private static func requireAvailableSource(
        _ url: URL, fingerprint: FileSystemFingerprint, access: SourceAccessContext
    ) throws {
        // Resolving a read-only bookmark is not enough to make its metadata accessible in an app
        // sandbox. Scope each metadata check just as the decoder scopes its later descriptor read.
        try access.withScopedAccess(to: url) { scopedURL in
            guard case let .success(metadata) = access.io.metadata(at: scopedURL),
                  metadata.isRegularFile.value == true,
                  metadata.isSymbolicLink.value != true,
                  metadata.isDataless.value == false,
                  metadata.volumeIsLocal.value == true,
                  metadata.ubiquitous.isDownloading.value != true,
                  metadata.ubiquitous.downloadingStatus.value != .notDownloaded,
                  fingerprint.compare(to: metadata.fingerprint) == .matches
            else { throw PrimaryPCMRefusal.sourceChanged }
        }
    }

    private struct MappedWindow: Equatable {
        let firstFrame: Int64
        let frameCount: Int64
        let channel: Int
        let channelCount: Int
        let epoch: RecordingEpochID
    }

    private static func mappedWindow(
        model: ShowDocumentModel, selection: ShowWindowState.SelectedPrimaryTranscriptBinding
    ) throws -> MappedWindow {
        guard model.schemaVersion == SchemaVersion.show,
              model.episodes.filter({ $0.id == selection.episodeID }).count == 1,
              model.speakers.filter({ $0.id == selection.speakerID }).count == 1,
              let episode = model.episode(selection.episodeID),
              episode.speakerAssignments.filter({ $0.speakerID == selection.speakerID }).count == 1,
              let assignment = episode.assignment(for: selection.speakerID),
              assignment.primary == selection.primary, assignment.primaryConfirmation == .userConfirmed,
              !assignment.backups.contains(selection.primary),
              episode.speakerAssignments.filter({ $0.primary == selection.primary }).count == 1,
              episode.sources.filter({ $0.id == selection.primary.sourceID }).count == 1,
              let source = episode.source(selection.primary.sourceID),
              source.role == .primary, source.roleConfirmation == .userConfirmed,
              let channel = selection.primary.channel.value, channel >= 0,
              let channelCount = source.observations.channelCount.value, channel < channelCount,
              source.observations.sampleRate.value == Double(WitnessBoundPCMWindowReader.sampleRate),
              let revision = episode.alignment?.acceptedRevision,
              let version = episode.alignment?.map(revision: revision),
              version.inputs.sources.filter({ $0.sourceID == source.id }).count == 1,
              version.inputs.sources.first(where: { $0.sourceID == source.id })?
                  .formatInterpretationVersion == FormatInterpretation.currentVersion,
              let applicable = try? episode.applicability(ofMapRevision: revision),
              applicable.isCurrent,
              let map = try? model.timeMap(revision: revision, in: selection.episodeID)
        else { throw PrimaryPCMRefusal.unmappedPrimary }
        let placements = map.groups.flatMap { group in group.placements.map { (group, $0) } }
            .filter { $0.1.occurrence.source == source.id }
        guard placements.count == 1, let located = placements.first else {
            throw PrimaryPCMRefusal.unmappedPrimary
        }
        let (group, placement) = located
        guard source.placement.recorderGroupID == group.group,
              let epoch = source.placement.epochID,
              placement.spans.count == 1,
              let span = placement.spans.first, span.epoch == epoch,
              span.startFrame == 0,
              span.endFrame == placement.occurrence.frameCount,
              span.endFrame >= Int64(WitnessBoundPCMWindowReader.frameCount),
              placement.occurrence.nominalRate.framesPerSecond == Int64(WitnessBoundPCMWindowReader.sampleRate),
              group.epochs.contains(where: {
                  guard $0.epoch == epoch, case .mapped = $0.mapping else { return false }
                  return true
              })
        else { throw PrimaryPCMRefusal.unmappedPrimary }
        return MappedWindow(
            firstFrame: span.startFrame, frameCount: placement.occurrence.frameCount,
            channel: channel, channelCount: channelCount, epoch: epoch
        )
    }
    #endif
}
