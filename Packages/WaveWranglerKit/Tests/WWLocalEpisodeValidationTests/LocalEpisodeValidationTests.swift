import Accelerate
import CryptoKit
import Darwin
import Foundation
import Testing
import UniformTypeIdentifiers
import WWAlignEstimate
import WWAlignPipeline
import WWCore
import WWDecode
import WWDerived
import WWPersistence
import WWRender
import WWSources
import WWTimeMap

// Headless local validation of the M2 pipeline on a user-approved, disposable local episode copy.
//
// Consent rules (docs/planning/kickoffs/m2.md, "Content consent"):
// * Runs ONLY when WW_LOCAL_EPISODE_DIR names an approved folder; it is skipped otherwise, so CI never
//   runs it. The path is supplied at run time and never written anywhere by this harness.
// * The folder is read-only. Audio content is opened only through the WWDecode gateway (SourceDecoder);
//   the only other content read is plain read-only SHA-256 hashing of the folder's audio items to prove
//   they are byte-unchanged. Non-audio items are never opened (metadata only).
// * Derived data (the rendered test segment) goes only to WW_LOCAL_SCRATCH_DIR, a fresh `mktemp -d`
//   directory that ConsentGuards.checkScratch requires to be empty, local, non-ubiquitous and outside the
//   approved folder, the repository and cloud-synced folders. The render asset is removed when render()
//   exits, and the operator deletes the directory after the run. Analysis buffers stay in memory and are
//   never written.
// * The immutability snapshot is re-taken and compared even when an earlier step throws.
// * Output names sources S01..Snn only (audio by size descending then SHA-256; then non-audio by size). It
//   never prints a path, a file name, or any audio content.
// * No transcription, speech analysis, network or GUI.
// Estimator results on real material are observations: there is no clock truth, a proposal stays a
// proposal and scores are not probabilities.

private enum Env {
    static let episode = ProcessInfo.processInfo.environment["WW_LOCAL_EPISODE_DIR"]
    static let scratch = ProcessInfo.processInfo.environment["WW_LOCAL_SCRATCH_DIR"]
    static let manual = ProcessInfo.processInfo.environment["WW_LOCAL_EPISODE_MANUAL"] == "1"
    static let phase = ProcessInfo.processInfo.environment["WW_LOCAL_EPISODE_MEMORY_PHASE"]
    static let labelMap = ProcessInfo.processInfo.environment["WW_LOCAL_EPISODE_LABEL_MAP"]
}

private func log(_ line: String) {
    print("WWLEV | \(line)")
}

private func f(_ value: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", value) }

private func sLabel(_ number: Int) -> String { String(format: "S%02d", number) }

@Suite("Local episode validation (WW_LOCAL_EPISODE_DIR)", .serialized, .enabled(if: Env.episode != nil))
struct LocalEpisodeValidationTests {
    @Test(.timeLimit(.minutes(60)))
    func validateApprovedEpisodeCopy() async throws {
        let episode = URL(fileURLWithPath: try #require(Env.episode), isDirectory: true).standardizedFileURL
        let scratchPath = try #require(Env.scratch, "set WW_LOCAL_SCRATCH_DIR to a fresh mktemp -d directory")
        let scratch = try ConsentGuards.checkScratch(URL(fileURLWithPath: scratchPath, isDirectory: true), episode: episode)
        log("scratch guard: empty directory on a local, non-ubiquitous volume; outside the approved folder, the repository and cloud-synced folders")

        var harness = Harness(episode: episode, scratch: scratch)
        try await harness.run()
        #expect(harness.findings.isEmpty, "findings: \(harness.findings)")
    }
}

@Suite("Local episode manual pipeline (opt-in)", .serialized, .enabled(if: Env.manual && Env.episode != nil))
struct LocalEpisodeManualTests {
    @Test(.timeLimit(.minutes(60)))
    func validateManualPipeline() async throws {
        let episode = URL(fileURLWithPath: try #require(Env.episode), isDirectory: true).standardizedFileURL
        let scratchPath = try #require(Env.scratch, "set WW_LOCAL_SCRATCH_DIR to a fresh mktemp -d directory")
        let scratch = try ConsentGuards.checkScratch(URL(fileURLWithPath: scratchPath, isDirectory: true), episode: episode)
        var harness = Harness(episode: episode, scratch: scratch)
        try await harness.runManual()
        #expect(harness.findings.isEmpty, "findings: \(harness.findings)")
    }
}

@Suite("Local episode isolated memory (opt-in)", .serialized,
    .enabled(if: Env.episode != nil && Env.phase.map { ["snapshot", "original", "render"].contains($0) } == true))
struct LocalEpisodeMemoryTests {
    @Test(.timeLimit(.minutes(30)))
    func measureIsolatedPhase() async throws {
        let episode = URL(fileURLWithPath: try #require(Env.episode), isDirectory: true).standardizedFileURL
        let phase = try #require(Env.phase)
        if phase == "snapshot" {
            let harness = Harness(episode: episode, scratch: episode)
            let items = try harness.enumerate()
            let snapshot = try harness.snapshot(items)
            let numbered = harness.number(items, snapshots: snapshot)
            let labels = numbered.filter(\.isAudio).map {
                "\($0.number):\(snapshot[$0.url]!.inode)"
            }.joined(separator: "\n") + "\n"
            let mapPath = try #require(Env.labelMap, "set a temporary label-map path outside the repository")
            let mapURL = URL(fileURLWithPath: mapPath)
            if FileManager.default.fileExists(atPath: mapURL.path) {
                let previous: String
                do {
                    previous = try String(contentsOf: mapURL, encoding: .utf8)
                } catch {
                    throw HarnessError("temporary label map unreadable")
                }
                guard previous == labels else { throw HarnessError("original source label order changed") }
            } else {
                let directory = try ConsentGuards.checkScratch(mapURL.deletingLastPathComponent(), episode: episode)
                guard ConsentGuards.realPath(mapURL.deletingLastPathComponent()) == directory else {
                    throw HarnessError("temporary label map is not in guarded scratch")
                }
                do {
                    try labels.write(to: mapURL, atomically: true, encoding: .utf8)
                } catch {
                    throw HarnessError("temporary label map write failed")
                }
            }
            var hasher = SHA256()
            for entry in snapshot.values.map({
                "\($0.size):\($0.mtime):\($0.ctime):\($0.inode):\($0.sha256 ?? "-")"
            }).sorted() {
                hasher.update(data: Data(entry.utf8))
                hasher.update(data: Data([10]))
            }
            log("memory snapshot: \(items.count) items, \(items.filter(\.isAudio).count) audio; aggregate SHA-256 \(hasher.finalize().map { String(format: "%02x", $0) }.joined())")
            return
        }
        let scratchPath = try #require(Env.scratch, "set WW_LOCAL_SCRATCH_DIR to a fresh mktemp -d directory")
        let scratch = try ConsentGuards.checkScratch(URL(fileURLWithPath: scratchPath, isDirectory: true), episode: episode)
        var harness = Harness(episode: episode, scratch: scratch)
        try await harness.runIsolatedMemoryPhase(phase)
    }
}

// MARK: - Harness

private struct Harness {
    let episode: URL
    let scratch: URL
    let io = SystemSourceIO()
    var findings: [String] = []

    init(episode: URL, scratch: URL) {
        self.episode = episode
        self.scratch = scratch
    }

    mutating func run() async throws {
        let started = Date()
        log("host: \(Host.summary)")
        log("pipeline: decode envelope v\(DecodeEnvelope.version), estimator \(AcousticEstimator.identifier), renderer v\(RenderVersions.renderer), recipe v\(RenderRecipe.currentVersion)")

        // 1. Enumerate (metadata only), snapshot, number.
        var items = try enumerate()
        let before = try snapshot(items)
        items = number(items, snapshots: before)
        log("items: \(items.count) numbered (\(items.filter(\.isAudio).count) audio, \(items.filter { !$0.isAudio }.count) non-audio)")

        // Steps 2-5 run inside a do/catch so the immutability check (step 6) always runs, like a finally.
        var stepError: (any Error)?
        do {
            try await steps(items)
        } catch {
            // Only HarnessError text is known path-free; anything else is reported by type alone.
            let sanitized = error as? HarnessError ?? HarnessError("a validation step threw \(type(of: error))")
            stepError = sanitized
            log("step failed: \(sanitized)")
            findings.append("a validation step threw")
        }

        // 6. Immutability, even when an earlier step threw.
        do {
            let after = try snapshot(items)
            verifyUnchanged(items, before: before, after: after)
        } catch {
            log("immutability: NOT VERIFIED (\(error))")
            findings.append("P0 immutability not verified: \(error)")
        }

        log("wall time: \(f(Date().timeIntervalSince(started), 1)) s; process peak RSS \(Host.peakRSSMegabytes) MB")
        log("findings: \(findings.isEmpty ? "none" : findings.joined(separator: "; "))")
        if let stepError { throw stepError }
    }

    mutating func steps(_ items: [Item]) async throws {
        // 2. Decode every audio item through the gateway, one at a time.
        var decoded: [Int: Decoded] = [:]
        for item in items {
            guard item.isAudio else {
                log("\(item.label): non-audio item, metadata only, not opened")
                continue
            }
            if let result = await decode(item) { decoded[item.number] = result }
        }

        // 3. Metadata-only recorder groups.
        let groups = proposeGroups(decoded)

        // 4. Estimator observations.
        await estimate(groups, decoded)

        // 5. Channel-consistent render.
        try await render(groups, decoded)
    }

    // MARK: Enumeration and numbering

    struct Item {
        let url: URL
        let isAudio: Bool
        let size: Int64
        var number = 0
        var label: String { sLabel(number) }
    }

    func enumerate() throws -> [Item] {
        let listing = io.listItems(under: episode)
        var items: [Item] = []
        var directories = 0
        var hidden = 0
        var links = 0
        for listed in listing.items {
            if listed.isHidden.value == true { hidden += 1; continue }
            guard case .success(let metadata) = io.metadata(at: listed.url) else { throw HarnessError("metadata unavailable for an item") }
            if metadata.isDirectory.value == true, metadata.isPackage.value != true { directories += 1; continue }
            if metadata.isSymbolicLink.value == true { links += 1; continue }
            guard metadata.isDataless.value == false, metadata.volumeIsLocal.value == true else {
                throw HarnessError("an item is not local; the harness never triggers a download")
            }
            let type = metadata.fingerprint.contentType.value.flatMap { UTType($0) }
            let isAudio = metadata.isRegularFile.value == true && (type?.conforms(to: .audio) ?? false)
            items.append(Item(url: listed.url, isAudio: isAudio, size: metadata.fingerprint.fileSize.value ?? -1))
        }
        log("listing (metadata only): \(items.count) items, \(directories) subdirectories, \(hidden) hidden entries skipped, \(links) links skipped, \(listing.unreadableEntryCount) unreadable entries")
        return items
    }

    func number(_ items: [Item], snapshots: [URL: Snapshot]) -> [Item] {
        let audio = items.filter(\.isAudio).sorted {
            $0.size != $1.size ? $0.size > $1.size : (snapshots[$0.url]?.sha256 ?? "") < (snapshots[$1.url]?.sha256 ?? "")
        }
        let others = items.filter { !$0.isAudio }.sorted {
            $0.size != $1.size ? $0.size > $1.size : (snapshots[$0.url]?.inode ?? 0) < (snapshots[$1.url]?.inode ?? 0)
        }
        return (audio + others).enumerated().map { index, item in
            var numbered = item
            numbered.number = index + 1
            return numbered
        }
    }

    // MARK: Immutability

    struct Snapshot: Equatable {
        var size: Int64
        var mtime: Int64
        var ctime: Int64
        var inode: UInt64
        var sha256: String?
    }

    func snapshot(_ items: [Item]) throws -> [URL: Snapshot] {
        var result: [URL: Snapshot] = [:]
        var hashedBytes: Int64 = 0
        let started = Date()
        for (index, item) in items.enumerated() {
            // Before numbering (numbering needs the hashes) an item is identified only by its listing index.
            let label = item.number > 0 ? item.label : "unnumbered item \(index + 1)"
            var status = stat()
            guard lstat(item.url.path, &status) == 0 else { throw HarnessError("lstat of \(label) failed: errno \(errno)") }
            var snap = Snapshot(
                size: Int64(status.st_size),
                mtime: Int64(status.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(status.st_mtimespec.tv_nsec),
                ctime: Int64(status.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(status.st_ctimespec.tv_nsec),
                inode: UInt64(status.st_ino)
            )
            if item.isAudio {
                snap.sha256 = try ConsentGuards.sha256(item.url, label: label)
                hashedBytes += snap.size
            }
            result[item.url] = snap
        }
        let seconds = Date().timeIntervalSince(started)
        log("snapshot: \(items.count) items (lstat size/mtime/ctime/inode), \(items.filter(\.isAudio).count) audio items SHA-256, \(f(Double(hashedBytes) / 1e9, 2)) GB hashed in \(f(seconds, 1)) s")
        return result
    }

    mutating func verifyUnchanged(_ items: [Item], before: [URL: Snapshot], after: [URL: Snapshot]) {
        let changed = items.filter { before[$0.url] != after[$0.url] }.map(\.label)
        let audio = items.filter(\.isAudio).count
        if changed.isEmpty {
            log("immutability: \(items.count)/\(items.count) items unchanged before vs after (size, mtime, ctime, inode; SHA-256 for the \(audio) audio items)")
        } else {
            log("immutability: CHANGED \(changed.joined(separator: ","))")
            findings.append("P0 source changed: \(changed.joined(separator: ","))")
        }
    }

    // MARK: Decode

    struct Decoded: Sendable {
        let label: String
        let interpretation: FormatInterpretation
        let report: DecodeReport
        let product: AnalysisProduct
        let seconds: Double
    }

    mutating func decode(_ item: Item, sliceStartSeconds: Int? = nil) async -> Decoded? {
        let decoder = SourceDecoder(access: SourceAccessContext(io: io))
        let started = Date()
        do throws(DecodeFailure) {
            let result = try await decoder.decode(item.url, source: SourceID()) { interpretation in
                AnalysisSink(interpretation, sliceStartSeconds: sliceStartSeconds)
            }
            let seconds = Date().timeIntervalSince(started)
            let i = result.interpretation
            let duration = Double(i.frames.validFrames) / Double(i.sourceSampleRate)
            log("\(item.label): SUPPORTED | container \(i.container.kind.rawValue) (\(i.container.typeCode), extension matches \(i.container.extensionMatchesContainer)) | codec \(i.codec.kind.rawValue) (\(i.codec.formatID)) | \(i.sourceSampleRate) Hz | \(i.sampleFormat) | \(i.channelCount) ch | valid \(i.frames.validFrames) frames (\(f(duration, 1)) s) | priming \(i.frames.primingFrames), remainder \(i.frames.remainderFrames), packet table \(i.frames.hasPacketTable) | envelope v\(i.envelopeVersion) | exact in float32 \(i.output.representsSourceSamplesExactly)")
            let mb = Double(item.size) / 1e6
            log("\(item.label): decode \(f(seconds, 2)) s (\(f(mb / seconds, 0)) MB/s, \(f(duration / seconds, 0))x real time), \(result.report.readCalls) reads, stream frames \(result.report.codecStreamFramesRead), discarded \(result.report.leadingStreamFramesDiscarded)+\(result.report.trailingStreamFramesDiscarded) | analysis \(result.product.analysis.count) samples at \(result.product.analysisRate) Hz (memory only) | peak |x| \(f(Double(result.product.peak), 4)) | sink on main thread: \(result.product.sawMainThread)")
            if result.product.sawMainThread { findings.append("main-thread decode work: \(item.label)") }
            return Decoded(label: item.label, interpretation: i, report: result.report, product: result.product, seconds: seconds)
        } catch {
            log("\(item.label): REFUSED | \(Self.describe(error))")
            if Self.isUnexpectedRefusal(error) { findings.append("unexpected decode refusal \(item.label): \(Self.describe(error))") }
            return nil
        }
    }

    /// Typed, path-free description (never interpolates sink or URL text).
    static func describe(_ failure: DecodeFailure) -> String {
        switch failure {
        case .unsupported(let reason): "unsupported(\(reason))"
        case .metadataUnavailable: "metadataUnavailable"
        case .sinkFailed: "sinkFailed"
        default: "\(failure)"
        }
    }

    /// Containers outside DecodeEnvelope v1 (e.g. MP3, docs/m2/evidence/ww-050-decode-envelope.md) are an
    /// expected, typed refusal; any other refusal of a real audio file is a finding.
    static func isUnexpectedRefusal(_ failure: DecodeFailure) -> Bool {
        if case .unsupported(.container) = failure { return false }
        return true
    }

    // MARK: Groups

    struct Group {
        let label: String
        let members: [Int]
        let rate: Int
        let frames: Int64
        var seconds: Double { Double(frames) / Double(rate) }
    }

    func proposeGroups(_ decoded: [Int: Decoded]) -> [Group] {
        var buckets: [String: [Int]] = [:]
        var order: [String] = []
        for key in decoded.keys.sorted() {
            let i = decoded[key]!.interpretation
            let bucket = "\(i.sourceSampleRate)/\(i.frames.validFrames)"
            if buckets[bucket] == nil { order.append(bucket) }
            buckets[bucket, default: []].append(key)
        }
        var groups: [Group] = []
        for (index, bucket) in order.enumerated() {
            let members = buckets[bucket]!
            let first = decoded[members[0]]!.interpretation
            let group = Group(label: "G\(index + 1)", members: members, rate: first.sourceSampleRate, frames: first.frames.validFrames)
            let channels = members.map { "\(decoded[$0]!.interpretation.channelCount)" }.joined(separator: "+")
            log("\(group.label) (proposed from metadata: same rate and same valid frame count): \(members.map(sLabel).joined(separator: ",")) | \(group.rate) Hz | \(group.frames) frames (\(f(group.seconds, 1)) s) | channels \(channels)")
            groups.append(group)
        }
        for a in 0 ..< groups.count {
            for b in a + 1 ..< groups.count where abs(groups[a].seconds - groups[b].seconds) < 1 {
                log("note: \(groups[a].label) and \(groups[b].label) durations differ by \(f(abs(groups[a].seconds - groups[b].seconds), 4)) s (< 1 s) but are not grouped (rate or frame count differs)")
            }
        }
        return groups
    }

    // MARK: Estimator

    struct Analysis: Sendable {
        let samples: [Float]
        let rate: Int
        var seconds: Double { Double(samples.count) / Double(rate) }
    }

    func representative(_ members: [Int], _ decoded: [Int: Decoded]) -> Analysis {
        let first = decoded[members[0]]!.product
        var sum = [Float](repeating: 0, count: first.analysis.count)
        for member in members { vDSP_vadd(sum, 1, decoded[member]!.product.analysis, 1, &sum, 1, vDSP_Length(sum.count)) }
        var scale = 1 / Float(members.count)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(sum.count))
        return Analysis(samples: sum, rate: first.analysisRate)
    }

    struct PairJob: Sendable {
        let name: String
        let reference: Analysis
        let target: Analysis
        let deviation: Double
        let center: Double
        let overlap: Range<Int>?
        let sameClock: Bool
    }

    struct PairOutcome: Sendable {
        let job: PairJob
        let result: Result<EstimationReport, AlignEstimateError>
        let seconds: Double
        let timeMap: String
    }

    mutating func estimate(_ groups: [Group], _ decoded: [Int: Decoded]) async {
        var jobs: [PairJob] = []
        let reps = groups.map { representative($0.members, decoded) }
        for a in 0 ..< groups.count {
            for b in a + 1 ..< groups.count {
                // Reference = the longer group; the shorter one is estimated against it.
                let (r, t) = groups[a].seconds >= groups[b].seconds ? (a, b) : (b, a)
                let name = "pair \(groups[r].label)<-\(groups[t].label)"
                guard reps[t].seconds >= 60 else {
                    log("\(name): not estimated (target shorter than 60 s)")
                    continue
                }
                jobs.append(PairJob(name: name + " stage 1", reference: reps[r], target: reps[t], deviation: 600, center: 0, overlap: nil, sameClock: false))
            }
        }
        for group in groups where group.members.count > 1 {
            for member in group.members {
                let others = group.members.filter { $0 != member }
                let target = Analysis(samples: decoded[member]!.product.analysis, rate: decoded[member]!.product.analysisRate)
                jobs.append(PairJob(name: "within \(group.label): \(sLabel(member)) vs mix of the other members", reference: representative(others, decoded), target: target, deviation: 5, center: 0, overlap: nil, sameClock: true))
            }
        }
        let started = Date()
        var outcomes = await Self.runJobs(jobs)
        // Stage 2: a cross-group pair that abstained with >= 3 eligible windows is re-run once with the
        // overlap implied by their median offset declared and a narrow search around it (an observation).
        var stage2: [PairJob] = []
        for outcome in outcomes where !outcome.job.sameClock {
            guard case .success(let report) = outcome.result, let epoch = report.epochs.first, case .abstained = epoch.outcome else { continue }
            let offsets = epoch.windows.filter { $0.status == .eligible }.compactMap(\.offsetSeconds).sorted()
            guard offsets.count >= 3 else { continue }
            let median = offsets[offsets.count / 2]
            let rate = Double(outcome.job.target.rate)
            let lo = max(0, Int((-median * rate).rounded(.up))) + Int(rate)
            let hi = min(outcome.job.target.samples.count, Int(((outcome.job.reference.seconds - median) * rate).rounded(.down))) - Int(rate)
            guard hi - lo > Int(60 * rate) else { continue }
            stage2.append(PairJob(name: outcome.job.name.replacingOccurrences(of: "stage 1", with: "stage 2"), reference: outcome.job.reference, target: outcome.job.target, deviation: 5, center: median, overlap: lo ..< hi, sameClock: false))
        }
        outcomes += await Self.runJobs(stage2)
        for outcome in outcomes { report(outcome) }
        log("estimator: \(outcomes.count) requests in \(f(Date().timeIntervalSince(started), 1)) s wall (concurrent, off the main thread)")
    }

    static func runJobs(_ jobs: [PairJob]) async -> [PairOutcome] {
        await withTaskGroup(of: (Int, PairOutcome).self) { group in
            for (index, job) in jobs.enumerated() {
                group.addTask { (index, Self.runJob(job)) }
            }
            var results: [(Int, PairOutcome)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func runJob(_ job: PairJob) -> PairOutcome {
        let started = Date()
        let onMain = pthread_main_np() != 0
        let referenceGroup = RecorderGroupID()
        let referenceEpoch = RecordingEpochID()
        let referenceOccurrence = SourceOccurrenceID()
        let targetGroup = RecorderGroupID()
        let targetEpoch = RecordingEpochID()
        let targetOccurrence = SourceOccurrenceID()
        let result = Result { () throws(AlignEstimateError) -> EstimationReport in
            let request = EstimationRequest(
                reference: EstimatorTrack(group: referenceGroup, epoch: referenceEpoch, occurrence: referenceOccurrence, buffer: try SampleBuffer(samples: job.reference.samples, sampleRate: job.reference.rate)),
                tracks: [EstimatorTrack(group: targetGroup, epoch: targetEpoch, occurrence: targetOccurrence, buffer: try SampleBuffer(samples: job.target.samples, sampleRate: job.target.rate), declaredOverlap: job.overlap)],
                search: try SearchRange(centerOffsetSeconds: job.center, maximumDeviationSeconds: job.deviation)
            )
            return try AcousticEstimator.estimate(request)
        }
        var timeMap = onMain ? "ran on main thread" : "n/a (no proposal)"
        if case .success(let report) = result, let epoch = report.epochs.first, case .acousticConsistentProposal = epoch.outcome {
            do {
                let count = Int64(job.target.samples.count)
                let occurrence = try SourceOccurrence(id: targetOccurrence, source: SourceID(), nominalRate: NominalRate(Int64(job.target.rate)), frameCount: count)
                let map = try GroupTimeMap(
                    group: targetGroup,
                    reference: TimelineReference(group: referenceGroup, epoch: referenceEpoch, occurrence: referenceOccurrence),
                    epochs: [epoch.epochClockMap],
                    placements: [OccurrencePlacement(occurrence: occurrence, spans: [EpochSpan(startFrame: 0, endFrame: count, epoch: targetEpoch, groupClockOffset: .zero)])]
                )
                let overlap = job.overlap ?? 0 ..< job.target.samples.count
                let mid = Int64((overlap.lowerBound + overlap.upperBound) / 2)
                switch try map.alignedTime(ofFrame: mid, in: targetOccurrence) {
                case .aligned(let position): timeMap = "accepted by GroupTimeMap; mid-overlap frame maps (provenance \(position.provenance))"
                case let other: timeMap = "accepted by GroupTimeMap; mid-overlap frame \(other.regionState)"
                }
            } catch {
                timeMap = "REFUSED by GroupTimeMap: \(error)"
            }
            if onMain { timeMap += "; ran on main thread" }
        }
        return PairOutcome(job: job, result: result, seconds: Date().timeIntervalSince(started), timeMap: timeMap)
    }

    mutating func report(_ outcome: PairOutcome) {
        let job = outcome.job
        let overlap = job.overlap.map { "declared overlap \(f(Double($0.count) / Double(job.target.rate), 1)) s" } ?? "full overlap"
        let search = "search \(f(job.center, 3)) ± \(f(job.deviation, 0)) s, \(overlap)"
        if outcome.timeMap.contains("main thread") { findings.append("main-thread estimator work: \(job.name)") }
        switch outcome.result {
        case .failure(let error):
            log("\(job.name): ESTIMATOR ERROR \(error) | \(search)")
            findings.append("estimator error on \(job.name): \(error)")
        case .success(let report):
            for epoch in report.epochs {
                let c = epoch.coverage
                var counts: [WindowStatus: Int] = [:]
                for window in epoch.windows { counts[window.status, default: 0] += 1 }
                let statuses = WindowStatus.allCases.compactMap { s in counts[s].map { "\(s.rawValue) \($0)" } }.joined(separator: ", ")
                let scores = "median peak \(f(epoch.scores.medianPeakScore)), median margin \(f(epoch.scores.medianPeakMargin)) (evidence measures, not probabilities)"
                let coverage = "windows \(c.windowCount) [\(statuses)], eligible fraction \(f(c.eligibleWindowFraction, 2)), span fraction \(f(c.eligibleSpanFraction, 2))"
                let flags = epoch.flags.isEmpty ? "none" : epoch.flags.map(\.rawValue).sorted().joined(separator: ",")
                switch epoch.outcome {
                case .acousticConsistentProposal(let p):
                    log("\(job.name): PROPOSAL (acoustic-consistent, not clock-approved) offset \(f(p.offsetAtCenterSeconds * 1000, 3)) ms at centre, drift \(f(p.ppm, 3)) ppm, residual p95 \(f(p.acousticResidualP95Milliseconds, 3)) ms, max \(f(p.acousticResidualMaxMilliseconds, 3)) ms | \(coverage) | \(scores) | flags \(flags) | \(search) | time map: \(outcome.timeMap) | \(f(outcome.seconds, 1)) s")
                    if job.sameClock, abs(p.offsetAtCenterSeconds) > 0.020 {
                        findings.append("estimator anomaly: \(job.name) proposed \(f(p.offsetAtCenterSeconds * 1000, 1)) ms within one recorder (beyond a 20 ms acoustic path)")
                    }
                    if outcome.timeMap.hasPrefix("REFUSED") { findings.append("time map refused a proposal: \(job.name)") }
                case .abstained(let a):
                    let eligible = epoch.windows.filter { $0.status == .eligible }.compactMap(\.offsetSeconds).sorted()
                    let spread = eligible.isEmpty ? "no eligible windows" : "eligible-window offsets \(f(eligible.first!, 4))…\(f(eligible.last!, 4)) s, median \(f(eligible[eligible.count / 2], 4)) s"
                    log("\(job.name): ABSTAINED \(a.reason.rawValue) (\(a.detail)) | \(coverage) | \(scores) | \(spread) | flags \(flags) | \(search) | \(f(outcome.seconds, 1)) s")
                }
            }
        }
    }

    // MARK: Render

    mutating func render(_ groups: [Group], _ decoded: [Int: Decoded]) async throws {
        func channelTotal(_ group: Group) -> Int { group.members.reduce(0) { $0 + decoded[$1]!.interpretation.channelCount } }
        // The group with the most channels (ties: more members); one transform for all of its channels.
        guard let group = groups.max(by: { channelTotal($0) != channelTotal($1) ? channelTotal($0) < channelTotal($1) : $0.members.count < $1.members.count }) else {
            log("render: no decodable group")
            findings.append("render not run")
            return
        }
        let rate = Int64(group.rate)
        let first = decoded[group.members[0]]!.product
        let sliceStart = first.sliceStart
        let sliceFrames = Int64(first.slice.first?.count ?? 0)
        let outputCount = min(30 * rate, sliceFrames - 6 * rate)
        guard outputCount > rate else {
            log("render: \(group.label) too short for a render slice")
            findings.append("render not run")
            return
        }

        // A non-reference group map: one epoch, rate ratio 1 + 10 ppm and a 0.37-frame offset (manual numeric
        // entry), applied identically to every channel of every member.
        let segment = try AffineClockSegment(
            groupClockStart: .zero,
            groupClockEnd: try ExactRational(group.frames, rate),
            rateRatio: try ExactRational(1_000_010, 1_000_000),
            alignedOffset: try ExactRational(37, 100 * rate)
        )
        let epoch = RecordingEpochID()
        var placements: [OccurrencePlacement] = []
        var channels: [RenderChannel] = []
        var assets: [RenderInputAsset] = []
        var buffers: [SourceOccurrenceID: SliceProvider.Slice] = [:]
        var routes: [(occurrence: SourceOccurrenceID, channel: Int, label: String)] = []
        for member in group.members {
            let d = decoded[member]!
            let id = SourceOccurrenceID()
            let occurrence = try SourceOccurrence(id: id, source: SourceID(), nominalRate: NominalRate(rate), frameCount: group.frames)
            placements.append(OccurrencePlacement(occurrence: occurrence, spans: [EpochSpan(startFrame: 0, endFrame: group.frames, epoch: epoch, groupClockOffset: .zero)]))
            for c in 0 ..< d.interpretation.channelCount {
                channels.append(RenderChannel(occurrence: id, decodedChannel: c, statedChannel: .known(c)))
                routes.append((id, c, "\(d.label).\(c + 1)"))
            }
            assets.append(RenderInputAsset(occurrence: id, assetVersion: "local-validation-slice/\(d.label)"))
            buffers[id] = SliceProvider.Slice(start: d.product.sliceStart, channels: d.product.slice)
        }
        let map = try GroupTimeMap(
            group: RecorderGroupID(),
            reference: TimelineReference(group: RecorderGroupID(), epoch: RecordingEpochID(), occurrence: SourceOccurrenceID()),
            epochs: [EpochClockMap(epoch: epoch, mapping: .mapped(segments: [segment], provenance: .manual(ManualCorrection(basis: .numericEntry))))],
            placements: placements
        )
        let outputStart = sliceStart + 3 * rate
        let request = RenderRequest(groupMap: map, outputRate: try NominalRate(rate), outputFrames: outputStart ..< outputStart + outputCount, channels: channels, inputAssets: assets)

        let file = scratch.appendingPathComponent("render-\(group.label).f32")
        // The rendered asset is derived data: remove it however render() exits, before the operator deletes
        // the scratch directory itself.
        defer {
            if FileManager.default.fileExists(atPath: file.path) {
                let removed = (try? FileManager.default.removeItem(at: file)) != nil
                log("render \(group.label): scratch asset \(removed ? "removed" : "NOT removed (the scratch directory deletion still covers it)")")
            }
        }
        let provider = SliceProvider(buffers: buffers)
        let footprintBefore = Host.footprintMegabytes
        let started = Date()
        let result: RenderResult<RenderedAsset>
        do throws(RenderFailure) {
            result = try await GroupRenderer.render(request, provider: provider) { manifest in try FileSink(url: file, channelCount: manifest.channels.count) }
        } catch {
            log("render \(group.label): FAILED \(error)")
            findings.append("render failed: \(error)")
            return
        }
        let seconds = Date().timeIntervalSince(started)
        let asset = result.product
        let footprintAfter = Host.footprintMegabytes
        let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? -1

        // Channel count and shape, in memory, in the manifest and in the written scratch asset.
        let expectedBytes = Int64(channels.count) * outputCount * 4
        let shapeOK = asset.channels.count == channels.count && asset.channels.allSatisfy { Int64($0.count) == outputCount } && fileBytes == expectedBytes && result.manifest.channels.count == channels.count && asset.chunkChannelCountsConsistent
        let readBack = (try? Data(contentsOf: file)) ?? Data()
        let readBackOK = readBack.count == Int(expectedBytes) && readBack.withUnsafeBytes { raw -> Bool in
            let floats = raw.bindMemory(to: Float.self)
            for k in stride(from: 0, to: Int(outputCount), by: 997) {
                for c in 0 ..< channels.count where floats[k * channels.count + c] != asset.channels[c][k] { return false }
            }
            return true
        }
        log("render \(group.label): \(channels.count) output channels from \(group.members.count) members (\(routes.map(\.label).joined(separator: ","))) | \(outputCount) frames (\(f(Double(outputCount) / Double(rate), 1)) s) at \(rate) Hz | map: +10 ppm, 0.37-frame offset (manual numeric entry) | scratch asset \(fileBytes) bytes, read back \(readBackOK ? "matches" : "MISMATCH") | channel count/shape \(shapeOK ? "OK" : "FAIL") | sink on main thread: \(asset.sawMainThread)")
        log("render \(group.label): \(f(seconds, 2)) s, \(f(Double(outputCount) / Double(rate) / seconds, 1))x real time, \(f(Double(outputCount * Int64(channels.count)) / seconds / 1e6, 2)) M channel-frames/s | renderer peak working set \(f(Double(result.report.peakWorkingSetBytes) / 1e6, 2)) MB, peak window \(result.report.peakWindowFrames) frames, \(result.report.chunks) chunks, \(result.report.providerRequests) provider requests | process footprint \(footprintBefore) -> \(footprintAfter) MB, process peak RSS \(Host.peakRSSMegabytes) MB")
        if !shapeOK || !readBackOK { findings.append("render shape/channel-count invariant failed") }
        if asset.sawMainThread { findings.append("main-thread render work") }

        // Exact time-map round trip for every member at landmark frames.
        var exact = 0
        var total = 0
        for placement in placements {
            for frame in [0, group.frames / 2, sliceStart, outputStart, group.frames - 1] {
                total += 1
                guard case .aligned(let position) = try map.alignedTime(ofFrame: frame, in: placement.occurrence.id),
                      case .source(let back) = try map.sourceFrame(at: position.instant, in: placement.occurrence.id),
                      back.exactFrame == ExactRational(frame) else { continue }
                exact += 1
            }
        }
        log("render \(group.label): time-map round trip \(exact)/\(total) landmark frames exact")
        if exact != total { findings.append("time-map round trip failed \(total - exact)x") }

        // Interchannel skew: per 4096-frame block, each active channel's measured source position (normalised
        // cross-correlation peak, parabolic refinement) minus the exact mapped position; skew = max - min.
        let block = 4096
        var worstSkew = 0.0
        var worstError = 0.0
        var measuredBlocks = 0
        var activeChannelBlocks = 0
        for b in stride(from: 0, to: Int(outputCount) - block, by: block) {
            let k = outputStart + Int64(b)
            guard case .source(let p) = try map.sourceFrame(at: try ExactRational(k, rate), in: routes[0].occurrence) else { continue }
            let expected = p.exactFrame.approximateDouble
            var errors: [Double] = []
            for (index, route) in routes.enumerated() {
                let source = buffers[route.occurrence]!
                let out = Array(asset.channels[index][b ..< b + block])
                if let measured = Self.measurePosition(out, source: source.channels[route.channel], sourceStart: source.start, near: expected) {
                    errors.append(measured - expected)
                }
            }
            activeChannelBlocks += errors.count
            worstError = max(worstError, errors.map(abs).max() ?? 0)
            guard errors.count >= 2 else { continue }
            measuredBlocks += 1
            worstSkew = max(worstSkew, errors.max()! - errors.min()!)
        }
        let verdict = measuredBlocks == 0 ? "NOT MEASURED" : (worstSkew <= 1.0 ? "within" : "EXCEEDED")
        log("render \(group.label): interchannel skew max \(f(worstSkew, 4)) output frames over \(measuredBlocks) blocks with >= 2 active channels (\(activeChannelBlocks) active channel-blocks; gate 1 frame: \(verdict)) | max |measured - mapped source position| \(f(worstError, 4)) frames")
        if verdict != "within" { findings.append("render skew \(verdict) (\(f(worstSkew, 3)) frames)") }
    }

    /// Fractional source position whose content best matches the rendered block: normalised cross-correlation
    /// over integer lags near the expected position, refined by a parabola. Nil when the block is quiet or the
    /// match is weak.
    static func measurePosition(_ out: [Float], source: [Float], sourceStart: Int64, near expected: Double) -> Double? {
        let n = out.count
        let base = Int(expected.rounded(.down)) - Int(sourceStart)
        var outEnergy: Float = 0
        vDSP_svesq(out, 1, &outEnergy, vDSP_Length(n))
        guard (outEnergy / Float(n)).squareRoot() > 1e-4 else { return nil }
        let lags = -4 ... 4
        var scores: [Double] = []
        for lag in lags {
            let start = base + lag
            guard start >= 0, start + n <= source.count else { return nil }
            var dot: Float = 0
            var energy: Float = 0
            source.withUnsafeBufferPointer { s in
                vDSP_dotpr(out, 1, s.baseAddress! + start, 1, &dot, vDSP_Length(n))
                vDSP_svesq(s.baseAddress! + start, 1, &energy, vDSP_Length(n))
            }
            scores.append(Double(dot) / max(1e-20, Double((outEnergy * energy).squareRoot())))
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] >= 0.5, best > 0, best < scores.count - 1 else { return nil }
        let (l, c, r) = (scores[best - 1], scores[best], scores[best + 1])
        let denominator = l - 2 * c + r
        let delta = denominator == 0 ? 0 : 0.5 * (l - r) / denominator
        return Double(Int(sourceStart) + base + lags.lowerBound + best) + delta
    }
}

// MARK: - Sinks and provider

/// What the analysis decode keeps: a zero-phase low-passed, decimated mono mix (analysis only, never
/// written) plus a short full-rate slice of every channel for the render check.
private struct AnalysisProduct: Sendable {
    let analysis: [Float]
    let analysisRate: Int
    let sliceStart: Int64
    let slice: [[Float]]
    let peak: Float
    let sawMainThread: Bool
}

private struct AnalysisSink: DecodedAudioSink {
    let channelCount: Int
    let totalFrames: Int64
    let analysisRate: Int
    let sliceStart: Int64
    let sliceEnd: Int64
    var decimator: Decimator
    var slice: [[Float]]
    var decoded: Int64 = 0
    var peak: Float = 0
    var sawMainThread = false
    var mono: [Float] = []

    init(_ interpretation: FormatInterpretation, sliceStartSeconds: Int? = nil) {
        channelCount = interpretation.channelCount
        totalFrames = interpretation.frames.validFrames
        let rate = interpretation.sourceSampleRate
        let factor = Self.factor(for: rate)
        analysisRate = rate / factor
        decimator = Decimator(factor: factor)
        sliceStart = sliceStartSeconds.map { Int64($0 * rate) } ?? (totalFrames * 2 / 5) / 1000 * 1000
        sliceEnd = min(totalFrames, sliceStart + 36 * Int64(rate))
        slice = Array(repeating: [], count: channelCount)
    }

    /// Largest integer factor that keeps an integer analysis rate of at least 8 kHz (the estimator floor).
    static func factor(for rate: Int) -> Int {
        var best = 1
        for d in 1 ... 64 where rate % d == 0 && rate / d >= 8000 { best = d }
        return best
    }

    mutating func append(_ chunk: DecodedChunk) throws {
        if pthread_main_np() != 0 { sawMainThread = true }
        let n = chunk.frameCount
        mono = [Float](repeating: 0, count: n)
        chunk.samples.withUnsafeBufferPointer { all in
            for c in 0 ..< channelCount {
                vDSP_vadd(mono, 1, all.baseAddress! + c * n, 1, &mono, 1, vDSP_Length(n))
            }
            var chunkPeak: Float = 0
            vDSP_maxmgv(all.baseAddress!, 1, &chunkPeak, vDSP_Length(all.count))
            peak = max(peak, chunkPeak)
        }
        var scale = 1 / Float(channelCount)
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))
        decimator.push(mono)

        let lo = max(decoded, sliceStart)
        let hi = min(decoded + Int64(n), sliceEnd)
        if lo < hi {
            for c in 0 ..< channelCount {
                let base = c * n
                slice[c].append(contentsOf: chunk.samples[base + Int(lo - decoded) ..< base + Int(hi - decoded)])
            }
        }
        decoded += Int64(n)
    }

    mutating func finish() throws -> AnalysisProduct {
        guard decoded == totalFrames else { throw HarnessError("frame count mismatch") }
        let analysis = decimator.finish(inputFrames: Int(totalFrames))
        return AnalysisProduct(analysis: analysis, analysisRate: analysisRate, sliceStart: sliceStart, slice: slice, peak: peak, sawMainThread: sawMainThread)
    }
}

private struct CopySliceSink: DecodedAudioSink {
    let channelCount: Int
    let start: Int64
    let end: Int64
    var decoded: Int64 = 0
    var channels: [[Float]]

    init(_ format: FormatInterpretation, startSeconds: Int) {
        channelCount = format.channelCount
        start = Int64(startSeconds) * Int64(format.sourceSampleRate)
        end = min(format.frames.validFrames, start + 36 * Int64(format.sourceSampleRate))
        channels = Array(repeating: [], count: channelCount)
    }

    mutating func append(_ chunk: DecodedChunk) throws {
        let lo = max(decoded, start)
        let hi = min(decoded + Int64(chunk.frameCount), end)
        if lo < hi {
            for channel in 0 ..< channelCount {
                let base = channel * chunk.frameCount
                channels[channel].append(contentsOf: chunk.samples[
                    base + Int(lo - decoded) ..< base + Int(hi - decoded)
                ])
            }
        }
        decoded += Int64(chunk.frameCount)
    }

    mutating func finish() throws -> [[Float]] {
        guard channels.allSatisfy({ $0.count == Int(end - start) }) else {
            throw HarnessError("short copy frame count mismatch")
        }
        return channels
    }
}

/// Streaming zero-phase FIR decimator (Blackman-windowed sinc, 16·D + 1 taps, cutoff 0.4/D cycles per input
/// sample). Output sample j is centred on input sample j·D, so every source keeps its time origin.
private struct Decimator {
    let factor: Int
    let taps: [Float]
    let half: Int
    var pending: [Float]
    var output: [Float] = []

    init(factor: Int) {
        self.factor = factor
        if factor == 1 {
            taps = [1]
            half = 0
        } else {
            let length = 16 * factor + 1
            let h = 8 * factor
            let cutoff = 0.4 / Double(factor)
            let raw = (0 ..< length).map { i -> Double in
                let x = Double(i - h)
                let sinc = x == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * x) / (.pi * x)
                let phase = Double(i) / Double(length - 1)
                return sinc * (0.42 - 0.5 * cos(2 * .pi * phase) + 0.08 * cos(4 * .pi * phase))
            }
            let sum = raw.reduce(0, +)
            taps = raw.map { Float($0 / sum) }
            half = h
        }
        pending = [Float](repeating: 0, count: half)
    }

    mutating func push(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        drain()
    }

    private mutating func drain() {
        let length = taps.count
        guard pending.count >= length else { return }
        let count = (pending.count - length) / factor + 1
        var produced = [Float](repeating: 0, count: count)
        vDSP_desamp(pending, vDSP_Stride(factor), taps, &produced, vDSP_Length(count), vDSP_Length(length))
        output.append(contentsOf: produced)
        pending.removeFirst(count * factor)
    }

    mutating func finish(inputFrames: Int) -> [Float] {
        pending.append(contentsOf: [Float](repeating: 0, count: half + factor))
        drain()
        return Array(output.prefix((inputFrames + factor - 1) / factor))
    }
}

/// Serves render requests from the captured in-memory slices.
private struct SliceProvider: RenderSampleProvider {
    struct Slice: Sendable {
        let start: Int64
        let channels: [[Float]]
    }

    let buffers: [SourceOccurrenceID: Slice]

    func samples(for request: RenderSampleRequest) async throws -> [[Float]] {
        guard let buffer = buffers[request.occurrence] else { throw HarnessError("unknown occurrence") }
        let lo = Int(request.frames.lowerBound - buffer.start)
        let hi = Int(request.frames.upperBound - buffer.start)
        guard lo >= 0, hi <= (buffer.channels.first?.count ?? 0) else { throw HarnessError("request outside the captured slice") }
        return request.decodedChannels.map { Array(buffer.channels[$0][lo ..< hi]) }
    }
}

private struct RenderedAsset: Sendable {
    let channels: [[Float]]
    let sawMainThread: Bool
    let chunkChannelCountsConsistent: Bool
}

/// Writes interleaved binary32 frames to a scratch file (derived data, deleted with the scratch directory)
/// and keeps planar copies for the invariant checks.
private struct FileSink: RenderOutputSink {
    let url: URL
    let handle: FileHandle
    var channels: [[Float]]
    var sawMainThread = false
    var consistent = true

    init(url: URL, channelCount: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw HarnessError("cannot create scratch file") }
        self.url = url
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw HarnessError("cannot open scratch asset: \(ConsentGuards.errnoDescription(error))")
        }
        channels = Array(repeating: [], count: channelCount)
    }

    mutating func append(_ chunk: RenderedChunk) throws {
        if pthread_main_np() != 0 { sawMainThread = true }
        if chunk.channelCount != channels.count { consistent = false }
        var interleaved = [Float](repeating: 0, count: chunk.frameCount * chunk.channelCount)
        for c in 0 ..< chunk.channelCount {
            let planar = chunk.samples[c * chunk.frameCount ..< (c + 1) * chunk.frameCount]
            channels[c].append(contentsOf: planar)
            for (i, value) in planar.enumerated() { interleaved[i * chunk.channelCount + c] = value }
        }
        do {
            try handle.write(contentsOf: interleaved.withUnsafeBufferPointer { Data(buffer: $0) })
        } catch {
            throw HarnessError("scratch asset write failed: \(ConsentGuards.errnoDescription(error))")
        }
    }

    mutating func finish() throws -> RenderedAsset {
        do {
            try handle.close()
        } catch {
            throw HarnessError("scratch asset close failed: \(ConsentGuards.errnoDescription(error))")
        }
        return RenderedAsset(channels: channels, sawMainThread: sawMainThread, chunkChannelCountsConsistent: consistent)
    }

    mutating func abandon() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

// The manual run uses gateway-decoded, channel-preserving short copies. No original is opened by
// the pipeline's renderer; its source inputs are the disposable copies.
private extension Harness {
    func writeSlice(_ channels: [[Float]], rate: Int, to url: URL) throws {
        let frames = channels.first?.count ?? 0
        guard frames > 0,
              channels.allSatisfy({ $0.count == frames }),
              frames * channels.count * 4 < Int(UInt32.max) - 36 else {
            throw HarnessError("invalid slice shape")
        }
        let bytes = UInt32(frames * channels.count * 4)
        var wave = Data(capacity: 44 + Int(bytes))
        func ascii(_ text: String) { wave.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wave.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wave.append(contentsOf: $0) } }
        ascii("RIFF"); u32(36 + bytes); ascii("WAVEfmt ")
        u32(16); u16(3); u16(UInt16(channels.count)); u32(UInt32(rate))
        u32(UInt32(rate * channels.count * 4)); u16(UInt16(channels.count * 4)); u16(32)
        ascii("data"); u32(bytes)
        for frame in 0 ..< frames {
            for channel in channels {
                u32(channel[frame].bitPattern)
            }
        }
        try wave.write(to: url, options: .atomic)
    }

    func writeSlice(_ decoded: Decoded, to url: URL) throws {
        guard decoded.product.slice.count == decoded.interpretation.channelCount else {
            throw HarnessError("invalid slice channel count")
        }
        try writeSlice(decoded.product.slice, rate: decoded.interpretation.sourceSampleRate, to: url)
    }

    mutating func runManual() async throws {
        let started = Date()
        log("manual pipeline host: \(Host.summary)")
        var items = try enumerate()
        let before = try snapshot(items)
        items = number(items, snapshots: before)
        var stepFailure: HarnessError?
        do {
            try await manualSteps(items)
        } catch {
            stepFailure = HarnessError("manual pipeline step failed: \(type(of: error))")
            findings.append("manual pipeline step failed")
            log("manual pipeline step failed: \(type(of: error))")
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        if !remaining.isEmpty {
            findings.append("temporary manual inputs or derived assets not deleted")
            log("manual scratch cleanup: FAILED (\(remaining.count) entries)")
        } else {
            log("manual scratch cleanup: empty")
        }
        let after = try snapshot(items)
        verifyUnchanged(items, before: before, after: after)
        log("manual pipeline wall \(f(Date().timeIntervalSince(started), 1)) s; process peak RSS \(Host.peakRSSMegabytes) MB")
        if let stepFailure { throw stepFailure }
        if !findings.isEmpty { throw HarnessError("manual pipeline findings: \(findings.joined(separator: "; "))") }
    }

    mutating func manualSteps(_ items: [Item]) async throws {
        var decoded: [Int: Decoded] = [:]
        for item in items where item.isAudio {
            let start: Int
            switch item.number {
            case 7, 10: start = 1702
            case 11: start = 1704
            case 12: start = 1706
            default: start = 1700
            }
            if let result = await decode(item, sliceStartSeconds: start) { decoded[item.number] = result }
        }
        let groups = proposeGroups(decoded)
        guard groups.count == 4, groups.map(\.members) == [[1, 2, 3, 4, 5, 6, 8, 9], [7, 10], [11], [12]],
              decoded.count == items.filter(\.isAudio).count - 1 else {
            throw HarnessError("unexpected supported-source or group count")
        }
        let copies = scratch.appendingPathComponent("manual-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: false)
        defer {
            do {
                try FileManager.default.removeItem(at: copies)
                log("manual temporary copies: deleted")
            } catch {
                log("manual temporary copies: deletion FAILED")
            }
        }
        let cache = scratch.appendingPathComponent("manual-cache", isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: cache)
                log("manual derived assets: deleted")
            } catch {
                log("manual derived assets: deletion FAILED")
            }
        }
        let store = try DerivedAssetStore(root: cache, sourceLocations: [episode])
        let coordinator = DerivedJobCoordinator(store: store)
        let decoder = SourceDecoder(access: SourceAccessContext(io: io))
        let pipeline = AlignmentPipeline(
            coordinator: coordinator, decoder: decoder,
            configuration: AlignmentPipelineConfiguration(concurrency: 1, targetExcerptSeconds: 20,
                searchDeviationSeconds: 5, renderSegmentSeconds: 6)
        )

        let episodeID = EpisodeID()
        var recorderGroups: [RecorderGroup] = []
        var records: [SourceRecord] = []
        var sources: [AlignmentSource] = []
        var originalSources: [AlignmentSource] = []
        var authorizations: [ContentWorkAuthorization] = []
        var epochs: [RecordingEpochID] = []
        var expectedChannels: [[String]] = []
        for group in groups {
            let groupID = RecorderGroupID()
            let epoch = RecordingEpochID()
            epochs.append(epoch)
            recorderGroups.append(RecorderGroup(id: groupID, name: group.label, epochs: [RecordingEpoch(id: epoch, label: "Take 1")]))
            var channelKeys: [String] = []
            for member in group.members {
                let source = SourceID()
                let url = copies.appendingPathComponent("\(sLabel(member)).wav")
                try writeSlice(decoded[member]!, to: url)
                records.append(SourceRecord(id: source, displayNameHint: sLabel(member), placement: SourcePlacement(recorderGroupID: groupID, epochID: epoch)))
                sources.append(AlignmentSource(id: source, url: url, availability: .on))
                let original = try #require(items.first { $0.number == member })
                originalSources.append(AlignmentSource(id: source, url: original.url, availability: .on))
                channelKeys += (0 ..< decoded[member]!.interpretation.channelCount).map { "\(source.rawValue)/\($0)" }
                authorizations.append(.explicitUserRequest(for: source))
                guard case let .success(metadata) = io.metadata(at: url) else { throw HarnessError("temporary copy metadata unavailable") }
                await coordinator.updateSource(SourceRevision.metadata(source, fingerprint: metadata.fingerprint))
            }
            expectedChannels.append(channelKeys)
        }
        var model = ShowDocumentModel(
            show: Show(title: "Local validation"),
            episodes: [Episode(id: episodeID, title: "Local validation", recorderGroups: recorderGroups, sources: records)]
        )
        let reference = sources[0].id
        let originalCache = scratch.appendingPathComponent("original-analysis-cache", isDirectory: true)
        defer {
            do {
                try FileManager.default.removeItem(at: originalCache)
                log("full-source analysis cache: deleted")
            } catch {
                log("full-source analysis cache: deletion FAILED")
            }
        }
        let originalStore = try DerivedAssetStore(root: originalCache, sourceLocations: [episode])
        let originalCoordinator = DerivedJobCoordinator(store: originalStore)
        for source in originalSources {
            guard case let .success(metadata) = io.metadata(at: source.url) else {
                throw HarnessError("original source registration metadata unavailable")
            }
            await originalCoordinator.updateSource(SourceRevision.metadata(source.id, fingerprint: metadata.fingerprint))
        }
        let originalPipeline = AlignmentPipeline(
            coordinator: originalCoordinator, decoder: decoder,
            configuration: AlignmentPipelineConfiguration(concurrency: 1, targetExcerptSeconds: 600,
                searchDeviationSeconds: 120, renderSegmentSeconds: 6)
        )
        let fullAnalysis = try #require(await originalPipeline.analyse(model: model, episode: episodeID,
            sources: originalSources, authorizations: authorizations, preferredReference: reference))
        guard fullAnalysis.plan.epochs.count == groups.count, fullAnalysis.sourceFailures.isEmpty,
              fullAnalysis.epochFailures.isEmpty, fullAnalysis.facts.count == decoded.count else {
            throw HarnessError("full-source pipeline analysis failed")
        }
        for (index, epoch) in epochs.enumerated() where index > 0 {
            guard let record = fullAnalysis.records[epoch] else { throw HarnessError("full-source epoch missing") }
            log("\(groups[index].label) full-source analysis: \(record.abstention.map { "ABSTAINED \($0.reason)" } ?? "PROPOSAL (not clock-approved)"); eligible \(record.coverage.eligibleCount)/\(record.coverage.windowCount)")
        }
        await originalPipeline.shutdown()
        let plan = try #require(await pipeline.plan(model: model, episode: episodeID, sources: sources,
            authorizations: authorizations, preferredReference: reference))
        guard plan.epochs.count == groups.count, plan.ineligible.isEmpty else { throw HarnessError("manual plan incomplete") }
        log("manual plan: \(groups.count) groups, \(decoded.count) eligible sources; all channels copied from gateway-decoded 36 s excerpts")
        let analysis = try #require(await pipeline.analyse(model: model, episode: episodeID, sources: sources,
            authorizations: authorizations, preferredReference: reference))
        guard analysis.sourceFailures.isEmpty, analysis.epochFailures.isEmpty, analysis.facts.count == decoded.count else {
            throw HarnessError("manual analysis probe or epoch failed")
        }
        for (index, epoch) in epochs.enumerated() where index > 0 {
            guard let record = analysis.records[epoch] else { throw HarnessError("manual analysis missing epoch") }
            log("\(groups[index].label) pipeline analysis: \(record.abstention.map { "ABSTAINED \($0.reason)" } ?? "PROPOSAL (not clock-approved)"); eligible \(record.coverage.eligibleCount)/\(record.coverage.windowCount)")
        }
        let referenceStart = Double(decoded[groups[0].members[0]]!.product.sliceStart) / Double(groups[0].rate)
        var decisions: [RecordingEpochID: EpochMapDecision] = [:]
        for index in 1 ..< groups.count {
            let group = groups[index]
            let start = Double(decoded[group.members[0]]!.product.sliceStart) / Double(group.rate)
            let offsetMilliseconds = (start - referenceStart) * 1000
            decisions[epochs[index]] = .numeric(ppm: 0, offsetMilliseconds: offsetMilliseconds,
                note: "Operator equal-origin placement of gateway-decoded excerpts; no clock truth")
            log("\(group.label) operator entry: 0 ppm, \(f(offsetMilliseconds, 3)) ms (difference of excerpt start frame/rate)")
        }
        let accepted = try await pipeline.accept(model: model, episode: episodeID, report: analysis, decisions: decisions)
        model = accepted.model
        try await pipeline.activate(accepted)
        let states = await pipeline.states(model: model, episode: episodeID, report: analysis)
        guard states.count == groups.count,
              states[0].status == .reference,
              states.dropFirst().allSatisfy({ $0.status == .manual(.numericEntry, revision: accepted.revision.revision) }) else {
            throw HarnessError("accepted states do not match reference and manual decisions")
        }
        log("manual acceptance: U1 reference, 3 U4 numeric manual epochs, revision \(accepted.revision.revision), one map digest; no clock approval")

        let cancelledStarted = Date()
        let renderModel = model
        let renderSources = sources
        let renderAuthorizations = authorizations
        let cancelledTask = Task.detached(priority: .utility) { [pipeline, renderModel, renderSources, renderAuthorizations, episodeID] in
            try await pipeline.renderAlignedAssets(model: renderModel, episode: episodeID,
                sources: renderSources, authorizations: renderAuthorizations)
        }
        try await Task.sleep(for: .milliseconds(200))
        cancelledTask.cancel()
        let cancelled = try await cancelledTask.value
        let cancellationSeconds = Date().timeIntervalSince(cancelledStarted)
        guard !cancelled.isComplete, cancellationSeconds < 5 else {
            throw HarnessError("active render cancellation did not stop within 5 s")
        }
        log("active render cancellation: incomplete, returned in \(f(cancellationSeconds, 3)) s")
        let renderStarted = Date()
        let rendered = try await pipeline.renderAlignedAssets(model: model, episode: episodeID,
            sources: sources, authorizations: authorizations)
        guard rendered.isComplete, rendered.notRendered.isEmpty, rendered.groups.count == groups.count else {
            throw HarnessError("manual aligned render incomplete")
        }
        for (index, group) in rendered.groups.enumerated() {
            let results = group.results.filter(\.isAvailable)
            var channelSpans: [String: [Range<Int64>]] = [:]
            var digests = Set<String>()
            for result in results {
                guard let payload = store.payload(for: result.key) else { throw HarnessError("missing aligned asset payload") }
                let header = try AlignedAudioSegment.decode(payload).header
                let key = "\(header.source.rawValue)/\(header.decodedChannel)"
                channelSpans[key, default: []].append(header.firstOutputFrame ..< (header.firstOutputFrame + Int64(header.frameCount)))
                digests.insert(header.mapDigest)
                guard header.group == group.group, header.outputRate == group.outputRate,
                      header.map == accepted.revision else {
                    throw HarnessError("aligned asset header disagrees with accepted map")
                }
            }
            guard group.outputRate == 48_000, group.outputFrames.count == 1_728_000,
                  Set(channelSpans.keys) == Set(expectedChannels[index]),
                  digests == [accepted.mapContentDigest] else {
                throw HarnessError("aligned asset channel, frame or digest mismatch")
            }
            for spans in channelSpans.values {
                var next = group.outputFrames.lowerBound
                for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                    guard span.lowerBound == next else { throw HarnessError("aligned channel has a gap or overlap") }
                    next = span.upperBound
                }
                guard next == group.outputFrames.upperBound else { throw HarnessError("aligned channel frame count mismatch") }
            }
            log("\(groups[index].label) assets: \(expectedChannels[index].count) channels, \(group.outputFrames.count) frames/channel, \(results.count) segment assets, one accepted map digest")
        }
        log("manual render: \(f(Date().timeIntervalSince(renderStarted), 2)) s, \(rendered.groups.count) groups, \(rendered.groups.reduce(0) { $0 + $1.results.count }) assets")
        let shutdownStarted = Date()
        await pipeline.shutdown()
        let shutdownSeconds = Date().timeIntervalSince(shutdownStarted)
        log("pipeline cancellation/shutdown idle response: \(f(shutdownSeconds, 3)) s")
        guard shutdownSeconds < 5 else { throw HarnessError("pipeline shutdown exceeded 5 s") }
    }
}

private extension Harness {
    static let memoryMembers = [[1, 2, 3, 4, 5, 6, 8, 9], [7, 10], [11], [12]]

    mutating func runIsolatedMemoryPhase(_ phase: String) async throws {
        let listed = try enumerate()
        let withInodes: [(Item, UInt64)] = try listed.map { item in
            var status = stat()
            guard lstat(item.url.path, &status) == 0 else {
                throw HarnessError("source metadata unavailable for numbering")
            }
            return (item, UInt64(status.st_ino))
        }
        let mapPath = try #require(Env.labelMap, "set the temporary pre-snapshot label map")
        let labels: String
        do {
            labels = try String(contentsOfFile: mapPath, encoding: .utf8)
        } catch {
            throw HarnessError("temporary label map unreadable")
        }
        var byInode: [UInt64: Int] = [:]
        for entry in labels.split(separator: "\n") {
            let pair = entry.split(separator: ":")
            guard pair.count == 2, let number = Int(pair[0]), let inode = UInt64(pair[1]),
                  byInode.updateValue(number, forKey: inode) == nil else {
                throw HarnessError("temporary label map malformed")
            }
        }
        let items = try withInodes.filter { $0.0.isAudio }.map { item, inode in
            guard let number = byInode[inode] else { throw HarnessError("source label map changed") }
            var numbered = item
            numbered.number = number
            return numbered
        }
        guard items.count == 13, byInode.count == 13, Set(items.map(\.number)) == Set(1 ... 13) else {
            throw HarnessError("temporary label map incomplete")
        }
        guard items.filter(\.isAudio).count == 13 else { throw HarnessError("unexpected audio item count") }
        let phaseDirectory = scratch.appendingPathComponent("phase-work", isDirectory: true)
        var failure: HarnessError?
        do {
            try await isolatedMemoryWork(phase, items: items, root: phaseDirectory)
        } catch {
            failure = error as? HarnessError ?? HarnessError("isolated \(phase) phase failed: \(type(of: error))")
        }
        if FileManager.default.fileExists(atPath: phaseDirectory.path) {
            do {
                try FileManager.default.removeItem(at: phaseDirectory)
            } catch {
                throw HarnessError("phase scratch cleanup failed: \(ConsentGuards.errnoDescription(error))")
            }
        }
        guard try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty else {
            throw HarnessError("phase scratch not empty after cleanup")
        }
        if let failure { throw failure }
        log("memory \(phase): scratch empty; run separate before/after snapshot processes to check originals")
    }

    func isolatedMemoryWork(_ phase: String, items: [Item], root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let copies = root.appendingPathComponent("inputs", isDirectory: true)
        if phase == "render" {
            try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: false)
        }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let store = try DerivedAssetStore(root: cache, sourceLocations: [episode])
        let coordinator = DerivedJobCoordinator(store: store)
        let decoder = SourceDecoder(access: SourceAccessContext(io: io))
        let pipeline = AlignmentPipeline(coordinator: coordinator, decoder: decoder,
            configuration: AlignmentPipelineConfiguration(concurrency: 1,
                targetExcerptSeconds: phase == "original" ? 600 : 20,
                searchDeviationSeconds: phase == "original" ? 120 : 5, renderSegmentSeconds: 6))
        let episodeID = EpisodeID()
        var groups: [RecorderGroup] = []
        var records: [SourceRecord] = []
        var sources: [AlignmentSource] = []
        var authorizations: [ContentWorkAuthorization] = []
        var epochs: [RecordingEpochID] = []
        var rates: [Int] = []
        var channelCounts: [Int] = []

        for (groupIndex, members) in Self.memoryMembers.enumerated() {
            let groupID = RecorderGroupID()
            let epoch = RecordingEpochID()
            epochs.append(epoch)
            groups.append(RecorderGroup(id: groupID, name: "G\(groupIndex + 1)",
                epochs: [RecordingEpoch(id: epoch, label: "Take 1")]))
            for member in members {
                guard let original = items.first(where: { $0.number == member && $0.isAudio }) else {
                    throw HarnessError("supported-source layout changed")
                }
                let source = SourceID()
                let url: URL
                if phase == "render" {
                    let start = [1700, 1702, 1704, 1706][groupIndex]
                    let result: (FormatInterpretation, [[Float]])
                    do throws(DecodeFailure) {
                        let decoded = try await decoder.decode(original.url, source: source) {
                            CopySliceSink($0, startSeconds: start)
                        }
                        result = (decoded.interpretation, decoded.product)
                    } catch {
                        throw HarnessError("short-copy decode refused \(sLabel(member)): \(Self.describe(error))")
                    }
                    guard result.1.count == result.0.channelCount else {
                        throw HarnessError("short-copy channel mismatch")
                    }
                    rates.append(result.0.sourceSampleRate)
                    channelCounts.append(result.0.channelCount)
                    url = copies.appendingPathComponent("\(sLabel(member)).wav")
                    try writeSlice(result.1, rate: result.0.sourceSampleRate, to: url)
                } else {
                    url = original.url
                }
                records.append(SourceRecord(id: source, displayNameHint: sLabel(member),
                    placement: SourcePlacement(recorderGroupID: groupID, epochID: epoch)))
                sources.append(AlignmentSource(id: source, url: url, availability: .on))
                authorizations.append(.explicitUserRequest(for: source))
                guard case let .success(metadata) = io.metadata(at: url) else {
                    throw HarnessError("phase source registration metadata unavailable")
                }
                await coordinator.updateSource(SourceRevision.metadata(source, fingerprint: metadata.fingerprint))
            }
        }
        let model = ShowDocumentModel(show: Show(title: "Local validation"),
            episodes: [Episode(id: episodeID, title: "Local validation",
                recorderGroups: groups, sources: records)])
        let reference = sources[0].id
        if phase == "original" {
            let baseline = try PhaseMemorySampler.now()
            let sampler = PhaseMemorySampler(baseline: baseline)
            let started = Date()
            let analysis = await pipeline.analyse(model: model, episode: episodeID,
                sources: sources, authorizations: authorizations, preferredReference: reference)
            let peak = try sampler.stop()
            log("memory original: idle \(baseline.megabytes); peak \(peak.megabytes); elapsed \(f(Date().timeIntervalSince(started), 2)) s")
            guard let analysis, analysis.plan.epochs.count == 4, analysis.facts.count == 12,
                  analysis.sourceFailures.isEmpty, analysis.epochFailures.isEmpty,
                  epochs.dropFirst().allSatisfy({ analysis.records[$0] != nil }) else {
                throw HarnessError("full-original pipeline analysis incomplete")
            }
            for index in 1 ..< epochs.count {
                let record = analysis.records[epochs[index]]!
                log("memory original G\(index + 1): \(record.abstention.map { "ABSTAINED \($0.reason)" } ?? "PROPOSAL (not clock-approved)"); eligible \(record.coverage.eligibleCount)/\(record.coverage.windowCount)")
            }
        } else {
            guard rates.count == 12, channelCounts.reduce(0, +) == 19 else {
                throw HarnessError("short-copy source layout changed")
            }
            let analysis = try #require(await pipeline.analyse(model: model, episode: episodeID,
                sources: sources, authorizations: authorizations, preferredReference: reference))
            guard analysis.sourceFailures.isEmpty, analysis.epochFailures.isEmpty,
                  analysis.facts.count == 12 else { throw HarnessError("copy pipeline analysis incomplete") }
            var decisions: [RecordingEpochID: EpochMapDecision] = [:]
            for index in 1 ..< epochs.count {
                decisions[epochs[index]] = .numeric(ppm: 0,
                    offsetMilliseconds: Double(2 * index * 1000),
                    note: "Operator equal-origin short-copy placement; no clock truth")
            }
            let accepted = try await pipeline.accept(model: model, episode: episodeID,
                report: analysis, decisions: decisions)
            try await pipeline.activate(accepted)
            let baseline = try PhaseMemorySampler.now()
            let sampler = PhaseMemorySampler(baseline: baseline)
            let started = Date()
            let rendered = try await pipeline.renderAlignedAssets(model: accepted.model,
                episode: episodeID, sources: sources, authorizations: authorizations)
            let peak = try sampler.stop()
            log("memory render: idle \(baseline.megabytes); peak \(peak.megabytes); elapsed \(f(Date().timeIntervalSince(started), 2)) s")
            guard rendered.isComplete, rendered.notRendered.isEmpty, rendered.groups.count == 4,
                  rendered.groups.reduce(0, { $0 + $1.results.count }) == 118,
                  rendered.groups.allSatisfy({ $0.outputRate == 48_000 && $0.outputFrames.count == 1_728_000 }) else {
                throw HarnessError("short-copy aligned render incomplete")
            }
            log("memory render: 36 s/channel, 19 channels, 118 assets; copy preparation excluded from measurement")
        }
        await pipeline.shutdown()
    }
}

// MARK: - Host facts

private final class PhaseMemorySampler: @unchecked Sendable {
    struct Reading {
        let resident: Int
        let footprint: Int
        var megabytes: String { "RSS \(resident >> 20) MiB, footprint \(footprint >> 20) MiB" }
    }

    private let condition = NSCondition()
    private var running = true
    private var finished = false
    private var samplingFailed = false
    private var peak: Reading

    static func now() throws -> Reading {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw HarnessError("task VM memory measurement failed") }
        return Reading(resident: Int(info.resident_size), footprint: Int(info.phys_footprint))
    }

    init(baseline: Reading) {
        peak = baseline
        let thread = Thread { [self] in
            condition.lock()
            while running {
                condition.unlock()
                if let sample = try? Self.now() {
                    condition.lock()
                    peak = Reading(resident: max(peak.resident, sample.resident),
                                   footprint: max(peak.footprint, sample.footprint))
                } else {
                    condition.lock()
                    samplingFailed = true
                }
                _ = condition.wait(until: Date().addingTimeInterval(0.002))
            }
            finished = true
            condition.broadcast()
            condition.unlock()
        }
        thread.stackSize = 1 << 20
        thread.start()
    }

    func stop() throws -> Reading {
        condition.lock()
        running = false
        condition.broadcast()
        while !finished { condition.wait() }
        let sampled = peak
        let failed = samplingFailed
        condition.unlock()
        guard !failed else { throw HarnessError("task VM memory sampling failed") }
        let final = try Self.now()
        return Reading(resident: max(sampled.resident, final.resident),
                       footprint: max(sampled.footprint, final.footprint))
    }
}

private enum Host {
    static var summary: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        let name = String(decoding: brand.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return "\(name), \(info.processorCount) cores, \(info.physicalMemory >> 30) GB, macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    /// Process-wide peak resident set (macOS reports ru_maxrss in bytes).
    static var peakRSSMegabytes: Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss) >> 20
    }

    static var footprintMegabytes: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint >> 20) : -1
    }
}
