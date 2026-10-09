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

    @Test func nativeEpisodeDeletionUsesStoreOwnedTransactionNotGenericMapMutation() throws {
        let store = try String(contentsOf: Self.appFolder.appending(path: "Document/ShowDocumentStore.swift"), encoding: .utf8)
        let command = try String(contentsOf: Self.appFolder.appending(path: "Workspace/ShowWindowState.swift"), encoding: .utf8)
        #expect(store.contains("let updated = try model.deletingEpisode(id, actionName: actionName)"))
        #expect(store.contains("guard updated.editMaps == model.editMaps else"))
        #expect(store.contains("guard newModel.editMaps == model.editMaps else"))
        #expect(command.contains("store.removeEpisode(episode.id, actionName: UndoActionName.deleteEpisode)"))
    }

    @Test func recoveryCopyAndDontSaveCannotAutomaticallyDeleteOriginalOffer() throws {
        let document = try String(contentsOf: Self.appFolder.appending(path: "Document/ShowDocument.swift"), encoding: .utf8)
        let saveResolution = try #require(document.range(of: "private func resolveOfferRecordsAfterVerifiedSave("))
        let afterResolution = try #require(document[saveResolution.upperBound...].range(of: "\n    fileprivate func offerCopyWasSaved("))
        let body = document[saveResolution.lowerBound..<afterResolution.lowerBound]
        #expect(body.contains("restoredOffers.resolvedAfterVerifiedOriginSave("))
        #expect(body.contains("try recovery.discardOfferedEditCheckpoints(Array(contained), for: documentKey)"))
        #expect(!body.contains("discardOfferedEditCheckpoints(resolution.urls"))
        let close = try #require(document.range(of: "override func close()"))
        let afterClose = try #require(document[close.upperBound...].range(of: "\n    // MARK: - Provider versions"))
        #expect(!document[close.lowerBound..<afterClose.lowerBound].contains("discardOfferedEditCheckpoints"))
    }

    @Test func showDocumentBindsCheckpointResolutionToVerifiedOriginFile() throws {
        let source = try String(contentsOf: Self.appFolder.appending(path: "Document/ShowDocument.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "private func resolveOfferRecordsAfterVerifiedSave("))
        let end = try #require(source[start.upperBound...].range(of: "\n    fileprivate func offerCopyWasSaved("))
        let resolution = source[start.lowerBound..<end.lowerBound]
        #expect(resolution.contains("PresenterFileCoordination(presenter: self)"))
        #expect(resolution.contains("receipt.url.standardizedFileURL == origin.url.standardizedFileURL"))
        #expect(resolution.contains("saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation"))
        #expect(resolution.contains("restoredAtSaveStart.copyIntentSerial == copyIntentSerial"))
        #expect(source.contains("override func saveAs(_ sender: Any?)"))
        #expect(source.contains("copyRetryGate.begin(retryPending: saveRetry != nil)"))
    }

    /// #126: windowless error presentation is routed to the opaque panel by `WaveWranglerApplication`, so it
    /// must be the app's NSApp: the principal class in every configuration, and the first `shared` in main().
    @Test func applicationClassIsWaveWranglerApplication() throws {
        let project = try String(contentsOf: Self.appFolder.deletingLastPathComponent().appending(path: "WaveWrangler.xcodeproj/project.pbxproj"), encoding: .utf8)
        let principal = project.components(separatedBy: "\n").filter { $0.contains("INFOPLIST_KEY_NSPrincipalClass") }
        // The app (Debug, Release) uses WaveWranglerApplication; the UI test bundle (Debug, Release) uses its
        // per-class isolation observer, WWUITestIsolation. Nothing else sets a principal class.
        #expect(principal.count == 4)
        #expect(principal.filter { $0.contains("= WaveWranglerApplication;") }.count == 2)
        #expect(principal.filter { $0.contains("= WWUITestIsolation;") }.count == 2)
        let app = try String(contentsOf: Self.appFolder.appending(path: "App/WaveWranglerApplication.swift"), encoding: .utf8)
        #expect(app.contains("@objc(WaveWranglerApplication)\nfinal class WaveWranglerApplication: NSApplication"))
        let main = try String(contentsOf: Self.appFolder.appending(path: "App/AppDelegate.swift"), encoding: .utf8)
        let entry = try #require(main.range(of: "static func main() {"))
        let firstShared = try #require(main[entry.upperBound...].range(of: ".shared"))
        #expect(main[entry.upperBound..<firstShared.upperBound].hasSuffix("WaveWranglerApplication.shared"))
    }
}

/// UI-test hooks (isolated storage, distributed autosave toggles) must never be active in Release builds.
/// This unhosted bundle checks the source guards; the Release binary was also verified to contain none of
/// the hook strings (`strings` on `scripts/build.sh Release` output).
@Suite("UI-test hooks are Debug-only")
struct UITestHooksDebugOnlyTests {
    static func source(_ path: String) throws -> String {
        try String(contentsOf: AppConfigurationTests.appFolder.appending(path: path), encoding: .utf8)
    }

    @Suite("Alignment runtime boundaries")
    struct AlignmentRuntimeBoundaryTests {
        static let runtimeURL = AppConfigurationTests.appFolder
            .appending(path: "Alignment/AlignmentRuntime.swift")

        static func runtimeSource() throws -> String {
            try String(contentsOf: runtimeURL, encoding: .utf8)
        }

        /// #219 review, finding 1: both whole-model replacements are computed from a snapshot across awaits,
        /// so neither may publish without the store's `expecting:` check against the live model.
        @Test func wholeModelReplacementsAreGuardedAgainstConcurrentEdits() throws {
            let source = try UITestHooksDebugOnlyTests.source("Alignment/EpisodeAlignmentModel.swift")
            let calls = source.components(separatedBy: "store.applyReplacement(").dropFirst()
            #expect(calls.count == 2, "the split and the accept are the only whole-model replacements")
            for call in calls {
                #expect(call.prefix(200).contains("expecting: prior,"))
            }
            let store = try UITestHooksDebugOnlyTests.source("Document/ShowDocumentStore.swift")
            #expect(store.contains("SharedModelPublication.decide(live: model, expected: expected) == .publish"))
        }

        @Test func inspectionNeverActivatesTheMutableLiveModel() throws {
            let source = try Self.runtimeSource()
            let start = try #require(source.range(of: "func inspect("))
            let end = try #require(source[start.upperBound...].range(of: "\n    func analyse("))
            let body = source[start.lowerBound..<end.lowerBound]
            #expect(!body.contains("activate("))
        }

        @Test func derivedStoreFilesystemInitializationIsDetachedFromMainActor() throws {
            let source = try Self.runtimeSource()
            let store = try #require(source.range(of: "DerivedAssetStore(root:"))
            let detached = try #require(source[..<store.lowerBound].range(
                of: "Task.detached(priority: .userInitiated)",
                options: .backwards
            ))
            let factory = try #require(source[..<detached.lowerBound].range(
                of: "nonisolated static func make(",
                options: .backwards
            ))
            #expect(factory.lowerBound < detached.lowerBound)
        }

        @Test func uncertainPublicationAdoptionReconcilesItsVerifiedRevision() throws {
            let source = try UITestHooksDebugOnlyTests.source("Document/ShowDocument.swift")
            let start = try #require(source.range(of: "private func adoptUncertainPublication()"))
            let end = try #require(source[start.upperBound...].range(of: "\n    override func writeSafely("))
            let body = source[start.lowerBound..<end.lowerBound]
            #expect(body.contains("verifiedModel = document.payload"))
            #expect(body.contains("AlignmentRuntimeProvider.reconcileActive(for: self)"))

            let runtime = try Self.runtimeSource()
            #expect(runtime.contains("documentID: ObjectIdentifier(document),\n                publication: publication"))
            #expect(runtime.contains("let published = try await reconciler.reconcile("))
            #expect(runtime.contains("openedDocuments.retry(episode: episodeID, documentID: documentID, publication: publication)"))
            #expect(runtime.contains("if !(error is CancellationError)"))
            #expect(runtime.contains("if published {"))
            #expect(runtime.contains("private func publicationReconciler(for episodeID: EpisodeID)"))
            #expect(runtime.contains("if episode.alignment?.acceptedRevision != nil {"))
            #expect(!runtime.contains("episode.alignment?.acceptedRevision != nil\n        else { return }"))
            #expect(!runtime.contains("guard episode.alignment?.acceptedRevision != nil else { return }"))

            let modelActivationStart = try #require(runtime.range(
                of: "func activate(model: ShowDocumentModel, episode episodeID: EpisodeID) async throws {"
            ))
            let acceptedActivationStart = try #require(runtime[modelActivationStart.upperBound...].range(
                of: "\n    func activate(_ accepted: AcceptedAlignment) async throws {"
            ))
            let openedActivationStart = try #require(runtime[acceptedActivationStart.upperBound...].range(
                of: "\n    /// Reconciles only the model"
            ))
            let modelActivation = runtime[modelActivationStart.lowerBound..<acceptedActivationStart.lowerBound]
            let acceptedActivation = runtime[acceptedActivationStart.lowerBound..<openedActivationStart.lowerBound]
            #expect(modelActivation.contains("let reconciler = publicationReconciler(for: episodeID)"))
            #expect(modelActivation.contains("_ = try await reconciler.reconcile("))
            #expect(acceptedActivation.contains("let reconciler = publicationReconciler(for: episodeID)"))
            #expect(acceptedActivation.contains("_ = try await reconciler.reconcile("))
        }

    }

    @Test func hooksTypeIsCompiledOnlyInDebug() throws {
        let lines = try Self.source("Document/UITestHooks.swift").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let code = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != "import Foundation" }
        #expect(code.first == "#if DEBUG", "everything after the import is inside #if DEBUG")
        #expect(code.last == "#endif")
        #expect(code.filter { $0.hasPrefix("#if") || $0.hasPrefix("#endif") || $0.hasPrefix("#else") }.count == 2)
    }

    @Test func environmentIgnoresHooksOutsideDebug() throws {
        let source = try Self.source("Document/PersistenceEnvironment.swift")
        let isUITestRun = try #require(source.range(of: "static let isUITestRun: Bool = {"))
        let body = String(source[isUITestRun.upperBound...].prefix(260))
        #expect(body.contains("#if DEBUG") && body.contains("#else\n        return false"), "Release returns false")
        let install = try #require(source.range(of: "UITestHooks.installIfRequested(self)"))
        let before = source[..<install.lowerBound].suffix(40)
        #expect(before.contains("#if DEBUG"))
        // Every other reference to UITestHooks must also sit inside a DEBUG block.
        let references = source.components(separatedBy: "UITestHooks.").count - 1
        #expect(references == 2, "only the two guarded references")
    }
}
