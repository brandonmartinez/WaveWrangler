import Foundation
import Testing
import WWCore
@testable import WWPersistence

@Suite("Cross-show recovery choice integration", .serialized)
struct RecoveryChoiceIntegrationTests {
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

        func choices() throws -> (RecoveryChoicePresentation.Plan, [String: SelectedRecoveryRecord]) {
            let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
            let opener = DocumentOpener.show(recovery: recovery)
            let saved = opener.candidates(url: original, key: nil)
            var records: [RecoveryChoicePresentation.Record] = []
            var selections: [String: SelectedRecoveryRecord] = [:]
            for candidate in saved {
                let checkpoint = candidate.checkpoint
                let selected = try recovery.selectRecord(.priorCheckpoint, at: checkpoint.url, for: checkpoint.key)
                let id = selected.url.path
                selections[id] = selected
                records.append(.init(recordID: id, kind: .savedPrior,
                                     documentID: candidate.document.payload.show.id.rawValue.uuidString,
                                     savedAt: checkpoint.savedAt, createdAt: nil,
                                     revision: candidate.document.revision, disposition: .open))
            }
            for key in try recovery.checkedKeys(forLocation: original) {
                try recovery.setAsideEditCheckpoints(for: key)
                for stored in try recovery.checkedOfferedEditCheckpoints(for: key) {
                    guard case let .success(value) = stored.record else { continue }
                    let selected = try recovery.selectRecord(.offeredEditCheckpoint, at: stored.url, for: key)
                    let id = selected.url.path
                    selections[id] = selected
                    records.append(.init(recordID: id, kind: .unsavedCheckpoint,
                                         documentID: String(key.rawValue.dropFirst("show-".count)),
                                         savedAt: nil, createdAt: value.createdAt,
                                         revision: EnvelopeHeaderInfo.peek(value.snapshot)?.revision,
                                         disposition: .open))
                }
            }
            return (RecoveryChoicePresentation.plan(records: records), selections)
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
        let (plan, selections) = try fixture.choices()
        #expect(plan.choices.count == 2 && plan.defaultRecordID == nil)
        #expect(plan.choices.first?.record.documentID == String(fixture.bKey.rawValue.dropFirst("show-".count)))
        #expect(plan.choices.first?.label.contains("Created") == true)
        #expect(plan.choices.first?.shortcut == "⌘1")
        let first = try #require(plan.choices.first)
        let selected = try #require(selections[first.record.recordID])
        #expect(selected.key == fixture.bKey)
        #expect(try EditCheckpointRecord.decode(fixture.recovery.readSelectedRecord(selected)).snapshot == fixture.bDraft)
        try fixture.unchanged()
    }

    @Test func savedAndUnsavedCopiesShareOneOrderAndIdentityBoundActions() throws {
        let fixture = try ReusedPath(savedPriors: true)
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let (plan, selections) = try fixture.choices()
        #expect(plan.choices.count == 4 && plan.defaultRecordID == nil)
        #expect(plan.choices.map(\.record.kind) ==
                [.unsavedCheckpoint, .unsavedCheckpoint, .savedPrior, .savedPrior])
        #expect(plan.choices.map(\.record.documentID) ==
                [fixture.bKey, fixture.aKey, fixture.bKey, fixture.aKey].map {
                    String($0.rawValue.dropFirst("show-".count))
                })
        let bDraft = try #require(selections[plan.choices[0].record.recordID])
        let bSaved = try #require(selections[plan.choices[2].record.recordID])
        #expect(bDraft.key == fixture.bKey && bSaved.key == fixture.bKey)
        #expect(try EditCheckpointRecord.decode(fixture.recovery.readSelectedRecord(bDraft)).snapshot == fixture.bDraft)
        #expect(try JSONEnvelopeCoder<ShowDocumentModel>.show.decode(fixture.recovery.readSelectedRecord(bSaved))
            .payload.show.title == "Later B")
        #expect(try fixture.recovery.checkedCheckpoints(for: fixture.aKey).count == 1)
        #expect(try fixture.recovery.checkedCheckpoints(for: fixture.bKey).count == 1)
        try fixture.unchanged()
    }
}
