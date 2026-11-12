import Foundation

public enum ExportDither: Sendable, Equatable { case none, tpdf }

public struct ExportDelivery: Sendable, Equatable {
    public let filename: String
    public let settings: ExportSettings
    public let metadata: ExportMetadata
    public let dither: ExportDither

    public init(filename: String, settings: ExportSettings, metadata: ExportMetadata = .init(),
                dither: ExportDither = .none) throws {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains(":"), !filename.contains("\0"),
              filename.utf8.count <= 240,
              (filename as NSString).pathExtension.lowercased() == settings.codec.fileExtension else {
            throw ExportFailure.destination("Choose a single filename with the requested format's extension")
        }
        if dither == .tpdf {
            guard case .wave(let pcm) = settings.codec, pcm != .float32 else {
                throw ExportFailure.invalidSettings("TPDF dither is only available for integer WAV")
            }
        }
        try metadata.validate(for: settings.codec)
        self.filename = filename
        self.settings = settings
        self.metadata = metadata
        self.dither = dither
    }
}

/// All destinations are new files in an explicitly user-selected folder. Existing entries are refused.
public struct ExportJobRequest: Sendable {
    public let directory: URL
    public let protectedLocations: [URL]
    public let productionFrames: Range<Int64>
    public let deliveries: [ExportDelivery]

    public init(userSelectedDirectory: URL, protectedLocations: [URL], productionFrames: Range<Int64>,
                deliveries: [ExportDelivery]) throws {
        guard userSelectedDirectory.isFileURL, !productionFrames.isEmpty,
              productionFrames.lowerBound >= -4_147_200_000, productionFrames.upperBound <= 4_147_200_000,
              !deliveries.isEmpty, deliveries.count <= 16,
              Set(deliveries.map { $0.filename.precomposedStringWithCanonicalMapping.lowercased() }).count
                == deliveries.count else {
            throw ExportFailure.invalidSettings("Expected a nonempty production range and 1...16 distinct delivery filenames")
        }
        directory = userSelectedDirectory
        self.protectedLocations = protectedLocations
        self.productionFrames = productionFrames
        self.deliveries = deliveries
    }
}

public struct PublishedExport: Sendable, Equatable {
    public let url: URL
    public let settings: ExportSettings
    public let inputFrames: Int64
    public let decodedFrames: Int64
    public let byteCount: Int64
}

public enum ExportJobPhase: Sendable, Equatable {
    case idle, preflight, rendering, converting(delivery: Int), verifying(delivery: Int), publishing, cleaning
    case completed, canceled, failed
}

public struct ExportJobProgress: Sendable, Equatable {
    public let phase: ExportJobPhase
    public let completedFrames: Int64
    public let totalFrames: Int64

    public init(phase: ExportJobPhase, completedFrames: Int64, totalFrames: Int64) {
        self.phase = phase
        self.completedFrames = completedFrames
        self.totalFrames = totalFrames
    }
}

public struct ExportJobProblem: Error, Sendable, Equatable {
    public enum Kind: Sendable { case canceled, stale, rendering, encoding, destination, cleanup }
    public let kind: Kind
    public let message: String
}

public struct ExportJobResult: Sendable {
    public let published: [PublishedExport]
    public let problem: ExportJobProblem?
    public let cleanupErrors: [String]
    public var succeeded: Bool { problem == nil && cleanupErrors.isEmpty }
}

/// One instance per document. Render output is provisional until the renderer's final currency check.
/// The callback must use the production renderer, independent effect instances and admitted sources.
public actor ExportJob {
    public typealias Sink = @Sendable (_ firstFrame: Int64, _ stereo: [[Float]]) async throws -> Void
    public typealias Renderer = @Sendable (_ sink: @escaping Sink) async throws -> Void
    public typealias Currency = @Sendable () async throws -> Bool
    public typealias Progress = @Sendable (ExportJobProgress) async -> Void

    public private(set) var progress = ExportJobProgress(phase: .idle, completedFrames: 0, totalFrames: 0)
    private var running = false
    private var canceled = false
    private var deliveryFrames: Int64 = 0

    public init() {}
    public func cancel() { if running { canceled = true } }

    public func run(_ request: ExportJobRequest, isCurrent: @escaping Currency,
                    render: @escaping Renderer, progress notify: @escaping Progress = { _ in }) async throws -> ExportJobResult {
        guard !running else { throw ExportFailure.invalidState }
        running = true
        canceled = false
        defer { running = false }
        let scope = request.directory.startAccessingSecurityScopedResource()
        defer { if scope { request.directory.stopAccessingSecurityScopedResource() } }
        var storage: ExportJobStorage?
        var intermediate: ExportIntermediate?
        var encoders: [ExportEncoder] = []
        var published: [PublishedExport] = []
        var problem: ExportJobProblem?
        var cleanupErrors: [String] = []
        do {
            await update(.preflight, total: request.productionFrames.count64, notify: notify)
            try await check(isCurrent)
            let owned = try ExportJobStorage(request: request)
            storage = owned
            let pcm = try ExportIntermediate(directory: owned.directory, frames: request.productionFrames)
            intermediate = pcm
            try owned.registerIntermediate()
            await update(.rendering, total: request.productionFrames.count64, notify: notify)
            try await render { [self] first, stereo in
                try await check(isCurrent)
                try await pcm.append(firstFrame: first, stereo: stereo)
                let count = await pcm.writtenFrames
                await renderingProgress(count, total: request.productionFrames.count64, notify: notify)
            }
            try await pcm.finish()
            try await check(isCurrent)
            var verified: [VerifiedExport] = []
            for (index, delivery) in request.deliveries.enumerated() {
                deliveryFrames = 0
                let expected = Int64((Double(request.productionFrames.count64)
                    * Double(delivery.settings.sampleRate) / 48_000).rounded())
                await update(.converting(delivery: index), total: expected, notify: notify)
                let encoder = try ExportEncoder(stagingDirectory: owned.directory,
                                                settings: delivery.settings, metadata: delivery.metadata)
                encoders.append(encoder)
                try await pcm.convert(delivery: delivery) { [self] samples in
                    try await check(isCurrent)
                    try await encoder.append(interleaved: samples)
                    await conversionProgress(Int64(samples.count / delivery.settings.channels),
                                             index: index, total: expected, notify: notify)
                }
                await update(.verifying(delivery: index), total: request.productionFrames.count64, notify: notify)
                verified.append(try await encoder.finish())
                try await check(isCurrent)
            }
            await update(.publishing, total: request.productionFrames.count64, notify: notify)
            try await check(isCurrent)
            for (index, file) in verified.enumerated() {
                try await check(isCurrent)
                let url = try owned.publish(file, filename: request.deliveries[index].filename)
                published.append(.init(url: url, settings: file.settings, inputFrames: file.inputFrames,
                                       decodedFrames: file.decodedFrames, byteCount: file.byteCount))
            }
        } catch {
            let kind: ExportJobProblem.Kind
            if error is CancellationError { kind = .canceled }
            else if let value = error as? ExportJobProblem { kind = value.kind }
            else {
                switch progress.phase {
                case .preflight, .publishing: kind = .destination
                case .rendering: kind = .rendering
                default: kind = .encoding
                }
            }
            problem = .init(kind: kind, message: String(describing: error))
        }
        await update(.cleaning, total: request.productionFrames.count64, notify: notify)
        do { try await intermediate?.close() }
        catch { cleanupErrors.append(String(describing: error)) }
        var mayClean = true
        do { try storage?.validateOwnership() }
        catch { mayClean = false; cleanupErrors.append(String(describing: error)) }
        for encoder in encoders where mayClean {
            do { try await encoder.cancel() }
            catch { cleanupErrors.append(String(describing: error)) }
        }
        do { if mayClean { try storage?.cleanup() } }
        catch { cleanupErrors.append(String(describing: error)) }
        if problem == nil, !cleanupErrors.isEmpty {
            problem = .init(kind: .cleanup, message: "Export files were published, but private staging cleanup failed")
        }
        await update(problem == nil ? .completed : problem?.kind == .canceled ? .canceled : .failed,
                     total: request.productionFrames.count64, notify: notify)
        return .init(published: published, problem: problem, cleanupErrors: cleanupErrors)
    }

    private func check(_ currency: Currency) async throws {
        try Task.checkCancellation()
        guard !canceled else { throw CancellationError() }
        let current = try await currency()
        try Task.checkCancellation()
        guard !canceled else { throw CancellationError() }
        guard current else {
            throw ExportJobProblem(kind: .stale, message: "The document or source admission changed. Restart export.")
        }
    }

    private func renderingProgress(_ frames: Int64, total: Int64, notify: Progress) async {
        progress = .init(phase: .rendering, completedFrames: frames, totalFrames: total)
        await notify(progress)
    }

    private func conversionProgress(_ frames: Int64, index: Int, total: Int64, notify: Progress) async {
        deliveryFrames += frames
        progress = .init(phase: .converting(delivery: index), completedFrames: deliveryFrames, totalFrames: total)
        await notify(progress)
    }

    private func update(_ phase: ExportJobPhase, total: Int64, notify: Progress) async {
        progress = .init(phase: phase, completedFrames: phase == .completed ? total : 0, totalFrames: total)
        await notify(progress)
    }
}

extension Range<Int64> {
    var count64: Int64 { upperBound - lowerBound }
}
