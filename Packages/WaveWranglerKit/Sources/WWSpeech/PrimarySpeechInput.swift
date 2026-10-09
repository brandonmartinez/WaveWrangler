import CryptoKit
import Darwin
import Foundation
import WWCore
import WWDecode
import WWDerived
import WWSources

/// Caller-declared intent for this episode and speaker, not production consent or permission
/// inferred from an import, preference, or another speaker's selected primary.
public struct PrimarySpeechAuthorization: Sendable, Equatable {
    public let episodeID: EpisodeID
    public let speakerID: SpeakerID

    private init(episodeID: EpisodeID, speakerID: SpeakerID) {
        self.episodeID = episodeID
        self.speakerID = speakerID
    }

    public static func explicitUserRequest(episodeID: EpisodeID, speakerID: SpeakerID) -> Self {
        Self(episodeID: episodeID, speakerID: speakerID)
    }
}

/// A caller-supplied snapshot of organizer and device-local source state. This does not attest
/// persistence, map activation, or organizer ownership; the caller must read it afresh on each request.
public struct PrimarySpeechInputState: Sendable {
    public let show: ShowDocumentModel
    /// Monotonic organizer mutation serial, including unsaved edits and undo/redo. A persisted
    /// publication revision alone cannot detect a primary switch-away-and-back before autosave.
    public let showRevision: UInt64?
    /// The entire device-local access-record set for this show, not just the selected source's hint.
    public let accessRecords: [DeviceAccessRecord]
    public let sourceRevision: SourceRevision?
    public let inputAssetRevision: Int?

    public init(show: ShowDocumentModel, showRevision: UInt64?, accessRecords: [DeviceAccessRecord],
                sourceRevision: SourceRevision?, inputAssetRevision: Int?) {
        self.show = show
        self.showRevision = showRevision
        self.accessRecords = accessRecords
        self.sourceRevision = sourceRevision
        self.inputAssetRevision = inputAssetRevision
    }
}

/// Provisional decoded samples of a selected channel in an episode with no maps. Caller-supplied
/// state cannot certify organizer authority or an accepted occurrence. This is not a worker credential.
/// The bytes stay private to WWSpeech; there is no public initializer or file URL.
public struct ProvisionalPrimarySpeechInput: Sendable {
    public let selection: PrimarySpeechSelection
    public let declaredAuthorization: PrimarySpeechAuthorization
    public let showRevision: UInt64
    public let interpretation: FormatInterpretation
    public let sourceRevision: SourceRevision
    /// SHA-256 over the selected decoded source channel, not the container file.
    public let selectedSourcePCMHash: String
    public let inputAssetRevision: Int
    package let samples: [Float]

    public var frameCount: Int { samples.count }

    fileprivate init(selection: PrimarySpeechSelection, declaredAuthorization: PrimarySpeechAuthorization,
                     showRevision: UInt64, interpretation: FormatInterpretation,
                     sourceRevision: SourceRevision, selectedSourcePCMHash: String,
                     samples: [Float]) {
        self.selection = selection
        self.declaredAuthorization = declaredAuthorization
        self.showRevision = showRevision
        self.interpretation = interpretation
        self.sourceRevision = sourceRevision
        self.selectedSourcePCMHash = selectedSourcePCMHash
        inputAssetRevision = PrimarySpeechInputAdapter.inputAssetRevision
        self.samples = samples
    }

    /// The input has no owned, descriptor-pinned PCM proxy yet. In particular, this value cannot
    /// authorize a caller-provided WAV path to the existing worker.
    public func offlinePlan(stage: URL, scratch: URL) throws(SpeechAdmissionRefusal) -> OfflineWhisperPlan {
        throw .primaryProxyNotProven
    }
}

public struct PrimarySpeechInputAdapter: Sendable {
    /// Bump when selected-channel samples, envelope checks, or occurrence interpretation change.
    public static let inputAsset = AssetSpec(kind: "ww.speech-selected-channel", revision: 2)
    public static let inputAssetRevision = inputAsset.revision
    public static let maximumFrames = 16_000 * 60 * 10

    private let decoder: SourceDecoder

    public init() {
        decoder = SourceDecoder(access: SourceAccessContext())
    }

    package init(access: SourceAccessContext) {
        decoder = SourceDecoder(access: access)
    }

    package init(access: SourceAccessContext, content: any SourceContentIO) {
        decoder = SourceDecoder(access: access, content: content)
    }

    /// Caller intent and snapshots cannot certify an accepted map. Only unmapped episodes may
    /// produce provisional decoded samples; mapped episodes refuse until an organizer-owned,
    /// content-bound active-map authority exists. No worker can launch from the result.
    public func prepare(
        episodeID: EpisodeID,
        speakerID: SpeakerID,
        authorization: PrimarySpeechAuthorization?,
        availability: SourceAvailabilitySetting,
        current: @escaping @Sendable () async throws -> PrimarySpeechInputState
    ) async throws(SpeechAdmissionRefusal) -> ProvisionalPrimarySpeechInput {
        try await prepareSelected(episodeID: episodeID, speakerID: speakerID,
                                  authorization: authorization, availability: availability,
                                  current: current) { $0 }
    }

    /// In-memory, selected-channel-only 16 kHz PCM from the verified read-only decode. This
    /// provisional proxy has no file URL or worker authority. The final live-state checks run
    /// after resampling as well as after decoding; mapped episodes remain refused.
    public func preparePCMProxy(
        episodeID: EpisodeID,
        speakerID: SpeakerID,
        authorization: PrimarySpeechAuthorization?,
        availability: SourceAvailabilitySetting,
        current: @escaping @Sendable () async throws -> PrimarySpeechInputState
    ) async throws(SpeechAdmissionRefusal) -> SelectedPrimaryPCMProxy {
        try await prepareSelected(episodeID: episodeID, speakerID: speakerID,
                                  authorization: authorization, availability: availability,
                                  current: current) { input throws(SpeechAdmissionRefusal) in
            try SelectedPrimaryPCMProxy.make(from: input)
        }
    }

    #if DEBUG
    /// Synthetic tests may borrow a sealed, pathname-free input descriptor only while
    /// the selected source and organizer snapshot are still verified. Release builds
    /// expose no worker handoff until the real runtime and rights are qualified.
    package func withSealedSyntheticWorkerInput<T: Sendable>(
        episodeID: EpisodeID,
        speakerID: SpeakerID,
        authorization: PrimarySpeechAuthorization?,
        availability: SourceAvailabilitySetting,
        current: @escaping @Sendable () async throws -> PrimarySpeechInputState,
        workerURL: URL,
        workerPin: LocalSpeechAssetPin,
        worker: @escaping @Sendable (BorrowedPrimaryPCMInput) throws(SpeechAdmissionRefusal) -> T
    ) async throws(SpeechAdmissionRefusal) -> T {
        guard authorization?.episodeID == episodeID,
              authorization?.speakerID == speakerID,
              availability == .on else { throw .sourceIdentityNotConfirmed }
        do { try workerPin.verify(at: workerURL) }
        catch { throw .runtimeDependencyMismatch }
        return try await prepareSelected(
            episodeID: episodeID, speakerID: speakerID, authorization: authorization,
            availability: availability, current: current, postConsumeCheck: true,
            transform: { input throws(SpeechAdmissionRefusal) in
                try SealedPrimaryPCMWorkerInput(proxy: SelectedPrimaryPCMProxy.make(from: input))
            },
            consume: { sealed throws(SpeechAdmissionRefusal) in
                do { try workerPin.verify(at: workerURL) }
                catch { throw .runtimeDependencyMismatch }
                let result = try sealed.withBorrowedDescriptor(worker)
                do { try workerPin.verify(at: workerURL) }
                catch { throw .runtimeDependencyMismatch }
                return result
            }
        )
    }
    #endif

    private func prepareSelected<Product: Sendable>(
        episodeID: EpisodeID,
        speakerID: SpeakerID,
        authorization: PrimarySpeechAuthorization?,
        availability: SourceAvailabilitySetting,
        current: @escaping @Sendable () async throws -> PrimarySpeechInputState,
        transform: @escaping @Sendable (ProvisionalPrimarySpeechInput) throws(SpeechAdmissionRefusal) -> Product
    ) async throws(SpeechAdmissionRefusal) -> Product {
        try await prepareSelected(
            episodeID: episodeID, speakerID: speakerID, authorization: authorization,
            availability: availability, current: current, postConsumeCheck: false,
            transform: transform, consume: { $0 }
        )
    }

    private func prepareSelected<Product: Sendable, Result: Sendable>(
        episodeID: EpisodeID,
        speakerID: SpeakerID,
        authorization: PrimarySpeechAuthorization?,
        availability: SourceAvailabilitySetting,
        current: @escaping @Sendable () async throws -> PrimarySpeechInputState,
        postConsumeCheck: Bool,
        transform: @escaping @Sendable (ProvisionalPrimarySpeechInput) throws(SpeechAdmissionRefusal) -> Product,
        consume: @escaping @Sendable (Product) throws(SpeechAdmissionRefusal) -> Result
    ) async throws(SpeechAdmissionRefusal) -> Result {
        guard let authorization, authorization.episodeID == episodeID,
              authorization.speakerID == speakerID,
              availability == .on else { throw .sourceIdentityNotConfirmed }
        let initial: PrimarySpeechInputState
        do { initial = try await current() }
        catch { throw .currentStateUnavailable }
        guard initial.showRevision != nil else { throw .sourceRevisionChanged }
        let selection = try Self.selection(in: initial.show, episodeID: episodeID, speakerID: speakerID)
        try Self.requireUnmapped(initial.show, episodeID: episodeID)
        let matching = initial.accessRecords.filter {
            $0.showID == initial.show.show.id && $0.sourceID == selection.sourceID
        }
        guard matching.count == 1, let record = matching.first,
              initial.accessRecords.allSatisfy({ $0.showID == initial.show.show.id }),
              record.recordedIdentity?.confirmation == .userConfirmed,
              let bookmark = record.bookmark, let expectedPath = record.lastKnownPath,
              case let .resolved(url, isStale) = decoder.access.io.resolveBookmark(bookmark),
              !isStale, url.isFileURL, url.path == expectedPath
        else { throw .sourceIdentityNotConfirmed }
        do {
            return try await decoder.access.withScopedAccess(to: url) { scopedURL in
                try await prepareScoped(initial: initial, selection: selection, record: record,
                                        authorization: authorization, episodeID: episodeID,
                                        url: scopedURL, current: current,
                                        postConsumeCheck: postConsumeCheck, transform: transform,
                                        consume: consume)
            }
        } catch let refusal as SpeechAdmissionRefusal {
            throw refusal
        } catch {
            throw .currentStateUnavailable
        }
    }

    private func prepareScoped<Product: Sendable, Result: Sendable>(
        initial: PrimarySpeechInputState,
        selection: PrimarySpeechSelection,
        record: DeviceAccessRecord,
        authorization: PrimarySpeechAuthorization,
        episodeID: EpisodeID,
        url: URL,
        current: @escaping @Sendable () async throws -> PrimarySpeechInputState,
        postConsumeCheck: Bool,
        transform: @Sendable (ProvisionalPrimarySpeechInput) throws(SpeechAdmissionRefusal) -> Product,
        consume: @Sendable (Product) throws(SpeechAdmissionRefusal) -> Result
    ) async throws(SpeechAdmissionRefusal) -> Result {
        let before = try Self.inspect(url)
        guard case let .success(metadata) = decoder.access.io.metadata(at: url),
              metadata.volumeIsLocal.value == true,
              metadata.isDataless.value == false,
              metadata.isRegularFile.value == true,
              metadata.isSymbolicLink.value == false,
              metadata.fingerprint.fileIdentifier.value == UInt64(before.st_ino),
              record.recordedIdentity?.fingerprint.compare(to: metadata.fingerprint) == .matches
        else { throw .sourceIdentityNotConfirmed }
        guard initial.accessRecords.filter({ candidate in
            let fingerprint = candidate.recordedIdentity?.fingerprint
            return fingerprint?.fileIdentifier.value == metadata.fingerprint.fileIdentifier.value &&
                   fingerprint?.volumeUUID.value == metadata.fingerprint.volumeUUID.value
        }).count == 1 else { throw .sourceAliasOrChanged }
        let revision = SourceRevision.metadata(selection.sourceID, fingerprint: metadata.fingerprint)
        guard initial.sourceRevision == revision,
              initial.inputAssetRevision == Self.inputAssetRevision
        else { throw .sourceRevisionChanged }

        let decoded: (interpretation: FormatInterpretation, samples: [Float], hash: String)
        do {
            decoded = try await decoder.withDecodingCursor(url, source: selection.sourceID) { cursor in
                let interpretation = cursor.interpretation
                guard interpretation.source == selection.sourceID,
                      interpretation.channelCount == initial.show.episode(episodeID)?.source(selection.sourceID)?.observations.channelCount.value,
                      selection.channel < interpretation.channelCount,
                      interpretation.sourceFingerprint.compare(to: metadata.fingerprint) == .matches,
                      interpretation.formatInterpretationVersion == FormatRevision.current.interpretationVersion,
                      interpretation.envelopeVersion == FormatRevision.current.envelopeVersion
                else { throw SpeechAdmissionRefusal.sourceRevisionChanged }
                guard interpretation.frames.validFrames <= Int64(Self.maximumFrames) else {
                    throw SpeechAdmissionRefusal.inputTooLarge
                }
                var sink = SelectedChannelSink(channel: selection.channel,
                                               sampleRate: interpretation.sourceSampleRate,
                                               maximumFrames: Self.maximumFrames)
                do {
                    while let chunk = try await cursor.next() { try sink.append(chunk) }
                    let (samples, hash) = try sink.finish()
                    return (interpretation, samples, hash)
                } catch {
                    sink.abandon()
                    throw error
                }
            }
        } catch let failure as DecodeFailure {
            throw .decode(failure)
        } catch let refusal as SpeechAdmissionRefusal {
            throw refusal
        } catch {
            throw .currentStateUnavailable
        }
        guard let showRevision = initial.showRevision else { throw .sourceRevisionChanged }
        let input = ProvisionalPrimarySpeechInput(
            selection: selection, declaredAuthorization: authorization,
            showRevision: showRevision, interpretation: decoded.interpretation,
            sourceRevision: revision, selectedSourcePCMHash: decoded.hash,
            samples: decoded.samples
        )
        let product = try transform(input)
        guard !Task.isCancelled else { throw .decode(.cancelled) }
        let after = try Self.inspect(url)
        guard Self.sameFile(before, after) else { throw .sourceAliasOrChanged }
        let latest: PrimarySpeechInputState
        do { latest = try await current() }
        catch { throw .currentStateUnavailable }
        guard latest.show == initial.show, latest.showRevision == initial.showRevision,
              latest.accessRecords == initial.accessRecords,
              latest.sourceRevision == revision, latest.inputAssetRevision == Self.inputAssetRevision
        else { throw .sourceRevisionChanged }
        guard let bookmark = record.bookmark,
              case let .resolved(finalURL, isStale) = decoder.access.io.resolveBookmark(bookmark),
              !isStale, finalURL == url,
              case let .success(finalMetadata) = decoder.access.io.metadata(at: url),
              metadata.fingerprint.compare(to: finalMetadata.fingerprint) == .matches,
              record.recordedIdentity?.fingerprint.compare(to: finalMetadata.fingerprint) == .matches
        else { throw .sourceAliasOrChanged }
        try Self.requireUnmapped(latest.show, episodeID: episodeID)
        let final: PrimarySpeechInputState
        do { final = try await current() }
        catch { throw .currentStateUnavailable }
        guard final.show == latest.show, final.showRevision == latest.showRevision,
              final.accessRecords == latest.accessRecords, final.sourceRevision == revision,
              final.inputAssetRevision == Self.inputAssetRevision
        else { throw .sourceRevisionChanged }
        let finalRecords = final.accessRecords.filter {
            $0.showID == final.show.show.id && $0.sourceID == selection.sourceID
        }
        guard finalRecords.count == 1, let finalRecord = finalRecords.first,
              finalRecord == record,
              finalRecord.recordedIdentity?.confirmation == .userConfirmed,
              finalRecord.lastKnownPath == url.path,
              let bookmark = finalRecord.bookmark,
              case let .resolved(finalURL, isStale) = decoder.access.io.resolveBookmark(bookmark),
              !isStale, finalURL.isFileURL, finalURL == url,
              case let .success(finalMetadata) = decoder.access.io.metadata(at: url),
              finalMetadata.volumeIsLocal.value == true,
              finalMetadata.isDataless.value == false,
              finalMetadata.isRegularFile.value == true,
              finalMetadata.isSymbolicLink.value == false,
              metadata.fingerprint.compare(to: finalMetadata.fingerprint) == .matches,
              finalRecord.recordedIdentity?.fingerprint.compare(to: finalMetadata.fingerprint) == .matches,
              Self.sameFile(before, try Self.inspect(url)),
              finalMetadata.fingerprint.fileIdentifier.value == UInt64(before.st_ino)
        else { throw .sourceAliasOrChanged }
        guard !Task.isCancelled else { throw .decode(.cancelled) }
        let result = try consume(product)
        if postConsumeCheck {
            guard !Task.isCancelled else { throw .decode(.cancelled) }
            let checked: PrimarySpeechInputState
            do { checked = try await current() }
            catch { throw .currentStateUnavailable }
            guard checked.show == final.show, checked.showRevision == final.showRevision,
                  checked.accessRecords == final.accessRecords,
                  checked.sourceRevision == revision,
                  checked.inputAssetRevision == Self.inputAssetRevision
            else { throw .sourceRevisionChanged }
            guard let checkedRecord = checked.accessRecords.first(where: {
                      $0.showID == checked.show.show.id && $0.sourceID == selection.sourceID
                  }),
                  let bookmark = checkedRecord.bookmark,
                  case let .resolved(checkedURL, isStale) = decoder.access.io.resolveBookmark(bookmark),
                  !isStale, checkedURL == url,
                  case let .success(checkedMetadata) = decoder.access.io.metadata(at: url),
                  metadata.fingerprint.compare(to: checkedMetadata.fingerprint) == .matches,
                  checkedRecord.recordedIdentity?.fingerprint.compare(to: checkedMetadata.fingerprint) == .matches,
                  Self.sameFile(before, try Self.inspect(url))
            else { throw .sourceAliasOrChanged }
            guard !Task.isCancelled else { throw .decode(.cancelled) }
        }
        return result
    }

    private static func selection(in show: ShowDocumentModel, episodeID: EpisodeID,
                                  speakerID: SpeakerID) throws(SpeechAdmissionRefusal) -> PrimarySpeechSelection {
        guard show.episodes.filter({ $0.id == episodeID }).count == 1,
              show.speakers.filter({ $0.id == speakerID }).count == 1,
              let episode = show.episode(episodeID) else { throw .primaryNotConfirmed }
        return try PrimarySpeechSelection(episode: episode, speakerID: speakerID)
    }

    private static func requireUnmapped(_ show: ShowDocumentModel, episodeID: EpisodeID)
        throws(SpeechAdmissionRefusal)
    {
        guard let alignment = show.episode(episodeID)?.alignment else { return }
        guard alignment.maps.isEmpty, alignment.acceptedRevision == nil else {
            throw .occurrenceNotContinuous
        }
    }

    private static func inspect(_ url: URL) throws(SpeechAdmissionRefusal) -> stat {
        guard url.path.hasPrefix("/"), !url.pathComponents.contains("..") else { throw .sourceAliasOrChanged }
        var parent = URL(fileURLWithPath: "/")
        for part in url.pathComponents.dropFirst().dropLast() {
            parent.appendPathComponent(part)
            var info = stat()
            guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_flags & UInt32(SF_DATALESS) == 0 else { throw .sourceAliasOrChanged }
        }
        var file = stat()
        guard lstat(url.path, &file) == 0, file.st_mode & S_IFMT == S_IFREG,
              file.st_nlink == 1, file.st_flags & UInt32(SF_DATALESS) == 0
        else { throw .sourceAliasOrChanged }
        return file
    }

    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_nlink == b.st_nlink &&
        a.st_size == b.st_size && a.st_mode == b.st_mode && a.st_flags == b.st_flags &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}

private struct SelectedChannelSink: DecodedAudioSink {
    let channel: Int
    let maximumFrames: Int
    var samples: [Float] = []
    private var hasher: SHA256

    init(channel: Int, sampleRate: Int, maximumFrames: Int) {
        self.channel = channel
        self.maximumFrames = maximumFrames
        hasher = SHA256()
        hasher.update(data: Data("WWSelectedPrimaryPCM1".utf8))
        Self.update(&hasher, Int64(channel))
        Self.update(&hasher, Int64(sampleRate))
    }

    mutating func append(_ chunk: DecodedChunk) throws {
        guard channel >= 0, channel < chunk.channelCount,
              chunk.firstSourceFrame == Int64(samples.count),
              chunk.channel(channel).allSatisfy(\.isFinite)
        else { throw SpeechAdmissionRefusal.sourceRevisionChanged }
        guard chunk.frameCount <= maximumFrames - samples.count else { throw SpeechAdmissionRefusal.inputTooLarge }
        let selected = chunk.channel(channel)
        let bits = selected.map { $0.bitPattern.littleEndian }
        bits.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        samples.append(contentsOf: selected)
    }

    mutating func finish() throws -> ([Float], String) {
        Self.update(&hasher, Int64(samples.count))
        return (samples, "selected-pcm-sha256:" +
            hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func update(_ hasher: inout SHA256, _ value: Int64) {
        withUnsafeBytes(of: value.littleEndian) { hasher.update(bufferPointer: $0) }
    }

    mutating func abandon() {
        samples.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress?.update(repeating: 0, count: buffer.count)
        }
        samples.removeAll(keepingCapacity: false)
    }
}
