import Foundation

public enum ExportDither: Sendable, Equatable { case none, tpdf }

public struct ExportDelivery: Sendable, Equatable {
    public let filename: String
    public let settings: ExportSettings
    public let metadata: ExportMetadata
    public let dither: ExportDither
    public let normalization: ExportNormalization

    public init(filename: String, settings: ExportSettings, metadata: ExportMetadata = .init(),
                dither: ExportDither = .none, normalization: ExportNormalization = .off) throws {
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
        _ = try normalization.targets(channels: settings.channels)
        self.filename = filename
        self.settings = settings
        self.metadata = metadata
        self.dither = dither
        self.normalization = normalization
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
    public let loudness: ExportLoudnessReport
}

public enum ExportJobPhase: Sendable, Equatable {
    case idle, preflight, rendering, converting(delivery: Int), verifying(delivery: Int), publishing, cleaning
    case measuring(delivery: Int), correcting(delivery: Int, attempt: Int)
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

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct ExportJobResult: Sendable {
    public let published: [PublishedExport]
    public let problem: ExportJobProblem?
    public let cleanupErrors: [String]
    /// Local encoded outputs retained after a destination failure, not published delivery receipts.
    public let retainedDirectory: URL?
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
    private var activeEncoder: ExportEncoder?
    private let remuxFactory: ExportRemuxOperation.Factory
    private let temporaryDirectory: URL

    public init() {
        remuxFactory = ExportRemuxOperation.system
        temporaryDirectory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    }
    init(temporaryDirectory: URL, remuxFactory: @escaping ExportRemuxOperation.Factory = ExportRemuxOperation.system) {
        self.remuxFactory = remuxFactory
        self.temporaryDirectory = temporaryDirectory
    }
    public func cancel() async {
        if running {
            canceled = true
            await activeEncoder?.requestCancellation()
        }
    }

    public func run(_ request: ExportJobRequest, isCurrent: @escaping Currency,
                    validateSources: Currency? = nil,
                    render: @escaping Renderer, progress notify: @escaping Progress = { _ in }) async throws -> ExportJobResult {
        guard !running else { throw ExportFailure.invalidState }
        running = true
        canceled = false
        defer { running = false; activeEncoder = nil }
        let scope = request.directory.startAccessingSecurityScopedResource()
        defer { if scope { request.directory.stopAccessingSecurityScopedResource() } }
        var storage: ExportJobStorage?
        var intermediate: ExportIntermediate?
        var encoders: [ExportEncoder] = []
        var finishedEncoders: [ExportEncoder] = []
        var published: [PublishedExport] = []
        var problem: ExportJobProblem?
        var cleanupErrors: [String] = []
        var retainedDirectory: URL?
        var verified: [VerifiedExport] = []
        do {
            await update(.preflight, total: request.productionFrames.count64, notify: notify)
            try await check(isCurrent, sources: validateSources)
            let owned = try ExportJobStorage(request: request, temporaryDirectory: temporaryDirectory)
            storage = owned
            let pcm = try ExportIntermediate(directory: owned.directory, frames: request.productionFrames)
            intermediate = pcm
            await update(.rendering, total: request.productionFrames.count64, notify: notify)
            try await render { [self] first, stereo in
                try await check(isCurrent)
                try await pcm.append(firstFrame: first, stereo: stereo)
                let count = await pcm.writtenFrames
                await renderingProgress(count, total: request.productionFrames.count64, notify: notify)
            }
            try await pcm.finish()
            try await check(isCurrent, sources: validateSources)
            var reports: [ExportLoudnessReport] = []
            for (index, delivery) in request.deliveries.enumerated() {
                let expected = Int64((Double(request.productionFrames.count64)
                    * Double(delivery.settings.sampleRate) / 48_000).rounded())
                let targets = try delivery.normalization.targets(channels: delivery.settings.channels)
                var gainDB = 0.0
                var initialStatus = ExportLoudnessReport.TargetStatus.off
                if let targets {
                    await update(.measuring(delivery: index), total: expected, notify: notify)
                    try await check(isCurrent, sources: validateSources)
                    let meter = ExportLoudnessAccumulator(settings: delivery.settings)
                    deliveryFrames = 0
                    try await pcm.convert(delivery: delivery, measuring: true) { [self] samples in
                        try await check(isCurrent)
                        try await meter.append(samples)
                        await measurementProgress(Int64(samples.count / delivery.settings.channels),
                                                  index: index, total: expected, notify: notify)
                    }
                    guard deliveryFrames == expected else { throw ExportFailure.verification("Incomplete loudness pass") }
                    let measured = await meter.finish()
                    let desired = measured.integratedLUFS.map { targets.loudness - $0 } ?? 0
                    let peakGain = measured.truePeakDBTP.map {
                        targets.ceiling - ExportLoudnessMeter.ceilingReserveDB - $0 - 0.05
                    } ?? 0
                    gainDB = min(desired, ExportNormalization.maximumBoostDB, peakGain)
                    if measured.integratedLUFS == nil { initialStatus = .unmeasurable }
                    else if gainDB < desired - 0.1 {
                        initialStatus = peakGain < min(desired, ExportNormalization.maximumBoostDB)
                            ? .peakLimited : .boostLimited
                    } else { initialStatus = .achieved }
                }
                let originalGainDB = gainDB
                var correctionPasses = 0
                while true {
                    deliveryFrames = 0
                    if correctionPasses == 0 {
                        await update(.converting(delivery: index), total: expected, notify: notify)
                    } else {
                        await update(.correcting(delivery: index, attempt: correctionPasses), total: expected, notify: notify)
                    }
                    try await check(isCurrent, sources: validateSources)
                    try owned.validateOwnership()
                    let encoder = try ExportEncoder(stagingDirectory: owned.directory,
                        settings: delivery.settings, metadata: delivery.metadata, remuxFactory: remuxFactory)
                    encoders.append(encoder)
                    activeEncoder = encoder
                    try await pcm.convert(delivery: delivery, gainDB: gainDB) { [self] samples in
                        try await check(isCurrent)
                        try await encoder.append(interleaved: samples)
                        await conversionProgress(Int64(samples.count / delivery.settings.channels),
                                                 index: index, total: expected, notify: notify)
                    }
                    await update(.verifying(delivery: index), total: expected, notify: notify)
                    try await check(isCurrent, sources: validateSources)
                    let file = try await encoder.finish { [self] in try await check(isCurrent) }
                    activeEncoder = nil
                    try await check(isCurrent, sources: validateSources)
                    if let targets, let peak = file.loudness.truePeakDBTP,
                       peak > targets.ceiling - ExportLoudnessMeter.ceilingReserveDB {
                        guard correctionPasses < 3 else {
                            throw ExportFailure.verification("Decoded true peak cannot satisfy the ceiling and reconstruction safety reserve after three corrective re-encodes")
                        }
                        gainDB -= peak - (targets.ceiling - ExportLoudnessMeter.ceilingReserveDB) + 0.1
                        correctionPasses += 1
                        try owned.validateOwnership()
                        try await encoder.cancel()
                        continue
                    }
                    var status = initialStatus
                    if targets != nil, file.loudness.integratedLUFS == nil { status = .unmeasurable }
                    else if let targets, initialStatus == .achieved,
                            let actual = file.loudness.integratedLUFS, abs(actual - targets.loudness) > 0.2 {
                        status = correctionPasses > 0 ? .peakLimited : .targetMissed
                    }
                    reports.append(.init(measurement: file.loudness,
                        requestedTargetLUFS: targets?.loudness, ceilingDBTP: targets?.ceiling,
                        appliedGainDB: gainDB, correctiveAttenuationDB: originalGainDB - gainDB,
                        correctionPasses: correctionPasses, targetStatus: status))
                    verified.append(file)
                    finishedEncoders.append(encoder)
                    break
                }
                try await check(isCurrent, sources: validateSources)
            }
            await update(.publishing, total: request.productionFrames.count64, notify: notify)
            try await check(isCurrent, sources: validateSources)
            try await pcm.validate()
            for (index, file) in verified.enumerated() {
                try await check(isCurrent, sources: validateSources)
                let url = try await owned.publish(file, filename: request.deliveries[index].filename,
                    check: { [self] in try await check(isCurrent) },
                    beforeCommit: { [self] in try await check(isCurrent, sources: validateSources) })
                published.append(.init(url: url, settings: file.settings, inputFrames: file.inputFrames,
                                       decodedFrames: file.decodedFrames, byteCount: file.byteCount,
                                       loudness: reports[index]))
            }
        } catch {
            let kind: ExportJobProblem.Kind
            if canceled || Task.isCancelled || error is CancellationError { kind = .canceled }
            else if let value = error as? ExportJobProblem { kind = value.kind }
            else {
                switch progress.phase {
                case .preflight, .publishing: kind = .destination
                case .rendering: kind = .rendering
                default: kind = .encoding
                }
            }
            problem = .init(kind: kind, message: String(describing: error))
            if kind == .destination, progress.phase == .publishing, verified.count == request.deliveries.count {
                do {
                    try storage?.validateOwnership()
                    for encoder in finishedEncoders { try await encoder.validateFinishedOutput() }
                    try storage?.validateOwnership()
                    retainedDirectory = storage?.directory
                    if let retainedDirectory {
                        problem = .init(kind: kind, message: "\(String(describing: error))\nLocal export files were retained at \(retainedDirectory.path). They are not published deliveries; reverify them before use.")
                    }
                } catch { cleanupErrors.append(String(describing: error)) }
            }
        }
        await update(.cleaning, total: request.productionFrames.count64, notify: notify)
        var mayClean = true
        do { try storage?.validateOwnership() }
        catch { mayClean = false; cleanupErrors.append(String(describing: error)) }
        do { if mayClean { try await intermediate?.cleanup() } }
        catch { cleanupErrors.append(String(describing: error)) }
        do { try await intermediate?.close() }
        catch { cleanupErrors.append(String(describing: error)) }
        do { try storage?.cleanupPublication() }
        catch { cleanupErrors.append(String(describing: error)) }
        for encoder in encoders where mayClean && retainedDirectory == nil {
            do { try await encoder.cancel() }
            catch { cleanupErrors.append(String(describing: error)) }
        }
        do { if mayClean && retainedDirectory == nil { try storage?.cleanup() } }
        catch { cleanupErrors.append(String(describing: error)) }
        if problem == nil, !cleanupErrors.isEmpty {
            problem = .init(kind: .cleanup, message: "Export files were published, but private staging cleanup failed")
        }
        await update(problem == nil ? .completed : problem?.kind == .canceled ? .canceled : .failed,
                     total: request.productionFrames.count64, notify: notify)
        return .init(published: published, problem: problem, cleanupErrors: cleanupErrors, retainedDirectory: retainedDirectory)
    }

    private func check(_ currency: Currency, sources: Currency? = nil) async throws {
        try Task.checkCancellation()
        guard !canceled else { throw CancellationError() }
        let current = try await currency()
        try Task.checkCancellation()
        guard !canceled else { throw CancellationError() }
        guard current else {
            throw ExportJobProblem(kind: .stale, message: "The document or source admission changed. Restart export.")
        }
        if let sources {
            guard try await sources() else {
                throw ExportJobProblem(kind: .stale, message: "The document or source admission changed. Restart export.")
            }
            try await check(currency)
        }
    }

    private func renderingProgress(_ frames: Int64, total: Int64, notify: Progress) async {
        progress = .init(phase: .rendering, completedFrames: frames, totalFrames: total)
        await notify(progress)
    }

    private func conversionProgress(_ frames: Int64, index: Int, total: Int64, notify: Progress) async {
        deliveryFrames += frames
        let phase: ExportJobPhase
        if case .correcting = progress.phase { phase = progress.phase }
        else { phase = .converting(delivery: index) }
        progress = .init(phase: phase, completedFrames: deliveryFrames, totalFrames: total)
        await notify(progress)
    }

    private func measurementProgress(_ frames: Int64, index: Int, total: Int64, notify: Progress) async {
        deliveryFrames += frames
        progress = .init(phase: .measuring(delivery: index), completedFrames: deliveryFrames, totalFrames: total)
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
