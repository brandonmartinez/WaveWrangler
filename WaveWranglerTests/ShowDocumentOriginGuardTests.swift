import Foundation
import Testing
import WWCore
import WWOrganizer
import WWPersistence

@Suite("Show document originating item", .serialized)
struct ShowDocumentOriginGuardTests {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WWOriginGuard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func copyDestinationRefusesOriginAndEveryLocalAlias() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let origin = folder.appending(path: "Original.wwshow")
        try Data("original".utf8).write(to: origin)
        let item = try #require(FileItemIdentity.observe(at: origin))
        let symlink = folder.appending(path: "Linked.wwshow")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: origin)
        let hardlink = folder.appending(path: "Another Name.wwshow")
        try FileManager.default.linkItem(at: origin, to: hardlink)
        let alias = folder.appending(path: "Finder Alias.wwshow")
        try URL.writeBookmarkData(
            origin.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil),
            to: alias
        )
        #expect(try URL(resolvingAliasFileAt: alias, options: [.withoutUI, .withoutMounting]).standardizedFileURL
                == origin.standardizedFileURL)
        let different = folder.appending(path: "Different.wwshow")
        try Data("different".utf8).write(to: different)

        for destination in [origin, symlink, hardlink, alias] {
            #expect(ShowDocumentOriginGuard.isOriginatingDestination(destination, originURL: origin, originatingItem: item),
                    "\(destination.lastPathComponent) must not overwrite the originating file")
        }
        #expect(!ShowDocumentOriginGuard.isOriginatingDestination(different, originURL: origin, originatingItem: item))

        let caseVariant = folder.appending(path: "ORIGINAL.WWSHOW")
        if FileManager.default.fileExists(atPath: caseVariant.path) {
            #expect(ShowDocumentOriginGuard.isOriginatingDestination(caseVariant, originURL: origin, originatingItem: item))
        }
    }

    @Test func byteIdenticalSubstitutionBetweenReadAndIdentityPinIsRefusedWithoutLosingCheckpoint() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let origin = folder.appending(path: "Older.wwshow")
        let moved = folder.appending(path: "Moved.wwshow")
        let model = ShowDocumentModel.untitled()
        let bytes = try JSONEnvelopeCoder<ShowDocumentModel>.show.encodeDocument(model, revision: 1, publicationID: UUID()).data
        try bytes.write(to: origin)
        let openedItem = try #require(FileItemIdentity.observe(at: origin))
        let recovery = RecoveryStore(root: folder.appending(path: "Recovery", directoryHint: .isDirectory))
        let key = DocumentKey.show(model.show.id)
        let checkpoint = try recovery.retainCheckpoint(bytes, for: key)

        #expect(throws: PublicationError.self) {
            _ = try ShowDocumentOriginGuard.readPinned(at: origin) {
                try FileManager.default.moveItem(at: origin, to: moved)
                try bytes.write(to: origin)
            }
        }
        #expect(FileItemIdentity.observe(at: origin) != openedItem)
        #expect(try Data(contentsOf: origin) == bytes)
        #expect(try Data(contentsOf: moved) == bytes)
        #expect(try recovery.checkedCheckpoints(for: key).contains {
            $0.url.resolvingSymlinksInPath().path == checkpoint.url.resolvingSymlinksInPath().path
        })
        #expect(try Data(contentsOf: checkpoint.url) == bytes)
    }

    @Test func currentItemCanBeReadAndIndependentCopyCanBeChosen() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let origin = folder.appending(path: "Original.wwshow")
        let different = folder.appending(path: "Copy.wwshow")
        let bytes = Data("original".utf8)
        try bytes.write(to: origin)
        let pinned = try ShowDocumentOriginGuard.readPinned(at: origin)
        #expect(pinned.data == bytes)
        #expect(pinned.item == FileItemIdentity.observe(at: origin))
        #expect(!ShowDocumentOriginGuard.isOriginatingDestination(different, originURL: origin, originatingItem: pinned.item))
    }

    @Test func refusedCopyKeepsAnUnsavedAndExplicitlyExplainedStatus() {
        let reason = "Save a Copy Elsewhere needs a different file. WaveWrangler did not overwrite the original show or discard recovery copies."
        let state = WWPersistence.DocumentSaveState.originConflict(message: reason)
        let mapped = ShowDocumentStatusMapping.map(state, readOnlyReason: nil, autosaveEnabled: false, folderDisplayName: "Shows")
        #expect(mapped.hasUnsavedChanges)
        #expect(SaveStatusPresentation(mapped, showName: "Original").popoverText.contains(reason))
    }

    @Test func documentWiresTheGuardsBeforeTheSaveAndFormatUpdate() throws {
        let source = try String(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "WaveWrangler/Document/ShowDocument.swift"), encoding: .utf8)
        #expect(source.contains("ShowDocumentOriginGuard.readPinned(at: url)"))
        #expect(source.contains("originatingItem = openedItem"))
        #expect(source.components(separatedBy: "ShowDocumentOriginGuard.isOriginatingDestination(").count == 3,
                "check before Save a Copy and again at the safe-write boundary")
        #expect(source.contains("status.set(.originConflict(message: Self.copyOriginRefusal))"))
        #expect(source.contains("if !isDocumentEdited { updateChangeCount(.changeDone) }"))
        #expect(source.contains("migrator.migrate(url, key: key, originatingItem: openedItem)"))
    }
}
