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
        #expect(source.contains("guard let originatingItem, FileItemIdentity.observe(at: url) == originatingItem"))
        #expect(source.contains("if !isDocumentEdited { updateChangeCount(.changeDone) }"))
        let toolbar = try String(contentsOf: Self.documentSource.deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Workspace/WorkspaceToolbar.swift"), encoding: .utf8)
        #expect(toolbar.contains("Button(\"Discard…\") { state.discardPrior(prior) }"))
        #expect(toolbar.contains("Storage use can grow without a limit until you discard them individually."))
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
