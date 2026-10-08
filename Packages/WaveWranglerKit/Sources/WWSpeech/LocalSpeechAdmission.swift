import CryptoKit
import Darwin
import Foundation
import WWCore
import WWDecode

/// Only an explicitly confirmed primary channel may be submitted to a speech engine. This is
/// metadata admission, not proof that a future decoded PCM proxy came from that channel.
public struct PrimarySpeechSelection: Sendable, Equatable {
    public let episodeID: EpisodeID
    public let speakerID: SpeakerID
    public let sourceID: SourceID
    public let channel: Int

    public init(episode: Episode, speakerID: SpeakerID) throws(SpeechAdmissionRefusal) {
        guard episode.speakerAssignments.filter({ $0.speakerID == speakerID }).count == 1,
              let assignment = episode.assignment(for: speakerID),
              assignment.primaryConfirmation == .userConfirmed,
              let primary = assignment.primary,
              let channel = primary.channel.value, channel >= 0,
              let source = episode.source(primary.sourceID),
              episode.sources.filter({ $0.id == primary.sourceID }).count == 1,
              let channelCount = source.observations.channelCount.value, channel < channelCount,
              source.placement.channelLabels.count == 1,
              source.placement.channelLabels[0].channel == channel,
              source.role == .primary, source.roleConfirmation == .userConfirmed,
              !assignment.backups.contains(primary),
              !episode.speakerAssignments.contains(where: { $0.backups.contains(primary) }),
              episode.speakerAssignments.filter({ $0.primary == primary }).count == 1
        else { throw .primaryNotConfirmed }
        episodeID = episode.id
        self.speakerID = speakerID
        sourceID = primary.sourceID
        self.channel = channel
    }
}

public enum SpeechAdmissionRefusal: Error, Sendable, Equatable {
    case primaryNotConfirmed
    case assetNotLocalRegularFile
    case assetSizeMismatch
    case assetDigestMismatch
    case assetChangedDuringVerification
    case primaryProxyNotProven
    case sourceIdentityNotConfirmed
    case currentStateUnavailable
    case sourceAliasOrChanged
    case sourceRevisionChanged
    case occurrenceNotContinuous
    case inputTooLarge
    case proxyRateUnsupported
    case proxyFrameOverflow
    case proxyChunkOverflow
    case decode(DecodeFailure)
    case runtimeNotStaged
    case runtimeDependencyMismatch
    case sandboxFailed
}

/// Reviewed artifact identity. Production callers cannot supply provenance or substitute their own hash.
public struct LocalSpeechAssetPin: Sendable, Equatable {
    public let name: String
    public let version: String
    public let sizeBytes: Int64
    public let sha256: String
    public let license: String
    public let source: String

    package init(name: String, version: String, sizeBytes: Int64, sha256: String, license: String, source: String) {
        self.name = name
        self.version = version
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.license = license
        self.source = source
    }

    public static let whisperBaseEnglish = LocalSpeechAssetPin(
        name: "ggml-base.en.bin",
        version: "ggerganov/whisper.cpp@5359861c739e955e79d9a303bcbc70fb988958b1",
        sizeBytes: 147_964_211,
        sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        license: "MIT (model repository declaration; redistribution review outstanding)",
        source: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.en.bin"
    )

    /// Refuses non-local, dataless, symlinked or changed assets. Errors intentionally contain no
    /// path or file contents. Reverify at use time; a verified value is not an authorization to infer.
    public func verify(at url: URL) throws(SpeechAdmissionRefusal) {
        guard url.isFileURL, url.path.hasPrefix("/"),
              !url.pathComponents.contains("..") else { throw .assetNotLocalRegularFile }
        var component = URL(fileURLWithPath: "/")
        for part in url.pathComponents.dropFirst().dropLast() {
            component.appendPathComponent(part)
            var metadata = stat()
            guard lstat(component.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_flags & UInt32(SF_DATALESS) == 0 else { throw .assetNotLocalRegularFile }
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .volumeIsLocalKey, .isUbiquitousItemKey])
        } catch {
            throw .assetNotLocalRegularFile
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.volumeIsLocal == true, values.isUbiquitousItem != true
        else { throw .assetNotLocalRegularFile }

        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        guard previous >= 0,
              setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
        else { throw .assetNotLocalRegularFile }
        defer { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) }

        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw .assetNotLocalRegularFile }
        defer { _ = close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_flags & UInt32(SF_DATALESS) == 0,
              fcntl(fd, F_GETFL) & O_ACCMODE == O_RDONLY
        else { throw .assetNotLocalRegularFile }
        guard before.st_size == sizeBytes else { throw .assetSizeMismatch }
        var digest = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw .assetNotLocalRegularFile
            }
            if count == 0 { break }
            digest.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_flags & UInt32(SF_DATALESS) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw .assetChangedDuringVerification }
        var pathState = stat()
        guard lstat(url.path, &pathState) == 0,
              pathState.st_dev == after.st_dev, pathState.st_ino == after.st_ino,
              pathState.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              pathState.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              pathState.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              pathState.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw .assetChangedDuringVerification }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256
        else { throw .assetDigestMismatch }
    }
}
