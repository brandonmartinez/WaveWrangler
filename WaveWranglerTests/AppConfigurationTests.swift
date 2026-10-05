import Foundation
import Testing
import WWCore
import WWPersistence

/// Unhosted app-level checks (no app launch): the declared document types and sandbox entitlements stay
/// consistent with the persistence formats and the product's permission envelope.
@Suite("App configuration")
struct AppConfigurationTests {
    static let appFolder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "WaveWrangler")

    static func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: appFolder.appending(path: name))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test(arguments: [DocumentFormat.show, DocumentFormat.library])
    func exportsTypeForFormat(_ format: DocumentFormat) throws {
        let info = try Self.plist("Info.plist")
        let exported = try #require(info["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try #require(exported.first { $0["UTTypeIdentifier"] as? String == format.identifier })
        let tags = try #require(declaration["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == [try #require(format.filenameExtension)])
        let conforms = try #require(declaration["UTTypeConformsTo"] as? [String])
        #expect(conforms.contains("public.json"))
    }

    @Test func showDocumentTypeIsEditedByShowDocument() throws {
        let info = try Self.plist("Info.plist")
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let show = try #require(types.first { ($0["LSItemContentTypes"] as? [String])?.contains(DocumentFormat.show.identifier) == true })
        #expect(show["NSDocumentClass"] as? String == "ShowDocument")
        #expect(show["CFBundleTypeRole"] as? String == "Editor")
    }

    @Test func entitlementsAreSandboxedUserSelectedFilesWithBookmarksAndNoNetwork() throws {
        let entitlements = try Self.plist("WaveWrangler.entitlements")
        #expect(entitlements as NSDictionary == [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.files.user-selected.read-write": true,
            "com.apple.security.files.bookmarks.app-scope": true,
            "com.apple.security.files.bookmarks.document-scope": true,
        ] as NSDictionary)
    }

    @Test func showDocumentRoundTripsThroughAFileInATemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ww-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = try ShowDocumentModel.untitled().addingEpisode(Episode(title: "Synthetic", number: 1))
        let coder = JSONEnvelopeCoder<ShowDocumentModel>.show
        let url = directory.appending(path: "Synthetic.\(try #require(DocumentFormat.show.filenameExtension))")
        try coder.encode(model, revision: 1).write(to: url, options: .atomic)
        let decoded = try coder.decode(Data(contentsOf: url))
        #expect(decoded.payload == model)
        #expect(decoded.revision == 1)
    }
}
