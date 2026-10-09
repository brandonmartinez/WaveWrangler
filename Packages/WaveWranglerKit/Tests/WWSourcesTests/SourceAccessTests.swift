import Darwin
import Foundation
import Testing
import WWCore
@testable import WWSources

@Suite("Source access model")
struct SourceAccessTests {
    @Test func availabilityDefaultsToOn() {
        #expect(SourceAvailabilitySetting.default == .on)
        #expect(SourceAvailabilitySetting(downloadSourcesAutomatically: nil) == .on)
        #expect(SourceAvailabilitySetting(downloadSourcesAutomatically: true) == .on)
        #expect(SourceAvailabilitySetting(downloadSourcesAutomatically: false) == .off)
    }

    @Test func newObservationsStartUnknownInEveryDimension() {
        let observation = AvailabilityObservation(observedAt: Date(timeIntervalSince1970: 0))
        #expect(observation.access == .unknown)
        #expect(observation.location == .unknown)
        #expect(observation.residency == .unknown)
        #expect(observation.transfer == .unknown)
        #expect(observation.identity == .unknown)
        #expect(observation.provenance == .observed)
        #expect(observation.remedies.isEmpty)
    }

    @Test func accessRecordRoundTripsWithoutPathIdentity() throws {
        let record = DeviceAccessRecord(
            showID: ShowID(),
            sourceID: SourceID(),
            bookmark: Data([1, 2, 3]),
            lastKnownPath: "/tmp/synthetic/take.wav",
            recordedIdentity: RecordedIdentity(
                fingerprint: FileSystemFingerprint(fileSize: .known(3), fileIdentifier: .known(9), volumeUUID: .known("V")),
                confirmation: .provisional,
                recordedAt: Date(timeIntervalSince1970: 5)
            ),
            createdAt: Date(timeIntervalSince1970: 1),
            latestObservation: AvailabilityObservation(
                observedAt: Date(timeIntervalSince1970: 10),
                location: .missing(lastKnownPathOccupied: .known(true)),
                access: .denied,
                transfer: .inProgress(fractionCompleted: .unknown),
                identity: .mismatch([.fileIdentifier])
            ),
            relinkHistory: [RelinkEvent(at: Date(timeIntervalSince1970: 11), comparison: .differs([.fileSize], unknown: []), userConfirmed: true)]
        )
        let decoded = try JSONDecoder().decode(DeviceAccessRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(decoded.id == record.key)
    }

    @Test func portableSourceRecordCarriesNoDeviceAccessFields() throws {
        let json = try String(decoding: JSONEncoder().encode(SourceRecord(displayNameHint: "take.wav")), as: UTF8.self)
        for forbidden in ["bookmark", "lastKnownPath", "volume", "fingerprint", "access"] {
            #expect(!json.contains(forbidden))
        }
    }

    @Test func deniedAndMissingStayDistinct() {
        let denied = AvailabilityObservation(observedAt: .now, access: .denied)
        let missing = AvailabilityObservation(observedAt: .now, location: .missing(lastKnownPathOccupied: .known(false)))
        #expect(denied.remedies == [.checkPermissions])
        #expect(missing.remedies == [.relink])
        #expect(AccessState.denied.diagnosticText != LocationState.missing(lastKnownPathOccupied: .known(false)).diagnosticText)
        #expect(AccessState.denied.diagnosticText.contains("not a missing file"))
    }

    @Test func everyStateHasDistinctStatusText() {
        let access = AccessState.allCases.map(\.diagnosticText)
        #expect(Set(access).count == access.count)
        let residency = ResidencyState.allCases.map(\.diagnosticText)
        #expect(Set(residency).count == residency.count)
        let transfers: [TransferState] = [
            .unknown, .idle, .notRequested(.availabilityOff), .notRequested(.unsupportedLocation), .notRequested(.awaitingAccess),
            .requested, .inProgress(fractionCompleted: .unknown), .inProgress(fractionCompleted: .known(0.5)), .cancelled,
            .failed(SourceErrorDescriptor(domain: "d", code: 1)), .offlineOrUnknown(nil),
        ]
        let texts = transfers.map(\.diagnosticText)
        #expect(Set(texts).count == texts.count)
        #expect(TransferState.inProgress(fractionCompleted: .known(0.5)).reportedFraction == 0.5)
        #expect(TransferState.inProgress(fractionCompleted: .unknown).reportedFraction == nil)
        let identities: [IdentityState] = [
            .unknown, .unverified(.noRecordedEvidence), .unverified(.baselineNotUserConfirmed),
            .unverified(.insufficientEvidence([.fileIdentifier])), .matchesRecorded, .changed([.fileSize]), .mismatch([.fileIdentifier]),
        ]
        let identityTexts = identities.map(\.diagnosticText)
        #expect(Set(identityTexts).count == identityTexts.count)
    }

    @Test func offRemedyOffersExplicitMakeAvailable() {
        let observation = AvailabilityObservation(observedAt: .now, residency: .cloudPlaceholder, transfer: .notRequested(.availabilityOff))
        #expect(observation.remedies == [.makeAvailable])
        #expect(TransferState.notRequested(.availabilityOff).diagnosticText.contains("downloads are off"))
    }

    @Test func transferErrorsAreClassifiedHonestly() {
        #expect(TransferErrorClassifier.state(for: SourceErrorDescriptor(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) == .offlineOrUnknown(SourceErrorDescriptor(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
        #expect(TransferErrorClassifier.state(for: SourceErrorDescriptor(domain: NSCocoaErrorDomain, code: NSUbiquitousFileUnavailableError)).isOfflineOrUnknown)
        #expect(TransferErrorClassifier.state(for: SourceErrorDescriptor(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)) == .failed(SourceErrorDescriptor(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)))
    }
}

extension TransferState {
    var isOfflineOrUnknown: Bool {
        if case .offlineOrUnknown = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

@Suite("Identity evidence")
struct IdentityEvidenceTests {
    let base = FileSystemFingerprint(
        fileSize: .known(100),
        creationDate: .known(Date(timeIntervalSince1970: 1)),
        contentModificationDate: .known(Date(timeIntervalSince1970: 2)),
        fileIdentifier: .known(42),
        volumeUUID: .known("VOL"),
        contentType: .known("com.microsoft.waveform-audio")
    )

    @Test func exactMatchRequiresEveryField() {
        #expect(base.compare(to: base) == .matches)
        var partial = base
        partial.fileIdentifier = .unknown
        #expect(base.compare(to: partial) == .unknown([.fileIdentifier]))
        #expect(partial.compare(to: base) == .unknown([.fileIdentifier]))
    }

    @Test func differencesWinOverUnknowns() {
        var candidate = base
        candidate.fileSize = .known(101)
        candidate.volumeUUID = .unknown
        #expect(base.compare(to: candidate) == .differs([.fileSize], unknown: [.volumeUUID]))
    }

    @Test func objectChangesAreMismatchesContentChangesAreChanges() {
        let recorded = RecordedIdentity(fingerprint: base, confirmation: .userConfirmed, recordedAt: .now)
        var appended = base
        appended.fileSize = .known(200)
        appended.contentModificationDate = .known(Date(timeIntervalSince1970: 3))
        #expect(recorded.identityState(for: base.compare(to: appended)) == .changed([.fileSize, .contentModificationDate]))
        var substitute = base
        substitute.fileIdentifier = .known(43)
        #expect(recorded.identityState(for: base.compare(to: substitute)) == .mismatch([.fileIdentifier]))
        #expect(recorded.identityState(for: .matches) == .matchesRecorded)
        let provisional = RecordedIdentity(fingerprint: base, confirmation: .provisional, recordedAt: .now)
        #expect(provisional.identityState(for: .matches) == .unverified(.baselineNotUserConfirmed))
    }

    @Test func contentEvidenceIsDeclaredButNeverObserved() {
        #expect(ContentEvidenceField.allCases.count == 3)
        // There is no FileSystemFingerprint field for content: identity is metadata-only in M1.
        #expect(FingerprintField.allCases.count == 6)
    }

    @Test func regularFileDescriptorReportsTheURLVolumeUUID() throws {
        let tree = try SyntheticTree(label: "raw-fd-volume")
        var rng = SplitMix64(seed: 413)
        let file = try tree.file("take.wav", bytes: 128, rng: &rng)
        let io = SystemSourceIO()
        guard case let .success(metadata) = io.metadata(at: file) else {
            Issue.record("synthetic file metadata unavailable")
            return
        }
        let expectedVolume = try #require(metadata.fingerprint.volumeUUID.value)
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(fd) }
        let observed = try #require(RawSourceIdentity.onDescriptor(fd))
        #expect(observed.volumeUUID == expectedVolume.lowercased())
        #expect(observed.inode == metadata.fingerprint.fileIdentifier.value)
        #expect(observed.sizeBytes == metadata.fingerprint.fileSize.value)
    }
}

@Suite("Identity timestamp tolerance (#78)")
struct IdentityTimestampToleranceTests {
    static let base = Date(timeIntervalSinceReferenceDate: 812_345_678.123_456_7)

    static func fingerprint(created: Date = base, modified: Date = base, size: Int64 = 1_000, fileID: UInt64 = 42, volume: String = "VOL") -> FileSystemFingerprint {
        FileSystemFingerprint(
            fileSize: .known(size),
            creationDate: .known(created),
            contentModificationDate: .known(modified),
            fileIdentifier: .known(fileID),
            volumeUUID: .known(volume),
            contentType: .known("com.microsoft.waveform-audio")
        )
    }

    @Test(arguments: [1.19e-7, -1.19e-7, 1e-6, 5e-4, 9.99e-4, -9.99e-4])
    func subToleranceShiftsMatch(delta: Double) {
        let recorded = Self.fingerprint()
        #expect(recorded.compare(to: Self.fingerprint(created: Self.base.addingTimeInterval(delta), modified: Self.base.addingTimeInterval(delta))) == .matches)
        #expect(RecordedIdentity(fingerprint: recorded, confirmation: .userConfirmed, recordedAt: .now)
            .identityState(for: recorded.compare(to: Self.fingerprint(modified: Self.base.addingTimeInterval(delta)))) == .matchesRecorded)
    }

    @Test(arguments: [1.1e-3, -1.1e-3, 0.01, 1, 3_600])
    func aboveToleranceShiftsAreChanges(delta: Double) {
        let recorded = Self.fingerprint()
        #expect(recorded.compare(to: Self.fingerprint(modified: Self.base.addingTimeInterval(delta))) == .differs([.contentModificationDate], unknown: []))
        #expect(recorded.compare(to: Self.fingerprint(created: Self.base.addingTimeInterval(delta))) == .differs([.creationDate], unknown: []))
    }

    @Test func sizeOrObjectDifferencesNeverMatchEvenWithSubToleranceDates() {
        let recorded = Self.fingerprint()
        let tiny = Self.base.addingTimeInterval(1.19e-7)
        let identity = RecordedIdentity(fingerprint: recorded, confirmation: .userConfirmed, recordedAt: .now)
        #expect(recorded.compare(to: Self.fingerprint(created: tiny, modified: tiny, size: 1_001)) == .differs([.fileSize], unknown: []))
        #expect(identity.identityState(for: recorded.compare(to: Self.fingerprint(modified: tiny, fileID: 43))) == .mismatch([.fileIdentifier]))
        #expect(identity.identityState(for: recorded.compare(to: Self.fingerprint(modified: tiny, volume: "OTHER"))) == .mismatch([.volumeUUID]))
        #expect(Self.fingerprint(size: 0).compare(to: Self.fingerprint(size: 1)) != .matches)
    }

    @Test func unknownDatesNeverMatch() {
        var candidate = Self.fingerprint()
        candidate.contentModificationDate = .unknown
        #expect(Self.fingerprint().compare(to: candidate) == .unknown([.contentModificationDate]))
    }

    /// Observed on the local file system: a real file's dates moved by sub-tolerance and above-tolerance
    /// amounts (harness `setAttributes`, outside the app).
    @Test(arguments: [(0.000_000_2, true), (0.000_5, true), (0.002, false), (2.0, false)])
    func evaluatorOnRealFiles(delta: Double, expectMatch: Bool) async throws {
        let tree = try SyntheticTree(label: "tolerance")
        var rng = SplitMix64(seed: 78)
        let file = try tree.file("take.wav", bytes: 128, rng: &rng)
        let context = makeContext(HarnessIO())
        var record = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        record = RelinkEvaluator(context: context).confirmIdentity(of: record)
        let recordedModified = try #require(record.recordedIdentity?.fingerprint.contentModificationDate.value)
        try setDates(file, modification: recordedModified.addingTimeInterval(delta), creation: nil)
        let identity = SourceAvailabilityEvaluator(context: context).evaluate(key: record.key, record: record, setting: .on).observation.identity
        if expectMatch {
            #expect(identity == .matchesRecorded, "delta \(delta): \(identity)")
        } else {
            #expect(identity == .changed([.contentModificationDate]), "delta \(delta): \(identity)")
        }
    }
}

@Suite("Device access store keeps identity-baseline precision (#121)")
struct AccessStoreDatePrecisionTests {
    /// A record persisted by `FileDeviceAccessStore` and read back by a fresh store keeps sub-millisecond
    /// dates, so evaluating the untouched source right away reports it as matching — never `changed`.
    @Test func persistedBaselineMatchesImmediately() async throws {
        let tree = try SyntheticTree(label: "store-precision")
        var rng = SplitMix64(seed: 1_210)
        let file = try tree.file("take.wav", bytes: 512, rng: &rng)
        let context = makeContext(HarnessIO())
        var record = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        record = RelinkEvaluator(context: context).confirmIdentity(of: record)
        let recordedModified = try #require(record.recordedIdentity?.fingerprint.contentModificationDate.value)
        // The generated file has sub-second timestamps (otherwise this test would prove nothing).
        #expect(recordedModified.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) != 0)

        let storeURL = tree.root.appendingPathComponent("device-access/records.json")
        try await FileDeviceAccessStore(fileURL: storeURL).save(record)
        let reloaded = try #require(try await FileDeviceAccessStore(fileURL: storeURL).record(for: record.key))
        #expect(reloaded.recordedIdentity == record.recordedIdentity)

        let observation = SourceAvailabilityEvaluator(context: context).evaluate(key: reloaded.key, record: reloaded, setting: .on).observation
        #expect(observation.identity == .matchesRecorded)
        #expect(observation.location == .present)
        #expect(observation.access == .granted)
    }

    /// The failure mode behind #121 (a harness that stored baselines with `.iso8601`, whole seconds):
    /// a baseline truncated to whole seconds is honestly reported `changed`, which is why the store must
    /// keep full precision.
    @Test func wholeSecondBaselineIsReportedChanged() async throws {
        let tree = try SyntheticTree(label: "store-precision-lossy")
        var rng = SplitMix64(seed: 1_211)
        let file = try tree.file("take.wav", bytes: 512, rng: &rng)
        let context = makeContext(HarnessIO())
        var record = try #require(try await SourceImporter(context: context).plan(selection: [file], showID: testShow).items.first?.accessRecord)
        let fingerprint = try #require(record.recordedIdentity?.fingerprint)
        let created = try #require(fingerprint.creationDate.value)
        let modified = try #require(fingerprint.contentModificationDate.value)
        try #require(abs(modified.timeIntervalSinceReferenceDate.rounded(.down) - modified.timeIntervalSinceReferenceDate) > 0.001)
        var truncated = fingerprint
        truncated.creationDate = .known(Date(timeIntervalSinceReferenceDate: created.timeIntervalSinceReferenceDate.rounded(.down)))
        truncated.contentModificationDate = .known(Date(timeIntervalSinceReferenceDate: modified.timeIntervalSinceReferenceDate.rounded(.down)))
        record.recordedIdentity?.fingerprint = truncated
        let observation = SourceAvailabilityEvaluator(context: context).evaluate(key: record.key, record: record, setting: .on).observation
        if case .changed = observation.identity {} else { Issue.record("expected changed for a lossy baseline: \(observation.identity)") }
    }
}
