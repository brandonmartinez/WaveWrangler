import Foundation
import Testing
import WWCore
@testable import WWEpisodeSetup

private struct Fixture {
    let ana = Speaker(name: "Ana")
    let guest = Speaker(name: "Guest")
    let group = RecorderGroup(name: "Zoom H6", epochs: [RecordingEpoch(label: "1")])
    let tr1: SourceRecord
    let tr2: SourceRecord
    let intro = SourceRecord(displayNameHint: "intro.wav")
    let episodeID = EpisodeID()
    let model: ShowDocumentModel

    init() throws {
        tr1 = SourceRecord(displayNameHint: "tr1.wav", placement: SourcePlacement(recorderGroupID: group.id, epochID: group.epochs[0].id))
        tr2 = SourceRecord(displayNameHint: "tr2.wav", placement: SourcePlacement(recorderGroupID: group.id, epochID: group.epochs[0].id))
        var model = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [Episode(id: episodeID, title: "Interview", recorderGroups: [group], sources: [tr1, tr2, intro])])
        model = try model.addingSpeaker(ana, toEpisode: episodeID).addingSpeaker(guest, toEpisode: episodeID)
        model = try model.assigningSpeaker(ana.id, toSource: tr1.id, in: episodeID)
        model = try model.settingStatedChannel(0, forSource: tr1.id, in: episodeID)
        model = try model.usingAsPrimary(ChannelReference(sourceID: tr1.id, channel: 0), for: ana.id, in: episodeID)
        self.model = model
    }
}

@Suite("Setup tables presentation")
struct SetupPresentationTests {
    let ready = SourceStatusSnapshot(location: .known, access: .granted, residency: .local, transfer: .idle, identity: .notChecked)

    @Test func groupsSourcesWithUngroupedAlwaysPresent() throws {
        let f = try Fixture()
        let p = SetupPresentation(model: f.model, episodeID: f.episodeID, statuses: [:])
        #expect(p.sourceRows.map(\.name) == ["Zoom H6 — recorder group · 2 sources", "Ungrouped · 1 source"])
        #expect(p.sourceRows[0].children?.map(\.name) == ["tr1.wav", "tr2.wav"])
        let tr1 = try #require(p.sourceRows[0].children?.first)
        #expect(tr1.epoch.text == "1")
        #expect(tr1.channel == CellText("1", accessibilityValue: "1, not checked against the file"))
        #expect(tr1.speaker.text == "Ana")
        #expect(tr1.role.text == "Primary")
        #expect(tr1.status?.text == "Checking…", "unobserved sources are never guessed")
        let tr2 = try #require(p.sourceRows[0].children?.last)
        #expect(tr2.channel == .unknown)
        #expect(tr2.speaker == .none)
        let intro = try #require(p.sourceRows[1].children?.first)
        #expect(intro.epoch == .none)
        #expect(tr1.recordedFacts?.duration.text == "Unknown")
        #expect(tr1.recordedFacts?.channelCount.text == "Unknown")
        #expect(tr1.recordedFacts?.sampleRate.text == "Unknown")
        #expect(SetupPresentation(model: f.model, episodeID: f.episodeID, statuses: [:]).sourceRows.last?.id == .group(nil))
    }

    @Test func headerCountsSourcesNeedingAttention() throws {
        let f = try Fixture()
        var missing = ready
        missing.location = .missing(sameNamedFileAtOriginalLocation: true)
        let statuses = [f.tr1.id: ready, f.tr2.id: missing, f.intro.id: SourceStatusSnapshot(location: .known, access: .denied, residency: .local, identity: .notChecked)]
        let p = SetupPresentation(model: f.model, episodeID: f.episodeID, statuses: statuses)
        #expect(p.sourcesHeader == "Sources 3 · 2 need attention")
        let filtered = SetupPresentation(model: f.model, episodeID: f.episodeID, statuses: statuses, onlyNeedingAttention: true)
        #expect(filtered.orderedSourceIDs == [f.tr2.id, f.intro.id])
        let none = SetupPresentation(model: f.model, episodeID: f.episodeID, statuses: [f.tr1.id: ready, f.tr2.id: ready, f.intro.id: ready])
        #expect(none.sourcesHeader == "Sources 3")
    }

    @Test func speakerStatusesUseTheThreeDesignStates() throws {
        let f = try Fixture()
        var p = SetupPresentation(model: f.model, episodeID: f.episodeID, statuses: [f.tr1.id: ready])
        #expect(p.speakerRows.map(\.name) == ["Ana", "Guest"])
        #expect(p.speakerRows[0].status == .primaryChosen)
        #expect(p.speakerRows[0].primary.text == "tr1.wav · channel 1")
        #expect(p.speakerRows[0].accessibilityValue == "Primary tr1.wav channel 1, 0 backups, Primary chosen")
        #expect(p.speakerRows[1].status == .choosePrimary)
        #expect(p.speakerRows[1].primary.text == "None")

        var missing = ready
        missing.location = .missing(sameNamedFileAtOriginalLocation: false)
        p = SetupPresentation(model: f.model, episodeID: f.episodeID, statuses: [f.tr1.id: missing])
        #expect(p.speakerRows[0].status.text == "Primary unavailable — Not found")
    }

    @Test func unconfirmedRolesAreLabelled() throws {
        let f = try Fixture()
        let model = try f.model.assigningSpeaker(f.guest.id, toSource: f.tr2.id, in: f.episodeID)
        let p = SetupPresentation(model: model, episodeID: f.episodeID, statuses: [:])
        let tr2 = try #require(p.sourceRows[0].children?.last)
        #expect(tr2.role.text == "Backup (not confirmed)")
        #expect(tr2.role.accessibilityValue == "Backup, not confirmed")
    }

    @Test func rowIdentifiersUseLogicalIDsNeverFileNames() throws {
        let f = try Fixture()
        let p = SetupPresentation(model: f.model, episodeID: f.episodeID, statuses: [:])
        for row in p.sourceRows + p.sourceRows.flatMap({ $0.children ?? [] }) {
            #expect(!row.id.accessibilityIdentifier.contains(".wav"))
            #expect(row.id.accessibilityIdentifier.hasPrefix("ww.setup."))
        }
        #expect(SetupRowID.source(f.tr1.id).accessibilityIdentifier == "ww.setup.source.\(f.tr1.id)")
    }

    @Test func sortByNameKeepsGroups() throws {
        let f = try Fixture()
        let model = try f.model.movingSource(f.tr1.id, .down, in: f.episodeID)
        let manual = SetupPresentation(model: model, episodeID: f.episodeID, statuses: [:])
        #expect(manual.sourceRows[0].children?.map(\.name) == ["tr2.wav", "tr1.wav"])
        let byName = SetupPresentation(model: model, episodeID: f.episodeID, statuses: [:], sortOrder: .name)
        #expect(byName.sourceRows[0].children?.map(\.name) == ["tr1.wav", "tr2.wav"])
    }
}

@Suite("Import review (IA §5)")
struct ImportReviewTests {
    func scan() -> ImportScan {
        ImportScan(candidates: [
            ImportCandidate(details: FileDetails(name: "tr1.wav", folderName: "ZOOM0001"), kind: .recording(typeFromNameOnly: true), residency: .local),
            ImportCandidate(details: FileDetails(name: "tr2.wav", folderName: "ZOOM0001"), kind: .recording(typeFromNameOnly: true), residency: .cloudOnly),
            ImportCandidate(details: FileDetails(name: "ana-zoom.m4a", folderName: "Ana"), kind: .recording(typeFromNameOnly: true), residency: .cloudOnly),
            ImportCandidate(details: FileDetails(name: "tr3.wav", folderName: "ZOOM0001"), kind: .recording(typeFromNameOnly: true), alreadyInEpisode: true),
            ImportCandidate(details: FileDetails(name: "notes.txt"), kind: .notRecording),
            ImportCandidate(details: FileDetails(name: ".DS_Store"), kind: .hidden),
        ], chosenDisplayName: "Ana Interview", folderCount: 2, fileCount: 6)
    }

    @Test func suggestionsAreProvisionalAndDuplicatesExcluded() {
        let review = ImportReview(scan: scan(), episodeTitle: "Interview with Ana", knownSpeakerNames: ["Ana"])
        #expect(review.rows.count == 4)
        #expect(review.skipped.count == 2)
        #expect(review.includedCount == 3)
        #expect(review.title == "Import 3 Sources into “Interview with Ana”")
        #expect(review.importButtonTitle == "Import 3")
        #expect(review.fromLine == "From: Ana Interview (2 folders, 6 files; 1 not a recording, 1 hidden item, skipped)")
        #expect(review.rows[0].group == .suggested(Suggestion(value: "ZOOM0001", reason: "Suggested because the files share folder ZOOM0001")))
        #expect(review.rows[0].group.accessibilityValue(none: "Ungrouped") == "ZOOM0001, suggested")
        #expect(review.rows[2].speaker == .suggested(Suggestion(value: "Ana", reason: "Suggested because the file name contains “Ana”")))
        #expect(review.rows[3].caption == "Already in this episode")
        #expect(review.rows[0].caption == "Type from file name")
    }

    @Test func importDiscardsUnconfirmedSuggestions() {
        var review = ImportReview(scan: scan(), episodeTitle: "E", knownSpeakerNames: ["Ana"])
        #expect(review.confirmationLine == "4 suggestions weren't accepted and won't be applied.")
        review.setGroup(review.rows[0].id, "Zoom H6")
        let items = review.importItems()
        #expect(items.map(\.item.recorderGroupName) == ["Zoom H6", nil, nil])
        #expect(items.allSatisfy { $0.item.speakerName == nil })
        #expect(review.confirmationLine == "3 suggestions weren't accepted and won't be applied.")
    }

    @Test func acceptAllAndClear() {
        var review = ImportReview(scan: scan(), episodeTitle: "E", knownSpeakerNames: ["Ana"])
        review.acceptAllSuggestions()
        #expect(review.confirmationLine == nil)
        #expect(review.importItems().map(\.item.recorderGroupName) == ["ZOOM0001", "ZOOM0001", "Ana"])
        var cleared = ImportReview(scan: scan(), episodeTitle: "E", knownSpeakerNames: ["Ana"])
        cleared.clearSuggestions()
        #expect(!cleared.hasSuggestions)
        #expect(cleared.importItems().allSatisfy { $0.item.recorderGroupName == nil && $0.item.speakerName == nil })
    }

    @Test func includeToggleAndDownloadLine() {
        var review = ImportReview(scan: scan(), episodeTitle: "E", knownSpeakerNames: [])
        #expect(review.downloadLine(downloadsOn: true) == "2 files aren't downloaded. Downloads are On: they'll download after import.")
        #expect(review.downloadLine(downloadsOn: false) == "2 files aren't downloaded. Downloads are Off: WaveWrangler will use file details only and won't download them.")
        review.toggleInclude(review.rows[1].id)
        review.toggleInclude(review.rows[2].id)
        review.toggleInclude(review.rows[0].id)
        #expect(!review.canImport)
        #expect(review.downloadLine(downloadsOn: true) == nil)
    }

    @Test func sameNamedDifferentFileIsListedSeparately() {
        let scan = ImportScan(candidates: [
            ImportCandidate(details: FileDetails(name: "tr1.wav", size: 10), kind: .recording(typeFromNameOnly: true)),
            ImportCandidate(details: FileDetails(name: "tr1.wav", size: 20), kind: .recording(typeFromNameOnly: true)),
        ], chosenDisplayName: "x", folderCount: 1, fileCount: 2)
        let review = ImportReview(scan: scan, episodeTitle: "E", knownSpeakerNames: [])
        #expect(review.includedCount == 2)
    }
}

@Suite("Relink comparison (states §4)")
struct RelinkComparisonTests {
    let formatter = FileDetailFormatter(size: { "\($0) B" }, date: { "t\(Int($0.timeIntervalSince1970))" })
    let created = Date(timeIntervalSince1970: 1_000)
    var recorded: FileDetails { FileDetails(name: "tr2.wav", size: 100, created: created, modified: created, kind: "WAV audio", folderName: "ZOOM0001") }

    @Test func exactMatchHasDefaultUseThisFile() {
        let c = RelinkComparison.compare(recorded: recorded, chosen: recorded, formatter: formatter)
        #expect(c.outcome == .match)
        #expect(c.headline == "File details match. WaveWrangler compared file details, not audio.")
        #expect(!c.requiresAcknowledgement)
        #expect(c.confirmTitle == "Use This File")
        #expect(c.rows.map(\.result) == Array(repeating: .same, count: 5))
        #expect(c.acceptedIdentity == .detailsMatch)
    }

    @Test func sameNameDifferentSizeNeedsAcknowledgement() {
        var chosen = recorded
        chosen.size = 101
        let c = RelinkComparison.compare(recorded: recorded, chosen: chosen, formatter: formatter)
        #expect(c.outcome == .different(fields: ["Size"]))
        #expect(c.headline == "Some file details are different: size.")
        #expect(c.requiresAcknowledgement)
        #expect(c.confirmTitle == "Use This File Anyway")
        #expect(c.rows[1].accessibilityLabel == "Size — Recorded 100 B — Chosen 101 B — Different")
        #expect(c.acceptedIdentity == .changed(differences: "size differ", acceptedByUser: true))
    }

    @Test func missingDetailsAreUnknownNeverSame() {
        let c = RelinkComparison.compare(recorded: recorded, chosen: FileDetails(name: "tr2.wav"), unknownReason: "the file isn't downloaded and downloads are off", formatter: formatter)
        #expect(c.outcome == .unknown(reason: "the file isn't downloaded and downloads are off"))
        #expect(c.headline == "WaveWrangler can't compare some details because the file isn't downloaded and downloads are off.")
        #expect(c.requiresAcknowledgement)
    }

    @Test func panelMessage() {
        #expect(RelinkComparison.panelMessage(for: recorded, formatter: formatter) == "WaveWrangler recorded: 100 B, created t1000, from folder ZOOM0001.")
        #expect(RelinkComparison.panelPrompt(for: "tr2.wav") == "Choose the recording to use for “tr2.wav”")
    }
}

@Suite("Download controls")
struct DownloadControlTests {
    @Test func actionsFollowTheTransferCatalog() {
        #expect(TransferAction.available(transfer: .idle, residency: .cloudOnly, pauseSupported: false) == [.download])
        #expect(TransferAction.available(transfer: .idle, residency: .local, pauseSupported: false) == [])
        #expect(TransferAction.available(transfer: .downloadsOff, residency: .cloudOnly, pauseSupported: false) == [.download])
        #expect(TransferAction.available(transfer: .downloading(fraction: 0.5), residency: .cloudOnly, pauseSupported: false) == [.cancel])
        #expect(TransferAction.available(transfer: .downloading(fraction: 0.5), residency: .cloudOnly, pauseSupported: true) == [.pause, .cancel])
        #expect(TransferAction.available(transfer: .noConnection, residency: .cloudOnly, pauseSupported: false) == [.retry])
        #expect(TransferAction.available(transfer: .failed(reason: "x"), residency: .cloudOnly, pauseSupported: false) == [.retry])
        #expect(TransferAction.download.buttonTitle(for: .cancelled) == "Download Again")
        #expect(TransferAction.cancelNeedsConfirmation(.downloading(fraction: nil)))
        #expect(!TransferAction.cancelNeedsConfirmation(.queued))
    }

    @Test func episodeProgressIsOnlyDeterminateWhenEveryFractionWasReported() {
        let known = [SourceStatusSnapshot(transfer: .downloading(fraction: 0.2)), SourceStatusSnapshot(transfer: .downloading(fraction: 0.6)), SourceStatusSnapshot(transfer: .idle)]
        let p = EpisodeDownloadProgress(statuses: known)
        #expect(p?.activeCount == 2)
        #expect(p?.text == "Downloading 2 sources — 40%")
        let unknown = EpisodeDownloadProgress(statuses: known + [SourceStatusSnapshot(transfer: .queued)])
        #expect(unknown?.fraction == nil)
        #expect(unknown?.text == "Downloading 3 sources — progress unknown")
        #expect(EpisodeDownloadProgress(statuses: [SourceStatusSnapshot()]) == nil)
        #expect(EpisodeDownloadProgress.offExplanation(notDownloadedCount: 2) == "2 sources aren't downloaded. Downloads are Off: WaveWrangler will use file details only and won't download them.")
    }

    @Test func preferenceDefaultsOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "ww-tests-\(UUID().uuidString)"))
        let preference = UserDefaultsSourceDownloadPreference(defaults: defaults)
        #expect(preference.downloadsAutomatically)
        preference.downloadsAutomatically = false
        #expect(!UserDefaultsSourceDownloadPreference(defaults: defaults).downloadsAutomatically)
    }

    @Test func undoNamesMatchTheRegister() {
        #expect(SetupUndoName.importSources(9) == "Import 9 Sources")
        #expect(SetupUndoName.assignToGroup("Zoom H6") == "Assign to Group “Zoom H6”")
        #expect(SetupUndoName.changePrimary("Ana") == "Change Primary for “Ana”")
        #expect(SetupUndoName.relink("tr2.wav") == "Relink “tr2.wav”")
    }
}

@Suite("In-memory engine")
struct InMemoryEngineTests {
    @Test func observeYieldsUpdatesAndRecordsCalls() async throws {
        let id = SourceID()
        let engine = InMemorySourceSetupEngine(statuses: [id: SourceStatusSnapshot(location: .known, access: .granted, residency: .cloudOnly, transfer: .idle, identity: .notChecked)])
        var iterator = engine.observe([id]).makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?[id]?.residency == .cloudOnly)
        await engine.perform(.download, on: id)
        let second = await iterator.next()
        #expect(second?[id]?.transfer == .queued)
        #expect(engine.calls == [.perform(.download, id)])
    }
}
