import AppKit
import Foundation
import Testing
import WWCore
import WWPersistence

@MainActor
@Suite("Cross-show recovery choices", .serialized)
struct RecoveryChoiceNativeTests {
    private struct ReusedPath {
        let folder: URL
        let original: URL
        let moved: URL
        let recovery: RecoveryStore
        let aKey: DocumentKey
        let bKey: DocumentKey
        let aBytes: Data
        let damagedBytes = Data("damaged replacement".utf8)
        let aDraft: Data
        let bDraft: Data

        init(savedPriors: Bool) throws {
            folder = FileManager.default.temporaryDirectory.appending(path: "WWRecoveryChoices-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            original = folder.appending(path: "Reused.wwshow")
            moved = folder.appending(path: "Moved A.wwshow")
            recovery = RecoveryStore(root: folder.appending(path: "Recovery"))
            let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
            let publisher = DocumentPublisher(coder: coder, recovery: recovery)
            let a = ShowDocumentModel.untitled(
                id: ShowID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), title: "Earlier A")
            let b = ShowDocumentModel.untitled(
                id: ShowID(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!), title: "Later B")
            aKey = .show(a.show.id)
            bKey = .show(b.show.id)
            let aFirst = try publisher.publish(a, revision: 1, key: aKey, to: original, target: .newLocation)
            let aBase = savedPriors
                ? try publisher.publish(a.renamingShow(to: "A later save"), revision: 2, key: aKey,
                                        to: original, target: .inPlace(expectedBase: aFirst.fingerprint)).fingerprint
                : aFirst.fingerprint
            aBytes = try Data(contentsOf: original)
            try FileManager.default.moveItem(at: original, to: moved)
            let bFirst = try publisher.publish(b, revision: 1, key: bKey, to: original, target: .newLocation)
            let bBase = savedPriors
                ? try publisher.publish(b.renamingShow(to: "B later save"), revision: 2, key: bKey,
                                        to: original, target: .inPlace(expectedBase: bFirst.fingerprint)).fingerprint
                : bFirst.fingerprint
            aDraft = try coder.encode(a.renamingShow(to: "A unsaved"), revision: 3)
            bDraft = try coder.encode(b.renamingShow(to: "B unsaved"), revision: 3)
            let now = Date()
            try recovery.writeEditCheckpoint(snapshot: aDraft, base: aBase, schemaVersion: SchemaVersion.show,
                                             for: aKey, at: now.addingTimeInterval(60))
            try recovery.writeEditCheckpoint(snapshot: bDraft, base: bBase, schemaVersion: SchemaVersion.show,
                                             for: bKey, at: now.addingTimeInterval(120))
            try damagedBytes.write(to: original)
        }

        func offer() -> NSError {
            DocumentRecoveryOffer.error(for: .malformed("damaged"),
                candidates: DocumentOpener.show(recovery: recovery).candidates(url: original, key: nil),
                recovery: recovery, url: original)
        }

        func unchanged() throws {
            #expect(try Data(contentsOf: original) == damagedBytes)
            #expect(try Data(contentsOf: moved) == aBytes)
            #expect(recovery.offeredEditCheckpoints(for: aKey).count == 1)
            #expect(recovery.offeredEditCheckpoints(for: bKey).count == 1)
        }
    }

    @Test func onlyC2bCopiesAtAReusedPathSelectLaterBWithoutReturn() throws {
        let fixture = try ReusedPath(savedPriors: false)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let offer = fixture.offer()
        let labels = try #require(offer.localizedRecoveryOptions)
        #expect(labels.count == 3)
        #expect(labels[0].contains("FFFFFFFF") && labels[0].contains("Created") && labels[0].contains("⌘1"))
        #expect(labels[1].contains("00000000") && labels[1].contains("Created") && labels[1].contains("⌘2"))
        #expect(!labels.joined().contains("Newest") && !labels.joined().contains("Open Unsaved Copy 1"))
        let panel = OpaqueErrorPanel(error: offer)
        #expect(panel.defaultButtonCell == nil && panel.content.defaultIndex == nil)
        #expect(panel.optionButtons[0].keyEquivalent == "1")
        #expect(panel.optionButtons[0].keyEquivalentModifierMask == .command)
        let attempter = try #require(offer.recoveryAttempter as? DocumentRecoveryOffer.RecoveryAttempter)
        guard case let .unsaved(bSelection) = attempter.actions[0] else {
            Issue.record("⌘1 must select B's exact C2b record")
            return
        }
        #expect(bSelection.key == fixture.bKey)
        let selected = try EditCheckpointRecord.decode(fixture.recovery.readSelectedRecord(bSelection))
        #expect(selected.snapshot == fixture.bDraft)
        try fixture.unchanged()
    }

    @Test func savedAndUnsavedCopiesShareOneOrderAndIdentityBoundActions() throws {
        let fixture = try ReusedPath(savedPriors: true)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let offer = fixture.offer()
        let labels = try #require(offer.localizedRecoveryOptions)
        #expect(labels.count == 5)
        #expect(labels[0].contains("FFFFFFFF") && labels[0].contains("Created"))
        #expect(labels[1].contains("00000000") && labels[1].contains("Created"))
        #expect(labels[2].contains("FFFFFFFF") && labels[2].contains("Saved"))
        #expect(labels[3].contains("00000000") && labels[3].contains("Saved"))
        #expect(labels.prefix(4).enumerated().allSatisfy { $0.element.contains("⌘\($0.offset + 1)") })
        let panel = OpaqueErrorPanel(error: offer)
        #expect(panel.defaultButtonCell == nil && panel.content.defaultIndex == nil)
        let attempter = try #require(offer.recoveryAttempter as? DocumentRecoveryOffer.RecoveryAttempter)
        guard case let .unsaved(bDraft) = attempter.actions[0],
              case let .prior(bSaved, _) = attempter.actions[2] else {
            Issue.record("B's chosen draft and saved prior must remain independently selectable")
            return
        }
        #expect(bDraft.key == fixture.bKey && bSaved.key == fixture.bKey)
        #expect(try EditCheckpointRecord.decode(fixture.recovery.readSelectedRecord(bDraft)).snapshot == fixture.bDraft)
        #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(fixture.recovery.readSelectedRecord(bSaved))
            .payload.show.title == "Later B")
        #expect(try fixture.recovery.checkedCheckpoints(for: fixture.aKey).count == 1)
        #expect(try fixture.recovery.checkedCheckpoints(for: fixture.bKey).count == 1)
        try fixture.unchanged()
    }

    @Test func allRecoveryPresentersConsumeTheSharedPlanInsteadOfIndependentOrdering() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sites: [(String, String, String, String)] = [
            ("Packages/WaveWranglerKit/Sources/WWPersistence/DocumentOpener.swift",
             "public func candidates(", "\n    }\n}", "RecoveryChoicePresentation.plan("),
            ("WaveWrangler/Document/ShowDocument.swift",
             "func refreshEditCheckpointOffer()", "var selectedEditCheckpointCandidate:", "RecoveryChoicePresentation.plan("),
            ("WaveWrangler/Document/ShowDocument.swift",
             "func refreshPriorCheckpoints()", "func openPriorAsCopy(", "RecoveryChoicePresentation.plan("),
            ("WaveWrangler/Document/ShowDocument.swift",
             "static func error(", "final class RecoveryAttempter:", "RecoveryChoicePresentation.plan("),
            ("Packages/WaveWranglerKit/Sources/WWOrganizer/EditCheckpointOffer.swift",
             "public init(", "public static func confirmation(", "RecoveryChoicePresentation"),
            ("WaveWrangler/Workspace/EditCheckpointOfferBridge.swift",
             "var editCheckpointOfferState:", "func selectedEditCheckpointForDiscard()", "RecoveryChoicePresentation"),
            ("WaveWrangler/Workspace/ShowWorkspaceView.swift",
             "private struct ShowMessageBar:", "// MARK: - Window binding", "RecoveryChoicePresentation"),
            ("WaveWrangler/Workspace/MessageBar.swift",
             "var body: some View", "\n    }\n}", "RecoveryChoicePresentation"),
            ("WaveWrangler/Workspace/WorkspaceToolbar.swift",
             "private struct SaveStatusPopover:", "private struct PopoverAccessibilityLabel:", "RecoveryChoicePresentation"),
            ("WaveWrangler/Commands/OpaqueErrorPanel.swift",
             "private func buildContent()", "private static func label(", "RecoveryChoicePresentation"),
        ]
        for (path, start, end, required) in sites {
            let source = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            let begin = try #require(source.range(of: start), "\(path) lost \(start)")
            let finish = try #require(source.range(of: end, range: begin.upperBound..<source.endIndex), "\(path) lost \(end)")
            let presenter = source[begin.lowerBound..<finish.lowerBound]
            #expect(presenter.contains(required), "\(path): \(start) bypasses the shared recovery plan")
        }
    }
}
