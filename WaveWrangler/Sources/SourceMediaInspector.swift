import Foundation
import WWCore
import WWDecode
import WWSources

actor SourceMediaInspector {
    private let access: SourceAccessContext
    private let records: AlignmentSourceAccess
    private let decoder: SourceDecoder
    private var cache: [SourceID: (fingerprint: FileSystemFingerprint, observations: SourceObservations)] = [:]

    init(accessStore: any DeviceAccessStore, access: SourceAccessContext) {
        self.access = access
        records = AlignmentSourceAccess(store: accessStore)
        decoder = SourceDecoder(access: access)
    }

    /// A header-only, local-media inspection, separate from passive availability observation.
    /// Import may inspect a matching provisional original; neither path confirms its identity.
    func inspect(_ key: DeviceAccessKey, permitProvisional: Bool = false) async throws -> SourceObservations {
        try Task.checkCancellation()
        guard var record = try await records.record(for: key) else { throw Failure.noAccess }
        let evaluation = SourceAvailabilityEvaluator(context: access).evaluate(key: key, record: record, setting: .off)
        guard evaluation.observation.access == .granted,
              evaluation.observation.residency == .local, let url = evaluation.resolvedURL else {
            throw Failure.notLocalOrAccessible
        }
        if let refreshed = evaluation.refreshedRecord {
            try await records.refresh(refreshed)
            record = refreshed
        }
        guard let baseline = record.recordedIdentity,
              baseline.confirmation == .userConfirmed || permitProvisional else { throw Failure.unconfirmed }
        let fingerprint = try access.withScopedAccess(to: url) { scoped in
            guard case let .success(metadata) = access.io.metadata(at: scoped),
                  metadata.isReadable.value == true, metadata.residency.0 == .local,
                  baseline.fingerprint.compare(to: metadata.fingerprint).isExactMatch else {
                throw Failure.changed
            }
            return metadata.fingerprint
        }
        let observations: SourceObservations
        if let cached = cache[key.sourceID], cached.fingerprint == fingerprint {
            observations = cached.observations
        } else {
            observations = try await decoder.withDecodingCursor(url, source: key.sourceID) { cursor in
                let format = cursor.interpretation
                guard format.sourceFingerprint.compare(to: fingerprint).isExactMatch else { throw Failure.changed }
                return SourceObservations(
                    durationSeconds: .known(Double(format.frames.validFrames) / Double(format.sourceSampleRate)),
                    channelCount: .known(format.channelCount), sampleRate: .known(Double(format.sourceSampleRate)))
            }
        }
        try Task.checkCancellation()
        let current = try await records.record(for: key)
        guard current?.key == key, current?.bookmark == record.bookmark,
              current?.recordedIdentity == record.recordedIdentity else { throw Failure.changed }
        let unchanged = access.withScopedAccess(to: url) { scoped in
            guard case let .success(metadata) = access.io.metadata(at: scoped) else { return false }
            return metadata.residency.0 == .local && fingerprint.compare(to: metadata.fingerprint).isExactMatch
        }
        guard unchanged else { throw Failure.changed }
        cache[key.sourceID] = (fingerprint, observations)
        return observations
    }

    enum Failure: LocalizedError {
        case noAccess, notLocalOrAccessible, unconfirmed, changed

        var errorDescription: String? {
            switch self {
            case .noAccess: "Restore permission to reach the recording on this Mac, then read its audio details again."
            case .notLocalOrAccessible: "Audio details require an accessible, local recording. No download was requested; last known details were kept."
            case .unconfirmed: "Confirm or relink the original before updating its audio details."
            case .changed: "The original or its permission changed during inspection. Review its identity and retry; last known details were kept."
            }
        }
    }
}
