import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import WWSpeech

@Suite("Opt-in public chunking and timing comparison", .serialized)
struct TranscriptionChunkingCorpusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WW_ASR_CHUNKING_FIXTURES"] != nil))
    func optedInPublicLongAudioComparesFixedPauseAndShortTimingControls() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WW_ASR_CHUNKING_FIXTURES"]))
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: root.appendingPathComponent("chunking/manifest.json")))
        try #require(manifest.clips.count == 2)
        for (index, clip) in manifest.clips.enumerated() {
            try #require(clip.source == "downloads/ES2002a.Headset-1.wav")
            try #require(clip.source_sha256 == "285ed5b5eaa4f871cc146900d0cf87487ca757aa57a7062def2eb49feaabc23d")
            try #require(clip.start == [55.73, 394.62][index] && clip.end == [165.91, 487.21][index])
        }
        let configuration = try TranscriptionConfiguration.resolve(backend: .metal, threads: .four)
        let pool = TranscriptionWorkerPool(concurrency: .one)
        for weights in LocalWhisperWeights.allCases {
            let resources = try TranscriptionResources(weights: weights, configuration: configuration)
            try await pool.withAdmission(resources: resources) {
                let source = manifest.clips[0]
                try #require(try Self.digest(root.appendingPathComponent(source.source)) == source.source_sha256)
                let engine = try await LocalWhisper.load(url: root.appendingPathComponent("downloads/\(weights.filename)"),
                                                        weights: weights, configuration: configuration)
                let modes = ProcessInfo.processInfo.environment["WW_ASR_CHUNKING_SWEEP"] == "1"
                    ? ["pause300", "pause400", "pause600", "pause800", "pause1000"] : ["fixed", "pause", "short10"]
                for mode in modes {
                    var outputs: [Output] = []
                    for clip in manifest.clips {
                        let file = try AVAudioFile(forReading: root.appendingPathComponent(clip.source))
                        try #require(file.processingFormat.channelCount == 1 && file.processingFormat.sampleRate == 16_000)
                        let last = Int64(((clip.end - clip.start) * 48_000).rounded())
                        var planner = try TranscriptionChunkPlanner(start: 0, end: Double(last) / 48_000,
                            policy: mode == "pause" ? .pausePreferred : .fixed)
                        var cursor: Int64 = 0
                        let researchMinimum = mode.hasPrefix("pause") ? Int(mode.dropFirst(5)).map { $0 / 10 } : nil
                        let researchCore: Int64 = mode == "short10" ? 10 * 48_000 : 28 * 48_000
                        var windows: [WindowOutput] = []
                        var segments: [Segment] = []
                        let wall = ProcessInfo.processInfo.systemUptime
                        var planning = 0.0
                        while cursor < last {
                            let candidate = mode == "short10" || researchMinimum != nil
                                ? TranscriptionWindow(coreFrames: cursor..<min(last, cursor + researchCore),
                                    audioFrames: max(0, cursor - 48_000)..<min(last, cursor + researchCore + 48_000))
                                : try #require(planner.candidate)
                            try #require(candidate.audioFrames.count <= 30 * 48_000)
                            file.framePosition = AVAudioFramePosition((clip.start * 16_000).rounded())
                                + candidate.audioFrames.lowerBound / 3
                            let count = Int(candidate.audioFrames.count / 3)
                            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                frameCapacity: AVAudioFrameCount(count)))
                            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
                            try #require(Int(buffer.frameLength) == count)
                            let channel = try #require(buffer.floatChannelData?[0])
                            var pcm = Array(UnsafeBufferPointer(start: channel, count: count)).flatMap { [$0, $0, $0] }
                            let beginPlanning = ProcessInfo.processInfo.systemUptime
                            let selected: TranscriptionWindow
                            if mode == "short10" || researchMinimum != nil {
                                let boundary: Int64
                                if let minimum = researchMinimum, candidate.coreFrames.upperBound < last {
                                    boundary = try TranscriptionChunkPlanner.pauseBoundary(candidate: candidate, pcm: pcm,
                                        minimumQuietHops: minimum) ?? candidate.coreFrames.upperBound
                                } else {
                                    boundary = candidate.coreFrames.upperBound
                                }
                                selected = TranscriptionWindow(coreFrames: candidate.coreFrames.lowerBound..<boundary,
                                    audioFrames: candidate.audioFrames.lowerBound..<min(last, boundary + 48_000))
                            } else {
                                selected = try planner.next(pcm: pcm)
                            }
                            cursor = selected.coreFrames.upperBound
                            planning += ProcessInfo.processInfo.systemUptime - beginPlanning
                            pcm.removeLast(pcm.count - selected.audioFrames.count)
                            let result = try await engine.transcribeWindow(pcm: pcm, sampleRate: 48_000)
                            let start = Double(selected.audioFrames.lowerBound) / 48_000
                            let mapped = result.segments.map { segment in
                                Segment(text: segment.text, start: segment.startSeconds.map { $0 + start },
                                    end: segment.endSeconds.map { $0 + start })
                            }
                            for (raw, segment) in zip(result.segments, mapped) where segment.text != "[BLANK_AUDIO]" {
                                if let a = raw.startSeconds, let b = raw.endSeconds {
                                    if !selected.owns(startSeconds: a, endSeconds: b) { continue }
                                }
                                segments.append(segment)
                            }
                            windows.append(WindowOutput(core: [selected.coreFrames.lowerBound, selected.coreFrames.upperBound],
                                audio: [selected.audioFrames.lowerBound, selected.audioFrames.upperBound],
                                candidate: [candidate.audioFrames.lowerBound, candidate.audioFrames.upperBound], raw: mapped))
                        }
                        #expect(windows.first?.core.first == 0 && windows.last?.core.last == last)
                        #expect(zip(windows, windows.dropFirst()).allSatisfy { $0.core[1] == $1.core[0] })
                        outputs.append(Output(id: clip.id, windows: windows, segments: segments,
                            planning_seconds: planning, wall_seconds: ProcessInfo.processInfo.systemUptime - wall))
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let policyRevision = mode == "pause" ? TranscriptionChunking.pausePreferred.revision
                        : mode == "fixed" ? TranscriptionChunking.fixed.revision
                        : "research-\(mode)-context1-lookback4-rms10ms-cap50dB-relative20dB"
                    try encoder.encode(Evidence(recipe: engine.revision + "/" + policyRevision, mode: mode, clips: outputs))
                        .write(to: root.appendingPathComponent("chunking/outputs-\(weights.rawValue)-\(mode).json"))
                }
            }
        }
        let drained = await pool.snapshot
        #expect(drained.active == 0 && drained.reservedBytes == 0)
    }

    private static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1 << 20), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Manifest: Decodable {
        struct Clip: Decodable {
            let id: String
            let source: String
            let source_sha256: String
            let start: Double
            let end: Double
        }
        let clips: [Clip]
    }
    private struct Segment: Encodable {
        let text: String
        let start: Double?
        let end: Double?
    }
    private struct WindowOutput: Encodable {
        let core: [Int64]
        let audio: [Int64]
        let candidate: [Int64]
        let raw: [Segment]
    }
    private struct Output: Encodable {
        let id: String
        let windows: [WindowOutput]
        let segments: [Segment]
        let planning_seconds: Double
        let wall_seconds: Double
    }
    private struct Evidence: Encodable {
        let recipe: String
        let mode: String
        let clips: [Output]
    }
}
