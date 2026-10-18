import Foundation
import Observation
import OSLog
import WWOrganizer
import WWSpeech

@MainActor
@Observable
final class TranscriptionSettings {
    static let shared = TranscriptionSettings()
    static let legacyBookmarkKey = "WWLocalWhisperModelBookmark"

    var backend: TranscriptionBackend {
        didSet {
            defaults.set(backend.rawValue, forKey: PreferenceKey.transcriptionBackend)
            error = nil
        }
    }
    var threads: TranscriptionThreads {
        didSet {
            defaults.set(threads.rawValue, forKey: PreferenceKey.transcriptionThreads)
            error = nil
        }
    }
    let metalAvailable: Bool
    var concurrency: TranscriptionConcurrency {
        didSet {
            defaults.set(concurrency.rawValue, forKey: PreferenceKey.transcriptionWorkers)
            workerConfigurationRevision += 1
            let revision = workerConfigurationRevision
            let concurrency = concurrency
            Task { await workerPool.configure(concurrency, revision: revision) }
        }
    }
    let workerPool: TranscriptionWorkerPool
    var selection: LocalWhisperWeights {
        didSet {
            defaults.set(selection.rawValue, forKey: PreferenceKey.whisperModel)
            error = nil
        }
    }
    private(set) var available: Set<LocalWhisperWeights> = []
    private(set) var isBusy = false
    private(set) var receivedBytes: Int64 = 0
    private(set) var isVerifying = false
    private(set) var downloading: LocalWhisperWeights?
    private(set) var status = "Models download only when you click Download. Transcription stays on this Mac."
    private(set) var error: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let directory: URL
    @ObservationIgnored private var legacy: (weights: LocalWhisperWeights, url: URL)?
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var transferID = UUID()
    @ObservationIgnored private var workerConfigurationRevision: UInt64 = 0

    init(defaults: UserDefaults = PersistenceEnvironment.preferences,
         directory: URL = URL.applicationSupportDirectory.appending(
            path: "\(PersistenceEnvironment.storageName)/WhisperModels", directoryHint: .isDirectory),
         metalAvailable: Bool = TranscriptionConfiguration.metalAvailable) {
        self.defaults = defaults
        self.directory = directory
        self.metalAvailable = metalAvailable
        let storedBackend = defaults.string(forKey: PreferenceKey.transcriptionBackend)
        backend = storedBackend.flatMap(TranscriptionBackend.init(rawValue:)) ?? .automatic
        let storedThreads = defaults.object(forKey: PreferenceKey.transcriptionThreads)
        threads = (storedThreads as? Int).flatMap(TranscriptionThreads.init(rawValue:)) ?? .four
        if (storedBackend.map { TranscriptionBackend(rawValue: $0) == nil } ?? false)
            || (storedThreads != nil && (storedThreads as? Int).flatMap(TranscriptionThreads.init(rawValue:)) == nil) {
            error = "The saved hardware or thread preference is unsupported. Review Automatic and four threads before starting another transcription."
        }
        let storedWorkers = defaults.object(forKey: PreferenceKey.transcriptionWorkers)
        let policy = (storedWorkers as? Int).flatMap(TranscriptionConcurrency.init(rawValue:))
        concurrency = policy ?? .one
        workerPool = TranscriptionWorkerPool(concurrency: policy ?? .one)
        if storedWorkers != nil, policy == nil {
            error = "The saved transcription worker count is unsupported. Using one worker; choose a limit from 1 to 4."
        }
        var prior: (weights: LocalWhisperWeights, url: URL)?
        if let data = defaults.data(forKey: Self.legacyBookmarkKey) {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data,
                    options: [.withSecurityScope, .withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
                if !stale, let weights = LocalWhisperWeights.allCases.first(where: { $0.filename == url.lastPathComponent }) {
                    prior = (weights, url)
                } else {
                    error = "The previous model location is stale or unsupported. Download a model here to replace that setup."
                }
            } catch {
                self.error = "The previous model location could not be restored. Download a model here. \(error.localizedDescription)"
            }
        }
        legacy = prior
        if let stored = defaults.string(forKey: PreferenceKey.whisperModel) {
            selection = LocalWhisperWeights(rawValue: stored) ?? .turbo
            if LocalWhisperWeights(rawValue: stored) == nil {
                error = "The saved model is unsupported. Choose one of the listed models."
            }
        } else {
            selection = prior?.weights ?? .turbo
        }
        refreshAvailability()
    }

    var selectedURL: URL? { available.contains(selection) ? modelURL(for: selection) : nil }

    func captureConfiguration() throws -> TranscriptionConfiguration {
        try TranscriptionConfiguration.resolve(backend: backend, threads: threads, metalAvailable: metalAvailable)
    }

    var backendStatus: String {
        switch backend {
        case .automatic:
            metalAvailable
                ? "Automatic chooses CPU + GPU / Metal on this Mac. Initialization failure stops the job; choose CPU and retry."
                : "Automatic chooses CPU because a supported Apple GPU is unavailable."
        case .cpu: "CPU / Accelerate only. No Metal inference or Core ML encoder."
        case .metal:
            metalAvailable
                ? "Encoder and decoder tensor inference use Metal; audio preparation and decoding control also use the CPU."
                : "Metal is unavailable on this Mac. Choose CPU or Automatic before transcribing."
        }
    }

    func configuredWorkerPool() async -> TranscriptionWorkerPool {
        await workerPool.configure(concurrency, revision: workerConfigurationRevision)
        return workerPool
    }

    private func modelURL(for weights: LocalWhisperWeights) -> URL {
        let managed = directory.appendingPathComponent(weights.filename)
        if FileManager.default.fileExists(atPath: managed.path) { return managed }
        if legacy?.weights == weights, let url = legacy?.url { return url }
        return managed
    }

    func refreshAvailability() {
        available = Set(LocalWhisperWeights.allCases.filter { weights in
            let url = modelURL(for: weights)
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true && values.fileSize == weights.byteCount
            } catch {
                if (error as NSError).code != NSFileReadNoSuchFileError {
                    self.error = "A local model could not be inspected: \(error.localizedDescription)"
                }
                return false
            }
        })
    }

    typealias Fetch = @Sendable (LocalWhisperWeights, URL, @escaping @Sendable (Int64) -> Void) async throws -> Void
    typealias Verify = @Sendable (URL, LocalWhisperWeights) async throws -> Void

    func download(
        fetch: @escaping Fetch = { try await TranscriptionSettings.fetch($0, to: $1, progress: $2) },
        verify: Verify? = nil
    ) {
        guard !isBusy else { return }
        let weights = selection
        let token = UUID()
        transferID = token
        downloading = weights
        receivedBytes = 0
        isVerifying = false
        isBusy = true
        error = nil
        status = "Downloading \(weights.title)…"
        let directory = directory
        let pool = workerPool
        let verify = verify ?? { url, weights in
            try await pool.withAdmission(resources: .init(memoryBytes: weights.byteCount * 2)) {
                _ = try await LocalWhisper.load(url: url, weights: weights)
            }
        }
        job = Task { [weak self] in
            guard let self else { return }
            defer {
                isBusy = false
                downloading = nil
                job = nil
                refreshAvailability()
            }
            do {
                try await Self.install(weights, in: directory, fetch: fetch, verify: verify,
                    progress: { [weak self] bytes in
                        Task { @MainActor in
                            guard let self, self.transferID == token, self.isBusy, !self.isVerifying else { return }
                            self.receivedBytes = max(self.receivedBytes, bytes)
                        }
                    }, verifying: { [weak self] in
                        guard let self, self.transferID == token else { return }
                        self.isVerifying = true
                        self.receivedBytes = Int64(weights.byteCount)
                        self.status = "Waiting for the shared resource budget, then checking model size and SHA-256 before installation…"
                    })
                status = "\(weights.title) is installed. It can be used offline in every episode."
                if legacy == nil || legacy?.weights == weights {
                    defaults.removeObject(forKey: Self.legacyBookmarkKey)
                    legacy = nil
                }
            } catch {
                if Task.isCancelled {
                    status = "Download cancelled. Incomplete weights were not installed."
                } else {
                    self.error = "Model download failed: \(EpisodeCleanupModel.describe(error))"
                    status = "No unverified model was installed. You can retry the download."
                }
            }
        }
    }

    func cancelDownload() {
        job?.cancel()
        status = "Cancelling model download…"
    }

    @concurrent
    static func install(
        _ weights: LocalWhisperWeights, in directory: URL,
        fetch: Fetch, verify: Verify,
        progress: @escaping @Sendable (Int64) -> Void,
        verifying: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        defer { removeTemporaryFile(staging) }
        try await fetch(weights, staging, progress)
        try Task.checkCancellation()
        await verifying()
        try await verify(staging, weights)
        try Task.checkCancellation()
        let target = directory.appendingPathComponent(weights.filename)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }

    @concurrent
    static func fetch(
        _ weights: LocalWhisperWeights, to destination: URL,
        progress: @escaping @Sendable (Int64) -> Void,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws {
        try await WhisperModelTransfer(weights: weights, destination: destination,
            configuration: configuration, report: progress).run()
    }

    nonisolated private static func removeTemporaryFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { try FileManager.default.removeItem(at: url) }
        catch {
            Logger(subsystem: "com.brandonmartinez.WaveWrangler", category: "WhisperModels")
                .error("Could not remove incomplete model: \(error.localizedDescription)")
        }
    }
}

private enum ModelDownloadError: LocalizedError {
    case response(Int?)
    case tooLarge
    case incomplete
    var errorDescription: String? {
        switch self {
        case .response(let status): "The model server returned \(status.map(String.init) ?? "an invalid response")."
        case .tooLarge: "The download exceeded the pinned model size."
        case .incomplete: "The model transfer ended without a completed file."
        }
    }
}

nonisolated private final class WhisperModelTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let weights: LocalWhisperWeights
    let destination: URL
    let configuration: URLSessionConfiguration
    let report: @Sendable (Int64) -> Void
    // Every mutable field is locked: Swift-task cancellation can race with delegate callbacks.
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?
    private var cancelled = false
    private var lastReport: ContinuousClock.Instant?

    init(weights: LocalWhisperWeights, destination: URL, configuration: URLSessionConfiguration,
         report: @escaping @Sendable (Int64) -> Void) {
        self.weights = weights
        self.destination = destination
        self.configuration = configuration
        self.report = report
    }

    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: weights.downloadURL)
                let cancel = lock.withLock {
                    self.session = session
                    self.task = task
                    self.continuation = continuation
                    return cancelled
                }
                if cancel { task.cancel() }
                task.resume()
            }
        } onCancel: {
            let task = self.lock.withLock {
                self.cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let outcome = Result<Void, any Error> {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
                throw ModelDownloadError.response((downloadTask.response as? HTTPURLResponse)?.statusCode)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        }
        lock.withLock {
            if result == nil { result = outcome }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= Int64(weights.byteCount) else {
            lock.withLock { result = .failure(ModelDownloadError.tooLarge) }
            downloadTask.cancel()
            return
        }
        let now = ContinuousClock.now
        let shouldReport = lock.withLock {
            if let lastReport, now - lastReport < .milliseconds(100),
               totalBytesWritten != Int64(weights.byteCount) { return false }
            lastReport = now
            return true
        }
        if shouldReport { report(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, outcome) = lock.withLock {
            let outcome: Result<Void, any Error>
            if let result, case .failure = result { outcome = result }
            else if let error { outcome = .failure(error) }
            else { outcome = result ?? .failure(ModelDownloadError.incomplete) }
            let continuation = self.continuation
            self.continuation = nil
            self.task = nil
            self.session = nil
            return (continuation, outcome)
        }
        continuation?.resume(with: outcome)
        session.finishTasksAndInvalidate()
    }
}
