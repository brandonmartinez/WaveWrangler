import AVFoundation
import CryptoKit
import Foundation
import Testing
import WWCore
import WWOrganizer
import WWSpeech
@testable import WaveWrangler

@MainActor
@Suite("App-wide Whisper models", .serialized)
struct TranscriptionSettingsTests {
    private func fixture() throws -> (TranscriptionSettings, UserDefaults, URL) {
        let defaults = try #require(UserDefaults(suiteName: "ww.whisper.test.\(UUID().uuidString)"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ww-models-\(UUID().uuidString)")
        return (TranscriptionSettings(defaults: defaults, directory: directory), defaults, directory)
    }

    @Test func defaultsAreGlobalButNeverStartDownloadsOrCreateStorage() throws {
        let (settings, defaults, directory) = try fixture()
        #expect(settings.selection == .turbo)
        #expect(settings.backend == .automatic && settings.threads == .four)
        #expect(settings.available.isEmpty && settings.selectedURL == nil && !settings.isBusy)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(defaults.object(forKey: PreferenceKey.whisperModel) == nil)
        settings.selection = .baseEnglish
        let reopened = TranscriptionSettings(defaults: defaults, directory: directory)
        #expect(reopened.selection == .baseEnglish)
        #expect(!reopened.isBusy && reopened.selectedURL == nil)
        #expect(SettingsPane.allCases.contains(.transcription))
    }

    @Test(arguments: LocalWhisperWeights.allCases)
    func everyModelPreferenceReopensWithoutDownloadingOrRetargetingCapturedRecipes(_ weights: LocalWhisperWeights) throws {
        let (settings, defaults, directory) = try fixture()
        settings.selection = weights
        let capturedWeights = settings.selection
        let capturedConfiguration = try settings.captureConfiguration()
        let recipe = capturedConfiguration.revision(weights: capturedWeights)
        #expect(recipe.contains("/\(weights.rawValue)/\(weights.sha256)/"))
        settings.selection = weights == .turbo ? .baseEnglish : .turbo
        #expect(capturedConfiguration.revision(weights: capturedWeights) == recipe)
        defaults.set(weights.rawValue, forKey: PreferenceKey.whisperModel)
        let reopened = TranscriptionSettings(defaults: defaults, directory: directory)
        #expect(reopened.selection == weights && reopened.error == nil)
        #expect(reopened.available.isEmpty && reopened.selectedURL == nil && !reopened.isBusy)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func unsupportedModelPreferenceIsSurfacedWithoutADownload() throws {
        let (_, defaults, directory) = try fixture()
        defaults.set("unknown-model", forKey: PreferenceKey.whisperModel)
        let settings = TranscriptionSettings(defaults: defaults, directory: directory)
        #expect(settings.selection == .turbo)
        #expect(settings.error?.contains("saved model is unsupported") == true)
        #expect(!settings.isBusy && settings.available.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func hardwareThreadsPersistWhileCapturedJobsNeverRetarget() throws {
        let (_, defaults, directory) = try fixture()
        let settings = TranscriptionSettings(defaults: defaults, directory: directory, metalAvailable: true)
        settings.backend = .metal
        settings.threads = .two
        let captured = try settings.captureConfiguration()
        let recipe = captured.revision(weights: .turbo)
        settings.backend = .cpu
        settings.threads = .eight
        #expect(captured.backend == .metal && captured.threads == .two)
        #expect(captured.revision(weights: .turbo) == recipe)
        let reopened = TranscriptionSettings(defaults: defaults, directory: directory, metalAvailable: false)
        #expect(reopened.backend == .cpu && reopened.threads == .eight)
        reopened.backend = .metal
        #expect(reopened.backendStatus.contains("unavailable"))
        #expect(throws: TranscriptionConfigurationError.metalUnavailable) { try reopened.captureConfiguration() }
        reopened.backend = .automatic
        #expect(try reopened.captureConfiguration().backend == .cpu)
        defaults.set("neural", forKey: PreferenceKey.transcriptionBackend)
        defaults.set(99, forKey: PreferenceKey.transcriptionThreads)
        let invalid = TranscriptionSettings(defaults: defaults, directory: directory)
        #expect(invalid.backend == .automatic && invalid.threads == .four)
        #expect(invalid.error?.contains("unsupported") == true)
        invalid.backend = .cpu
        #expect(invalid.error == nil, "Choosing a supported backend clears the recovered preference error")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_ASR_ACCELERATION_FIXTURES"] != nil))
    func signedAppBundleRunsMetalFromItsOwnResourcesOffline() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WW_ASR_ACCELERATION_FIXTURES"]))
        let url = root.appendingPathComponent("clips/ami-01.wav")
        try #require(SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                     == "56f4b4abd278c61426b7ec4c844c5aff1420204a7b18ac7976321f8dc26c9b83")
        let audio = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
            frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let values = try #require(buffer.floatChannelData?[0])
        let pcm = Array(UnsafeBufferPointer(start: values, count: Int(buffer.frameLength)))
        let configuration = try TranscriptionConfiguration.resolve(backend: .metal, threads: .four)
        let engine = try await LocalWhisper.load(url: root.appendingPathComponent("downloads/\(LocalWhisperWeights.baseEnglish.filename)"),
                                                weights: .baseEnglish, configuration: configuration)
        let result = try await engine.transcribeWindow(pcm: pcm, sampleRate: 16_000)
        #expect(result.segments.map(\.text).joined(separator: " ").lowercased().contains("meeting"))
    }

    @Test func workerSelectionPersistsAndAllEpisodeWindowsUseTheSamePool() async throws {
        let (settings, defaults, directory) = try fixture()
        #expect(settings.concurrency == .one, "Preserve the former serial resource use until explicitly changed")
        settings.concurrency = .two
        #expect(defaults.integer(forKey: PreferenceKey.transcriptionWorkers) == 2)
        let pool = await settings.configuredWorkerPool()
        #expect(await pool.snapshot.limit == 2)
        let reopened = TranscriptionSettings(defaults: defaults, directory: directory)
        #expect(reopened.concurrency == .two)
        let a = Episode(title: "A"), b = Episode(title: "B")
        let state = ShowWindowState(store: ShowDocumentStore(
            model: ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [a, b])))
        let first = EpisodeCleanupModel(state: state, episodeID: a.id, transcriptionSettings: settings)
        let second = EpisodeCleanupModel(state: state, episodeID: b.id, transcriptionSettings: settings)
        defer { first.cancel(); second.cancel() }
        #expect(first.transcriptionSettings.workerPool === second.transcriptionSettings.workerPool)
        #expect(first.transcriptionSettings.concurrency == .two && second.transcriptionSettings.concurrency == .two)
        defaults.set(99, forKey: PreferenceKey.transcriptionWorkers)
        let invalid = TranscriptionSettings(defaults: defaults, directory: directory)
        #expect(invalid.concurrency == .one)
        #expect(invalid.error?.contains("unsupported") == true)
    }

    @Test func previousBookmarkRemainsUsableWithoutSelectingAFileAgain() throws {
        let (_, defaults, directory) = try fixture()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(LocalWhisperWeights.baseEnglish.filename)
        try Self.sparseModel(file, weights: .baseEnglish)
        let bookmark = try file.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: TranscriptionSettings.legacyBookmarkKey)
        let settings = TranscriptionSettings(defaults: defaults, directory: directory.appendingPathComponent("managed"))
        #expect(settings.selection == .baseEnglish)
        #expect(settings.selectedURL == file)
        #expect(settings.error == nil)
        #expect(!FileManager.default.fileExists(atPath: settings.directory.path))
    }

    @Test(arguments: LocalWhisperWeights.allCases)
    func successfulInstallationIsSharedAndPersistsAcrossSettingsInstances(_ weights: LocalWhisperWeights) async throws {
        let (settings, defaults, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        settings.selection = weights
        settings.download(fetch: { weights, target, report in
            try Self.sparseModel(target, weights: weights)
            report(Int64(weights.byteCount))
        }, verify: { url, weights in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            #expect(size == weights.byteCount)
        })
        try await wait { !settings.isBusy }
        #expect(settings.error == nil)
        #expect(settings.available == [weights])
        let installed = try #require(settings.selectedURL)
        #expect(installed.lastPathComponent == weights.filename)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [installed.lastPathComponent])
        let reopened = TranscriptionSettings(defaults: defaults, directory: directory)
        #expect(reopened.selectedURL == installed)
        settings.download(fetch: { weights, target, _ in
            try Self.sparseModel(target, weights: weights)
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data([42]))
        }, verify: { _, _ in })
        try await wait { !settings.isBusy }
        #expect(settings.error == nil, "Atomic replacement also supports an explicit re-download")
        let handle = try FileHandle(forReadingFrom: installed)
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: 1) == Data([42]))
        settings.selection = weights == .turbo ? .baseEnglish : .turbo
        #expect(settings.selectedURL == nil, "Selecting an uninstalled model never uses other weights silently")
    }

    @Test func episodeWindowsReadOneSharedPreferenceWithoutEditingTheirDocument() throws {
        let (settings, _, directory) = try fixture()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        let a = Episode(title: "Synthetic A"), b = Episode(title: "Synthetic B")
        let document = ShowDocumentModel(show: Show(title: "Synthetic"), episodes: [a, b])
        let state = ShowWindowState(store: ShowDocumentStore(model: document))
        let first = EpisodeCleanupModel(state: state, episodeID: a.id, transcriptionSettings: settings)
        let second = EpisodeCleanupModel(state: state, episodeID: b.id, transcriptionSettings: settings)
        defer { first.cancel(); second.cancel() }
        settings.selection = .baseEnglish
        #expect(first.transcriptionSettings.selection == .baseEnglish)
        #expect(second.transcriptionSettings.selection == .baseEnglish)
        #expect(state.store.model == document)
    }

    @Test func failedVerificationPreservesExistingModelAndRemovesPartial() async throws {
        let (settings, _, directory) = try fixture()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appendingPathComponent(settings.selection.filename)
        let original = Data("previous model must survive a rejected replacement".utf8)
        try original.write(to: installed)
        settings.download(fetch: { _, target, _ in try Data("bad model".utf8).write(to: target) },
            verify: { _, _ in throw SpeechModelError.hashMismatch })
        try await wait { !settings.isBusy }
        #expect(settings.error?.contains("Model download failed") == true)
        #expect(try Data(contentsOf: installed) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [installed.lastPathComponent])
    }

    @Test(arguments: LocalWhisperWeights.allCases)
    func actualVerifierRejectsWrongSizeAndHashWithoutPublishing(_ weights: LocalWhisperWeights) async throws {
        let (settings, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        settings.selection = weights
        settings.download(fetch: { _, target, _ in try Data([1, 2, 3]).write(to: target) })
        try await wait { !settings.isBusy }
        #expect(settings.error?.contains("pinned size or SHA-256") == true && settings.available.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        settings.download(fetch: { weights, target, _ in try Self.sparseModel(target, weights: weights) })
        try await wait { !settings.isBusy }
        #expect(settings.error?.contains("pinned size or SHA-256") == true && settings.available.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func downloadVerificationQueuesInTheSamePoolAndCancelsBeforeLoading() async throws {
        let (settings, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pool = settings.workerPool
        let holder = Task {
            try await pool.withAdmission(resources: .init(memoryBytes: 10)) {
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { holder.cancel() }
        let activeDeadline = Date().addingTimeInterval(10)
        while await pool.snapshot.active < 1, Date() < activeDeadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await pool.snapshot.active == 1)
        settings.download(fetch: { _, target, _ in try Data([1, 2, 3]).write(to: target) })
        let deadline = Date().addingTimeInterval(10)
        while await pool.snapshot.waiting < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await pool.snapshot.waiting == 1)
        #expect(settings.isBusy && settings.isVerifying)
        settings.cancelDownload()
        try await wait { !settings.isBusy }
        #expect(settings.error == nil && settings.status.hasPrefix("Download canceled"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(await pool.snapshot.reservedBytes == 10)
        holder.cancel()
        await #expect(throws: CancellationError.self) { try await holder.value }
        #expect(await pool.snapshot.active == 0)
    }

    @Test func cancellationAndTransportFailuresDoNotInstallPartialModels() async throws {
        let (settings, _, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        settings.download(fetch: { _, target, _ in
            try Data([1]).write(to: target)
            try await Task.sleep(for: .seconds(30))
        })
        settings.cancelDownload()
        try await wait { !settings.isBusy }
        #expect(settings.status.hasPrefix("Download canceled"))
        #expect(settings.available.isEmpty && settings.error == nil)
        settings.download(fetch: { _, target, _ in
            try Data([1]).write(to: target)
            throw URLError(.notConnectedToInternet)
        })
        try await wait { !settings.isBusy }
        #expect(settings.error != nil && settings.available.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func sessionDownloadUsesPinnedURLAndChecksHTTPBeforeInstallation() async throws {
        let (_, _, directory) = try fixture()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelResponseProtocol.self]
        let target = directory.appendingPathComponent("download")
        let progress = Progress(totalUnitCount: 20)
        try await TranscriptionSettings.fetch(.baseEnglish, to: target, progress: { progress.completedUnitCount = $0 },
            configuration: configuration)
        #expect(try Data(contentsOf: target) == Data("public model fixture".utf8))
        #expect(progress.completedUnitCount == 20, "The real URLSession download delegate reports written bytes")
        await #expect(throws: (any Error).self) {
            try await TranscriptionSettings.fetch(.turbo, to: directory.appendingPathComponent("refused"),
                progress: { _ in }, configuration: configuration)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("refused").path))
    }

    @Test func cancelingAnActualSessionTaskEndsAnIncompleteTransfer() async throws {
        let (_, _, directory) = try fixture()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IncompleteModelProtocol.self]
        let target = directory.appendingPathComponent("canceled")
        let progress = Progress(totalUnitCount: 131_072)
        let task = Task {
            try await TranscriptionSettings.fetch(.baseEnglish, to: target,
                progress: { progress.completedUnitCount = $0 }, configuration: configuration)
        }
        defer { task.cancel() }
        try await wait { progress.completedUnitCount > 0 }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    nonisolated private static func sparseModel(_ url: URL, weights: LocalWhisperWeights) throws {
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(weights.byteCount))
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Timed out waiting for model operation")
    }
}

nonisolated private final class ModelResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let isBase = url == LocalWhisperWeights.baseEnglish.downloadURL
        let response = HTTPURLResponse(url: url, statusCode: isBase ? 200 : 503,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "20"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("public model fixture".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

nonisolated private final class IncompleteModelProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "131072"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 65_536))
    }
    override func stopLoading() {}
}
