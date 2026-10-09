import AppKit
import Foundation
import Testing
import WWCore
import WWPersistence

@MainActor
@Suite("Native recovery safety", .serialized)
struct CheckpointRetirementNativeTests {
    private static let documentSource = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "WaveWrangler/Document/ShowDocument.swift")

    @Test func saveRevertCloseAndCopyNeverDiscardRecoveryRecords() throws {
        let source = try String(contentsOf: Self.documentSource, encoding: .utf8)
        #expect(!source.contains("recovery.discardEditCheckpoints("))
        #expect(!source.contains("recovery.discardOfferedEditCheckpoints("))
        #expect(!source.contains("resolveOfferRecordsAfterVerifiedSave"))
        #expect(!source.contains("copy.resolvesOffer"))
        #expect(source.contains("override func writeSafely("))
        #expect(source.contains("expectedOriginItem: inPlace ? originatingItem : nil, requiresOriginIdentity: inPlace"))
        #expect(source.contains("if !isDocumentEdited { updateChangeCount(.changeDone) }"))
        let toolbar = try String(contentsOf: Self.documentSource.deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Workspace/WorkspaceToolbar.swift"), encoding: .utf8)
        #expect(toolbar.contains("Button(\"Discard…\") { state.discardPrior(prior) }"))
        #expect(toolbar.contains("Storage use can grow without a limit until you discard them individually."))
    }

    @Test func everyRetainedSessionHasNondestructiveSelectionAndBoundActions() throws {
        let document = try String(contentsOf: Self.documentSource, encoding: .utf8)
        let bridge = try String(contentsOf: Self.documentSource.deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Workspace/EditCheckpointOfferBridge.swift"), encoding: .utf8)
        let presentation = try String(contentsOf: Self.documentSource.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packages/WaveWranglerKit/Sources/WWOrganizer/EditCheckpointOffer.swift"), encoding: .utf8)
        #expect(presentation.contains("case next = \"Next Recovery Copy\""))
        #expect(document.contains("selectedOfferURL"))
        #expect(document.contains("selectedOfferRecord"))
        #expect(bridge.contains("case .next:"))
    }

    @Test func damagedCanonicalFileReportsRetainedC2bAndOffersRawReveal() throws {
        let document = try String(contentsOf: Self.documentSource, encoding: .utf8)
        #expect(document.contains("checkedOfferedEditCheckpoints(for: key)"))
        #expect(document.contains("The recovery copy is damaged and cannot be restored"))
        #expect(document.contains("Show in Finder"))
        #expect(document.contains("NSWorkspace.shared.activateFileViewerSelecting"))
    }

    @Test func priorCopyDecodesOlderSchemasOrOffersRawRevealWithoutDeletion() throws {
        let document = try String(contentsOf: Self.documentSource, encoding: .utf8)
        let prior = try #require(document.range(of: "func openPriorAsCopy("))
        let discard = try #require(document.range(of: "func selectedPriorForDiscard(", range: prior.upperBound..<document.endIndex))
        let implementation = document[prior.lowerBound..<discard.lowerBound]
        #expect(implementation.contains("ShowSchemaMigration.decodeUpgradingOlder(bytes)"))
        #expect(implementation.contains("Show in Finder"))
        #expect(implementation.contains("NSRecoveryAttempterErrorKey"))
    }

    @Test func reusedLocationOffersLaterShowFirstWithoutDefaultingToAnUnverifiedNewest() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WWRecoveryOrder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "Reused.wwshow")
        let moved = folder.appending(path: "Moved.wwshow")
        let recovery = RecoveryStore(root: folder.appending(path: "Recovery"))
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let publisher = DocumentPublisher(coder: coder, recovery: recovery)
        let a = ShowDocumentModel.untitled(
            id: ShowID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), title: "Older A"
        )
        let b = ShowDocumentModel.untitled(
            id: ShowID(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!), title: "Later B"
        )
        let aKey = DocumentKey.show(a.show.id)
        let bKey = DocumentKey.show(b.show.id)
        let aFirst = try publisher.publish(a, revision: 1, key: aKey, to: path, target: .newLocation)
        _ = try publisher.publish(a.renamingShow(to: "A moved"), revision: 2, key: aKey, to: path,
                                  target: .inPlace(expectedBase: aFirst.fingerprint))
        try FileManager.default.moveItem(at: path, to: moved)
        let bFirst = try publisher.publish(b, revision: 1, key: bKey, to: path, target: .newLocation)
        _ = try publisher.publish(b.renamingShow(to: "B damaged"), revision: 2, key: bKey, to: path,
                                  target: .inPlace(expectedBase: bFirst.fingerprint))
        try Data("damaged".utf8).write(to: path)

        let candidates = DocumentOpener.show(recovery: recovery).candidates(url: path, key: nil)
        #expect(candidates.map(\.checkpoint.key) == [bKey, aKey])
        let bSavedAt = try #require(candidates.first?.checkpoint.savedAt)
        let aSavedAt = try #require(candidates.last?.checkpoint.savedAt)
        #expect(bSavedAt > aSavedAt)
        let error = DocumentRecoveryOffer.error(for: .malformed("damaged"), candidates: candidates, recovery: recovery, url: path)
        let names = try #require(error.localizedRecoveryOptions)
        #expect(names.count == 3)
        #expect(names.first?.contains("Saved") == true && names.first?.contains("Show") == true)
        #expect(names[1].contains("Saved") && names[1].contains("Show"))
        #expect(names[0].contains("FFFFFFFF") && names[1].contains("00000000"))
        #expect(names[0] != names[1] && !names.joined().contains("Newest"))
        #expect(OpaqueErrorContent(error: error).defaultIndex == nil)
        #expect(OpaqueErrorPresenter.route(for: error, window: .init(isVisible: true, isMiniaturized: false)) == .opaquePanel)
        let panel = OpaqueErrorPanel(error: error)
        #expect(panel.optionButtons.allSatisfy { $0.keyEquivalent != "\r" && !$0.title.isEmpty })
        #expect(panel.optionButtons.allSatisfy(\.isEnabled))
        #expect(panel.defaultButtonCell == nil && panel.initialFirstResponder === panel.optionButtons.last)
        let attempter = try #require(error.recoveryAttempter as? DocumentRecoveryOffer.RecoveryAttempter)
        guard case let .prior(first, _) = attempter.actions[0],
              case let .prior(second, _) = attempter.actions[1] else {
            Issue.record("Each show needs its own selectable retained copy")
            return
        }
        #expect(first.key == bKey && second.key == aKey)
        #expect(try coder.decode(recovery.readSelectedRecord(first)).payload.show.id == b.show.id)
        #expect(try Data(contentsOf: path) == Data("damaged".utf8))
    }

    @Test func missingAndTiedRecordedSaveDatesRequireAnExplicitRecoveryChoice() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WWRecoveryDate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "Damaged.wwshow")
        let recovery = RecoveryStore(root: folder.appending(path: "Recovery"))
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let model = ShowDocumentModel.untitled(title: "Missing save date")
        let key = DocumentKey.show(model.show.id)
        let first = try recovery.retainCheckpoint(coder.encode(model, revision: 1), for: key)
        try recovery.recordLocation(path, for: key)
        let opener = DocumentOpener.show(recovery: recovery)

        let unknown = DocumentRecoveryOffer.error(for: .malformed("damaged"),
            candidates: opener.candidates(url: path, key: nil), recovery: recovery, url: path)
        #expect(OpaqueErrorContent(error: unknown).defaultIndex == nil)
        #expect(unknown.localizedRecoveryOptions?.first?.contains("Saved date unknown") == true)
        #expect(unknown.localizedRecoveryOptions?.first?.contains(String(model.show.id.rawValue.uuidString.prefix(8))) == true)

        let second = try recovery.retainCheckpoint(coder.encode(model.renamingShow(to: "Another version"), revision: 2), for: key)
        let sameTime = Date(timeIntervalSince1970: 1_700_000_000)
        try recovery.recordVerifiedSave(first.fingerprint, for: key, at: sameTime)
        try recovery.recordVerifiedSave(second.fingerprint, for: key, at: sameTime)
        let tied = DocumentRecoveryOffer.error(for: .malformed("damaged"),
            candidates: opener.candidates(url: path, key: nil), recovery: recovery, url: path)
        let tiedLabels = try #require(tied.localizedRecoveryOptions)
        #expect(tiedLabels.count == 3 && tiedLabels[0] != tiedLabels[1])
        #expect(tiedLabels[0].contains("Saved 2023-") && tiedLabels[1].contains("Saved 2023-"))
        #expect(!tiedLabels.joined().contains("Newest"))
        #expect(OpaqueErrorContent(error: tied).defaultIndex == nil)
        #expect(try recovery.checkedCheckpoints(for: key).count == 2)
    }

    @Test func saveCopyDoesNotAdoptUnverifiedDestinationOrClearUndoAndOffers() throws {
        let source = try String(contentsOf: Self.documentSource, encoding: .utf8)
        let start = try #require(source.range(of: "private func saveCopy("))
        let end = try #require(source.range(of: "override func canClose(", range: start.upperBound..<source.endIndex))
        let copyFlow = source[start.lowerBound..<end.lowerBound]
        #expect(!copyFlow.contains("store.replaceLoadedModel(copy)"))
        #expect(!copyFlow.contains("undoManager?.removeAllActions()"))
        #expect(!copyFlow.contains("restoredOfferURLs.removeAll()"))
        #expect(!copyFlow.contains("status.setCopyNotice("))
        let finish = try #require(source.range(of: "private func finishSave("))
        let next = try #require(source.range(of: "private func acknowledgeToLibrary(", range: finish.upperBound..<source.endIndex))
        let finishFlow = source[finish.lowerBound..<next.lowerBound]
        #expect(finishFlow.contains("if let adoptingCopy"))
        #expect(finishFlow.contains("if result == nil, adopts, let receipt"))
        #expect(finishFlow.contains("(try? Data(contentsOf: url)) != candidateBytes"))
        #expect(source.contains("(try? Data(contentsOf: url)) != candidate.data"))
    }

    @Test(arguments: [true, false])
    func nativeSafeWriteVerificationErrorDoesNotClearDirtyState(initiallyDirty: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WWNativeRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Synthetic.wwshow")
        try Data("prior".utf8).write(to: url)
        let document = ReadBackProbe()
        document.fileURL = url
        if initiallyDirty { document.updateChangeCount(.changeDone) }

        let error = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: DocumentFormat.show.identifier, for: .saveOperation) {
                continuation.resume(returning: $0)
            }
        }
        #expect(error != nil)
        #expect(document.isDocumentEdited)
        #expect(document.fileURL == url)
        // The candidate might already be present: a verification failure is not a rollback.
        #expect(try Data(contentsOf: url) == Data("candidate".utf8))
    }

    private final class ReadBackProbe: NSDocument {
        override class var autosavesInPlace: Bool { false }
        override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { false }
        override func data(ofType typeName: String) throws -> Data { Data("candidate".utf8) }
        override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
            try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
            do {
                guard try Data(contentsOf: url) == Data("other".utf8) else {
                    throw PublicationError.acknowledgementUncertain("injected changed read-back")
                }
            } catch {
                if !isDocumentEdited { updateChangeCount(.changeDone) }
                throw error
            }
        }
    }
}
