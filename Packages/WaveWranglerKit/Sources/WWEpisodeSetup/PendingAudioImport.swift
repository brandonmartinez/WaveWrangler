import Foundation
import WWCore
import WWSources

public enum AudioImportChoice: Hashable, Sendable {
    case newSource
    case reuse(source: SourceID)
    case copy(source: SourceID, episode: EpisodeID, title: String)
    case blocked(reason: String)

    public var canImport: Bool {
        if case .blocked = self { return false }
        return true
    }
}

public struct AudioImportScan: Sendable {
    public let scan: ImportScan
    public let choices: [UUID: AudioImportChoice]
}

/// Engine-owned authority, not a caller-created reuse permission or a persisted media registry.
public struct PendingAudioImport: Hashable, Sendable {
    fileprivate let id: UUID
    let scan: UUID
    fileprivate let candidate: UUID
    public let source: SourceID
    public let addsSource: Bool
    public let disposition: AudioImportChoice
}

public struct PendingAudioImportRead: Sendable {
    public let source: SourceRecord
    public let location: URL
    public let witness: RawSourceIdentity
    public let existingAsset: AudioAsset?
}

@MainActor
struct AudioImportSession {
    let snapshot: ShowDocumentModel
    let destination: EpisodeID
    let currentModel: @MainActor () throws -> ShowDocumentModel
    let matches: [UUID: [DeviceAccessSnapshot]]
    let choices: [UUID: AudioImportChoice]
}

struct PendingAudioState {
    let token: PendingAudioImport
    let newImport: PendingSourceImport?
    let origin: DeviceAccessSnapshot?
    let source: SourceRecord
    let asset: AudioAsset?
    let location: URL
    let witness: RawSourceIdentity
    let copiedRecord: DeviceAccessRecord?
    var adopting = false
}

extension WWSourcesSetupEngine {
    public func scanForAudioImport(
        _ urls: [URL], in destination: EpisodeID,
        currentModel: @escaping @MainActor () throws -> ShowDocumentModel
    ) async throws -> AudioImportScan {
        let snapshot = try currentModel()
        try requireAudioModel(snapshot, destination: destination)
        guard let snapshotStore = store as? any DeviceAccessSnapshotStore else {
            throw audioRefusal("This access store cannot safely review reusable audio.")
        }
        let allRecords = try await store.records(in: showID)
        try requireUnchanged(snapshot, currentModel: currentModel)
        let active = Set(snapshot.episodes.flatMap(\.sources).map(\.id))
        let records = allRecords.filter { active.contains($0.sourceID) }
        let importer = SourceImporter(context: context), show = showID
        let plan = try await Task.detached {
            try await importer.plan(selection: urls, showID: show, existingRecords: records, policy: .audioFilesOnly)
        }.value
        try requireUnchanged(snapshot, currentModel: currentModel)
        var matches: [UUID: [DeviceAccessSnapshot]] = [:]
        var choices: [UUID: AudioImportChoice] = [:]
        for item in plan.items {
            let id = item.sourceRecord.id.rawValue
            var snapshots: [DeviceAccessSnapshot] = []
            for record in physicalMatches(item, records: records) {
                guard let value = try await snapshotStore.snapshot(for: record.key), value.record == record else {
                    throw audioRefusal("Audio access changed during review. Choose the files again.")
                }
                try requireUnchanged(snapshot, currentModel: currentModel)
                snapshots.append(value)
            }
            matches[id] = snapshots
            if !hasCompleteAudioRoster(snapshot, records: records) {
                choices[id] = .blocked(reason: "An existing supplemental reference has missing or inconsistent asset/access data. Repair it in Recordings & Speakers before importing or reusing audio.")
            } else {
                let context = context
                let local = await Task.detached {
                    guard let bookmark = item.accessRecord.bookmark,
                          case let .resolved(url, stale) = context.io.resolveBookmark(bookmark), !stale else { return false }
                    return Self.isLocalAudioOriginal(url, context: context)
                }.value
                try requireUnchanged(snapshot, currentModel: currentModel)
                choices[id] = local ? choice(for: snapshots, model: snapshot, destination: destination)
                    : .blocked(reason: "This original is not fully local and accessible. Make it available explicitly, then choose it again; no download was requested.")
            }
        }
        let scan = ImportScan(candidates: plan.items.map {
            .init(id: $0.sourceRecord.id.rawValue,
                details: WWSourcesStatusMapping.details($0.accessRecord.recordedIdentity?.fingerprint,
                                                       path: $0.accessRecord.lastKnownPath),
                kind: .recording(typeFromNameOnly: true),
                alreadyInEpisode: $0.possibleDuplicates.contains { id in
                    snapshot.episode(destination)?.source(id) != nil
                })
        }, chosenDisplayName: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items",
            folderCount: 0, fileCount: plan.items.count,
            uncountedSkips: .init(
                notRecordings: [.projectOrSession, .transcriptOrDocument, .otherFile]
                    .reduce(0) { $0 + plan.skipped.byCategory[$1, default: 0] },
                hidden: plan.skipped.byCategory[.hidden, default: 0],
                unreadable: plan.skipped.unreadableEntries + plan.failures.count,
                duplicates: plan.skipped.duplicateSelections,
                folders: plan.skipped.byCategory[.directory, default: 0],
                symbolicLinks: plan.skipped.byCategory[.symbolicLink, default: 0]))
        plans[scan.token] = plan
        audioScans[scan.token] = .init(snapshot: snapshot, destination: destination,
            currentModel: currentModel, matches: matches, choices: choices)
        return .init(scan: scan, choices: choices)
    }

    public func preparePendingAudioImport(candidate: UUID, fromScan scan: UUID) async throws -> PendingAudioImport {
        let session = try audioSession(scan)
        guard let item = plans[scan]?.items.first(where: { $0.sourceRecord.id.rawValue == candidate }),
              let choice = session.choices[candidate], choice.canImport,
              !preparingAudio.contains(candidate),
              !pendingAudio.values.contains(where: { $0.token.scan == scan && $0.token.candidate == candidate }) else {
            throw audioRefusal("The audio selection is blocked, already preparing, or out of date. Review it again.")
        }
        preparingAudio.insert(candidate)
        defer { preparingAudio.remove(candidate) }
        let sourceID: SourceID
        let addsSource: Bool
        switch choice {
        case .newSource: sourceID = item.sourceRecord.id; addsSource = true
        case let .reuse(source): sourceID = source; addsSource = false
        case .copy: sourceID = item.sourceRecord.id; addsSource = true
        case let .blocked(reason): throw audioRefusal(reason)
        }
        let token = PendingAudioImport(id: UUID(), scan: scan, candidate: candidate,
                                       source: sourceID, addsSource: addsSource, disposition: choice)
        if choice == .newSource {
            try await validateNewAudioCandidate(candidate, scan: scan, publication: nil)
            let pending = try await preparePendingImport(candidate: candidate, fromScan: scan)
            do {
                _ = try audioSession(scan)
                let read = try await validatePendingImport(pending)
                _ = try audioSession(scan)
                pendingAudio[token.id] = .init(token: token, newImport: pending, origin: nil,
                    source: read.source, asset: nil, location: read.location, witness: read.witness, copiedRecord: nil)
            } catch {
                discardPendingImport(pending)
                throw error
            }
        } else {
            let originID: SourceID
            switch choice {
            case let .reuse(source), let .copy(source, _, _): originID = source
            default: throw audioRefusal("The reuse decision is no longer available.")
            }
            guard let origin = session.matches[candidate]?.first(where: { $0.record.sourceID == originID }),
                  let pair = canonicalSource(originID, in: session.snapshot),
                  var asset = pair.episode.audioArrangement?.assets.first(where: { $0.source == originID }) else {
                throw audioRefusal("The existing audio needs repair in Recordings & Speakers.")
            }
            let admitted = try await admitAudioOriginal(item: item, origin: origin, scan: scan, candidate: candidate)
            _ = try audioSession(scan)
            let source: SourceRecord
            let copy: DeviceAccessRecord?
            if addsSource {
                source = SourceRecord(id: sourceID, displayNameHint: item.sourceRecord.displayNameHint,
                                      purpose: .supplementalAudio)
                var record = item.accessRecord
                record.recordedIdentity = .init(fingerprint: admitted.fingerprint, confirmation: .userConfirmed,
                    recordedAt: context.now(), rawWitness: admitted.witness)
                copy = record
            } else {
                source = pair.source
                copy = nil
            }
            asset.source = sourceID
            pendingAudio[token.id] = .init(token: token, newImport: nil, origin: origin,
                source: source, asset: asset, location: admitted.location, witness: admitted.witness, copiedRecord: copy)
        }
        do {
            _ = try await validatePendingAudioImport(token)
            return token
        } catch {
            discardPendingAudioImport(token)
            throw error
        }
    }

    public func validatePendingAudioImport(_ token: PendingAudioImport) async throws -> PendingAudioImportRead {
        try await validateAudio(token, publication: nil)
    }

    public func discardPendingAudioImport(_ token: PendingAudioImport) {
        guard let state = pendingAudio[token.id], state.token == token else { return }
        if let pending = state.newImport { discardPendingImport(pending) }
        pendingAudio[token.id] = nil
    }

    public func adoptPendingAudioImports(
        _ tokens: [PendingAudioImport],
        validatingPublication: @escaping @MainActor () throws -> ShowDocumentModel
    ) async throws {
        guard let scan = tokens.first?.scan, tokens.allSatisfy({ $0.scan == scan }),
              Set(tokens).count == tokens.count else {
            throw audioRefusal("The reviewed audio batch is empty or duplicated.")
        }
        let publication = try validatingPublication()
        var records: [DeviceAccessRecord] = [], reads: [PendingSourceImportRead] = []
        for token in tokens {
            guard let state = pendingAudio[token.id], !state.adopting else {
                throw audioRefusal("The audio batch was already consumed.")
            }
            try validateAudioPublication(publication, tokens: tokens, scan: token.scan)
            let read = try await validateAudio(token, publication: publication)
            guard try validatingPublication() == publication else { throw audioRefusal("The audio publication changed.") }
            if token.addsSource {
                let record: DeviceAccessRecord
                if let pending = state.newImport { record = try consumePendingImport(pending) }
                else if let copy = state.copiedRecord { record = copy }
                else { throw audioRefusal("The copied audio access is incomplete.") }
                records.append(record)
                reads.append(.init(source: read.source, location: read.location, witness: read.witness))
            }
            pendingAudio[token.id]?.adopting = true
        }
        defer { for token in tokens { discardPendingAudioImport(token) } }
        let validateOrigins: @MainActor () async throws -> Void = { [self] in
            guard try validatingPublication() == publication else { throw audioRefusal("The audio publication changed.") }
            for token in tokens {
                if pendingAudio[token.id]?.origin != nil {
                    _ = try await validateAudio(token, publication: publication)
                } else {
                    try await validateNewAudioCandidate(token.candidate, scan: token.scan, publication: publication)
                }
                guard try validatingPublication() == publication else { throw audioRefusal("The audio publication changed.") }
            }
        }
        if records.isEmpty {
            // Reused-only batches must not enter the nonempty conditional-adoption API.
            try await validateOrigins()
        } else {
            try await adoptAudioRecords(records, reads: reads, validatingPublication: {
                guard try validatingPublication() == publication else { throw audioRefusal("The audio publication changed.") }
            }, validatingOrigins: validateOrigins)
        }
    }

    private func validateAudio(
        _ token: PendingAudioImport, publication: ShowDocumentModel?
    ) async throws -> PendingAudioImportRead {
        _ = try audioSession(token.scan, publication: publication)
        guard let state = pendingAudio[token.id], state.token == token else {
            throw audioRefusal("The pending audio was canceled, discarded, or closed.")
        }
        if let pending = state.newImport {
            let read = try await validatePendingImport(pending)
            _ = try audioSession(token.scan, publication: publication)
            try await validateNewAudioCandidate(token.candidate, scan: token.scan, publication: publication)
            return .init(source: read.source, location: read.location, witness: read.witness, existingAsset: nil)
        }
        guard let origin = state.origin,
              let item = plans[token.scan]?.items.first(where: { $0.sourceRecord.id.rawValue == token.candidate }) else {
            throw audioRefusal("The reusable original is no longer available.")
        }
        let read = try await admitAudioOriginal(item: item, origin: origin, scan: token.scan,
            candidate: token.candidate, publication: publication)
        guard pendingAudio[token.id]?.token == token, read.witness == state.witness else {
            throw audioRefusal("The original audio changed while preparing clips.")
        }
        if token.addsSource, try await store.record(for: .init(showID: showID, sourceID: token.source)) != nil {
            if !state.adopting { throw audioRefusal("The destination audio grant is occupied. Relink instead.") }
        }
        _ = try audioSession(token.scan, publication: publication)
        return .init(source: state.source, location: state.location, witness: state.witness, existingAsset: state.asset)
    }

    private func admitAudioOriginal(
        item: ImportedSource, origin: DeviceAccessSnapshot, scan: UUID, candidate: UUID,
        publication: ShowDocumentModel? = nil
    ) async throws -> (location: URL, witness: RawSourceIdentity, fingerprint: FileSystemFingerprint) {
        let session = try audioSession(scan, publication: publication)
        guard let snapshotStore = store as? any DeviceAccessSnapshotStore, let captureRawIdentity,
              let baseline = origin.record.recordedIdentity, baseline.confirmation == .userConfirmed,
              let recorded = baseline.rawWitness, recorded.isUsable,
              let bookmark = origin.record.bookmark,
              case let .resolved(url, stale) = context.io.resolveBookmark(bookmark), !stale,
              let droppedBookmark = item.accessRecord.bookmark,
              case let .resolved(dropped, droppedStale) = context.io.resolveBookmark(droppedBookmark), !droppedStale,
              let fingerprint = item.accessRecord.recordedIdentity?.fingerprint else {
            throw audioRefusal("The existing audio needs permission or identity repair in Recordings & Speakers. It was not regranted or duplicated.")
        }
        let expected = session.matches[candidate] ?? []
        let all = try await store.records(in: showID)
        _ = try audioSession(scan, publication: publication)
        let activeIDs = Set(session.snapshot.episodes.flatMap(\.sources).map(\.id))
        let matches = physicalMatches(item, records: all.filter { activeIDs.contains($0.sourceID) })
        guard hasCompleteAudioRoster(session.snapshot, records: all),
              Set(matches.map(\.key)) == Set(expected.map(\.record.key)),
              matches.allSatisfy({ record in
                  expected.contains { $0.record == record }
                      && canonicalSource(record.sourceID, in: session.snapshot)?.source.purpose == .supplementalAudio
              }) else {
            throw audioRefusal("The complete physical-source roster changed or includes a recording. Review the existing originals.")
        }
        for snapshot in expected {
            guard let current = try await snapshotStore.snapshot(for: snapshot.record.key),
                  current == snapshot, current.storeIdentity == snapshot.storeIdentity else {
                throw audioRefusal("Audio access was revoked, changed, or regranted. Review access before reusing it.")
            }
            _ = try audioSession(scan, publication: publication)
        }
        let context = context
        let (proposal, evaluation, local) = await Task.detached {
            let proposal = RelinkEvaluator(context: context).evaluate(candidate: dropped, for: item.accessRecord.key,
                record: item.accessRecord, otherRecords: all.filter { activeIDs.contains($0.sourceID) })
            let evaluation = SourceAvailabilityEvaluator(context: context).evaluate(
                key: origin.record.key, record: origin.record, setting: .off)
            return (proposal, evaluation, Self.isLocalAudioOriginal(dropped, context: context)
                    && Self.isLocalAudioOriginal(url, context: context))
        }.value
        _ = try audioSession(scan, publication: publication)
        guard proposal.canApply, proposal.comparison.isExactMatch,
              proposal.alreadyLinkedTo.map({ id in expected.contains { $0.record.sourceID == id } }) == true,
              local else {
            throw audioRefusal("The selected original changed, is a symlink, remote, unavailable, or no longer matches the reviewed asset.")
        }
        guard evaluation.refreshedRecord == nil, evaluation.resolvedURL == url,
              evaluation.observation.access == .granted, evaluation.observation.location == .present,
              evaluation.observation.identity == .matchesRecorded, evaluation.observation.residency == .local else {
            throw audioRefusal("The saved original needs explicit repair in Recordings & Speakers. No permission was changed.")
        }
        try await validateAudioOriginSnapshot(origin, scan: scan, publication: publication)
        let live = try await captureRawIdentity(url, baseline.fingerprint)
        _ = try audioSession(scan, publication: publication)
        guard recorded.matchesPersistentOriginal(live) else {
            throw audioRefusal("The admitted original no longer matches the verified audio asset.")
        }
        try await validateAudioCohort(item, expected: expected, scan: scan, publication: publication)
        try await validateAudioOriginSnapshot(origin, scan: scan, publication: publication)
        guard try await captureRawIdentity(dropped, fingerprint) == live else {
            throw audioRefusal("The dropped location no longer names the admitted original.")
        }
        _ = try audioSession(scan, publication: publication)
        for snapshot in expected {
            guard let current = try await snapshotStore.snapshot(for: snapshot.record.key),
                  current == snapshot, current.storeIdentity == snapshot.storeIdentity else {
                throw audioRefusal("Audio access changed while admitting the original.")
            }
            _ = try audioSession(scan, publication: publication)
        }
        try await validateAudioCohort(item, expected: expected, scan: scan, publication: publication)
        return (url, live, fingerprint)
    }

    private func validateAudioCohort(
        _ item: ImportedSource, expected: [DeviceAccessSnapshot], scan: UUID,
        publication: ShowDocumentModel?
    ) async throws {
        let session = try audioSession(scan, publication: publication)
        let records = try await store.records(in: showID)
        _ = try audioSession(scan, publication: publication)
        let activeIDs = Set(session.snapshot.episodes.flatMap(\.sources).map(\.id))
        let matches = physicalMatches(item, records: records.filter { activeIDs.contains($0.sourceID) })
        guard hasCompleteAudioRoster(session.snapshot, records: records),
              matches.count == expected.count,
              matches.allSatisfy({ record in expected.contains { $0.record == record } }) else {
            throw audioRefusal("The complete active physical-source cohort changed during audio admission.")
        }
    }

    private func validateNewAudioCandidate(
        _ candidate: UUID, scan: UUID, publication: ShowDocumentModel?
    ) async throws {
        let session = try audioSession(scan, publication: publication)
        guard session.choices[candidate] == .newSource,
              let item = plans[scan]?.items.first(where: { $0.sourceRecord.id.rawValue == candidate }) else {
            throw audioRefusal("The new-audio decision is no longer available.")
        }
        let records = try await store.records(in: showID)
        _ = try audioSession(scan, publication: publication)
        let active = Set(session.snapshot.episodes.flatMap(\.sources).map(\.id))
        let current = records.filter { active.contains($0.sourceID) }
        guard hasCompleteAudioRoster(session.snapshot, records: current),
              physicalMatches(item, records: current).isEmpty else {
            throw audioRefusal("The complete active source roster now references this original or needs repair. Review the files again.")
        }
    }

    private func validateAudioOriginSnapshot(
        _ expected: DeviceAccessSnapshot, scan: UUID, publication: ShowDocumentModel?
    ) async throws {
        guard let snapshots = store as? any DeviceAccessSnapshotStore,
              let current = try await snapshots.snapshot(for: expected.record.key),
              current == expected, current.storeIdentity == expected.storeIdentity else {
            throw audioRefusal("The saved audio permission changed before content admission.")
        }
        _ = try audioSession(scan, publication: publication)
    }

    private func choice(for matches: [DeviceAccessSnapshot], model: ShowDocumentModel,
                        destination: EpisodeID) -> AudioImportChoice {
        if matches.isEmpty { return .newSource }
        let pairs = matches.compactMap { canonicalSource($0.record.sourceID, in: model) }
        guard pairs.count == matches.count, pairs.allSatisfy({ $0.source.purpose == .supplementalAudio }) else {
            return .blocked(reason: "This original is an active recording. Recording aliases cannot become Audio Clips.")
        }
        guard matches.allSatisfy({ $0.record.recordedIdentity?.confirmation == .userConfirmed
            && $0.record.recordedIdentity?.rawWitness?.isUsable == true }),
              pairs.allSatisfy({ qualifiedAsset(for: $0.source, in: $0.episode) != nil }) else {
            return .blocked(reason: "An existing audio reference is provisional or unverified. Repair it in Recordings & Speakers before reusing it.")
        }
        let assets = pairs.compactMap { qualifiedAsset(for: $0.source, in: $0.episode) }
        guard let firstAsset = assets.first, assets.allSatisfy({
            $0.frameCount == firstAsset.frameCount && $0.sampleRate == firstAsset.sampleRate
                && $0.channelCount == firstAsset.channelCount
        }) else {
            return .blocked(reason: "The physical matches have inconsistent qualified audio geometry. Repair the existing references.")
        }
        if let local = pairs.first(where: { $0.episode.id == destination }) { return .reuse(source: local.source.id) }
        let first = pairs[0]
        return .copy(source: first.source.id, episode: first.episode.id, title: first.episode.title)
    }

    private func hasCompleteAudioRoster(_ model: ShowDocumentModel, records: [DeviceAccessRecord]) -> Bool {
        model.episodes.allSatisfy { episode in
            episode.supplementalAudioSources.allSatisfy { source in
                qualifiedAsset(for: source, in: episode) != nil && records.contains {
                    $0.sourceID == source.id && $0.recordedIdentity?.fingerprint.fileIdentifier.value != nil
                        && $0.recordedIdentity?.fingerprint.volumeUUID.value != nil
                }
            }
        }
    }

    private func qualifiedAsset(for source: SourceRecord, in episode: Episode) -> AudioAsset? {
        let assets = episode.audioArrangement?.assets.filter { $0.source == source.id } ?? []
        guard assets.count == 1, let asset = assets.first, asset.isValid,
              source.purpose == .supplementalAudio,
              source.observations.channelCount.value.map({ $0 == asset.channelCount }) != false,
              source.observations.sampleRate.value.map({ $0 == Double(asset.sampleRate) }) != false,
              source.observations.durationSeconds.value.map({
                  $0 == Double(asset.frameCount) / Double(asset.sampleRate)
              }) != false else { return nil }
        return asset
    }

    private func canonicalSource(_ id: SourceID, in model: ShowDocumentModel) -> (episode: Episode, source: SourceRecord)? {
        for episode in model.episodes {
            if let source = episode.source(id) { return (episode, source) }
        }
        return nil
    }

    private func physicalMatches(_ item: ImportedSource, records: [DeviceAccessRecord]) -> [DeviceAccessRecord] {
        guard let fingerprint = item.accessRecord.recordedIdentity?.fingerprint else { return [] }
        return SourceImporter.physicalMatches(for: fingerprint, in: records)
    }

    private nonisolated static func isLocalAudioOriginal(_ url: URL, context: SourceAccessContext) -> Bool {
        guard url.isFileURL,
              case let .success(metadata) = context.withScopedAccess(to: url, { context.io.metadata(at: $0) }) else { return false }
        return metadata.isRegularFile.value == true && metadata.isDirectory.value == false
            && metadata.isSymbolicLink.value == false && metadata.isDataless.value == false
            && metadata.isReadable.value == true
            && metadata.volumeIsLocal.value == true && metadata.residency.0 == .local
    }

    private func audioSession(_ scan: UUID, publication: ShowDocumentModel? = nil) throws -> AudioImportSession {
        try Task.checkCancellation()
        guard isRunning, plans[scan] != nil, let session = audioScans[scan] else {
            throw audioRefusal("The audio selection was canceled, discarded, or closed.")
        }
        let current = try session.currentModel()
        try requireAudioModel(current, destination: session.destination)
        guard current == (publication ?? session.snapshot) else {
            throw audioRefusal("The canonical audio destination changed. Review the files again.")
        }
        return session
    }

    private func validateAudioPublication(_ publication: ShowDocumentModel, tokens: [PendingAudioImport], scan: UUID) throws {
        guard let session = audioScans[scan], let episode = publication.episode(session.destination),
              let original = session.snapshot.episode(session.destination) else {
            throw audioRefusal("The published audio destination was removed.")
        }
        let added = Set(tokens.filter(\.addsSource).map(\.source))
        guard Set(episode.sources.map(\.id)) == Set(original.sources.map(\.id)).union(added),
              original.sources.allSatisfy({ episode.source($0.id) == $0 }),
              added.allSatisfy({ episode.source($0)?.purpose == .supplementalAudio }) else {
            throw audioRefusal("The published audio source roster does not match the reviewed batch.")
        }
        var restored = publication
        guard let index = restored.episodes.firstIndex(where: { $0.id == session.destination }) else {
            throw audioRefusal("The audio destination was removed.")
        }
        restored.episodes[index].sources = original.sources
        restored.episodes[index].audioArrangement = original.audioArrangement
        restored.episodes[index].mix = original.mix
        guard restored == session.snapshot else {
            throw audioRefusal("Unrelated canonical state changed during audio import.")
        }
    }

    private func requireAudioModel(_ model: ShowDocumentModel, destination: EpisodeID) throws {
        let ids = model.episodes.flatMap(\.sources).map(\.id)
        guard isRunning, model.show.id == showID, model.episode(destination) != nil, Set(ids).count == ids.count else {
            throw audioRefusal("The show/destination/source roster is unavailable or ambiguous.")
        }
    }

    private func requireUnchanged(_ snapshot: ShowDocumentModel,
                                  currentModel: @MainActor () throws -> ShowDocumentModel) throws {
        try Task.checkCancellation()
        guard isRunning, try currentModel() == snapshot else { throw audioRefusal("The destination changed during review.") }
    }

    private func audioRefusal(_ reason: String) -> SourceEngineError { .failed(reason: reason) }
}
