import Darwin
import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// Real multi-process evidence using the `wwpersist-probe` executable built alongside the tests:
/// two processes saving the same synthetic file, and real process death (SIGKILL) at each publisher
/// boundary. Local APFS only — **simulated/local, not provider-observed**.
@Suite("Multi-process (real processes)", .serialized)
struct MultiProcessTests {
    struct GatedProbe {
        let writer: String
        let process: Process
        let output: Pipe
        let readiness: Pipe
        let release: Pipe

        func waitUntilReady(timeoutMilliseconds: Int32 = 30_000) throws {
            var descriptor = pollfd(
                fd: readiness.fileHandleForReading.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            var result: Int32
            repeat {
                result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            } while result < 0 && errno == EINTR
            guard result > 0, descriptor.revents & Int16(POLLIN) != 0 else {
                let termination: String
                if process.isRunning {
                    termination = "still running"
                } else {
                    process.waitUntilExit()
                    termination = "\(process.terminationReason.rawValue)/\(process.terminationStatus)"
                }
                throw CocoaError(.fileReadUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "writer \(writer) did not reach the save gate; poll=\(result) events=\(descriptor.revents) termination=\(termination)",
                ])
            }
            let marker = readiness.fileHandleForReading.readData(ofLength: 1)
            guard marker == Data([0x52]) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [
                    NSLocalizedDescriptionKey: "writer \(writer) emitted an invalid save-gate marker",
                ])
            }
        }

        func releaseToSave() throws {
            try release.fileHandleForWriting.write(contentsOf: Data([0x47]))
            try release.fileHandleForWriting.close()
        }

        func finish() -> [String: Any] {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [
                "result": "noOutput",
                "rawOutput": String(decoding: data, as: UTF8.self),
                "terminationReason": process.terminationReason.rawValue,
                "terminationStatus": process.terminationStatus,
            ]
        }

        func cancelIfRunning() {
            try? release.fileHandleForWriting.close()
            guard process.isRunning else { return }
            process.terminate()
            process.waitUntilExit()
        }
    }

    static func probeURL() throws -> URL {
        var candidates: [URL] = [Bundle(for: ProbeLocator.self).bundleURL.deletingLastPathComponent()]
        candidates += Bundle.allBundles.map { $0.bundleURL.deletingLastPathComponent() }
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
        for directory in candidates {
            let url = directory.appending(path: "wwpersist-probe")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "wwpersist-probe not found next to the test bundle"])
    }

    static func launch(_ arguments: [String]) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = try probeURL()
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, pipe)
    }

    static func launchGated(writer: String, _ arguments: [String]) throws -> GatedProbe {
        let process = Process()
        process.executableURL = try probeURL()
        process.arguments = arguments + ["--gate-stdin", "1"]
        let output = Pipe()
        let readiness = Pipe()
        let release = Pipe()
        process.standardOutput = output
        process.standardError = readiness
        process.standardInput = release
        try process.run()
        return GatedProbe(writer: writer, process: process, output: output, readiness: readiness, release: release)
    }

    static func output(_ pipe: Pipe) -> [String: Any] {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test func twoProcessesSavingTheSameFileConflictAndPreserveBoth() throws {
        let rig = Rig(label: "twoproc")
        let rounds = 20
        var saved = 0, conflicts = 0, preserved = 0, other = 0
        for round in 0..<rounds {
            let model = Fixtures.show(seed: 5_000 + UInt64(round))
            let url = rig.url("Shared-\(round).wwshow")
            _ = try rig.publisher.publish(model, revision: 1, key: .show(model.show.id), to: url, target: .newLocation)
            var running: [GatedProbe] = []
            defer { for probe in running { probe.cancelIfRunning() } }
            for writer in ["A", "B"] {
                running.append(try Self.launchGated(writer: writer, [
                    "save", "--file", url.path, "--title", "Process \(writer)", "--recovery", rig.recovery.root.path,
                ]))
            }
            for probe in running { try probe.waitUntilReady() }
            for probe in running { try probe.releaseToSave() }
            let results = running.map { ($0.writer, $0.finish()) }
            for (writer, result) in results {
                switch result["result"] as? String {
                case "saved": saved += 1
                case "conflict":
                    conflicts += 1
                    if let path = result["preservedCandidate"] as? String, !path.isEmpty,
                       let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
                       let decoded = try? JSONEnvelopeCoder<ShowDocumentModel>.show.decode(bytes),
                       decoded.payload.show.title == result["title"] as? String {
                        preserved += 1
                    }
                default:
                    other += 1
                    Issue.record("round \(round) writer \(writer) unexpected probe result \(result)")
                }
            }
            guard case let .editable(document, _) = rig.opener.open(url) else { Issue.record("round \(round) unreadable"); continue }
            #expect(results.contains { $0.1["result"] as? String == "saved" && $0.1["title"] as? String == document.payload.show.title })
        }
        Evidence.record("two real processes, same file (NSFileCoordinator across processes) rounds=\(rounds) saved=\(saved) conflicts=\(conflicts) conflictCandidatesPreserved=\(preserved) other=\(other) [simulated/local, not provider-observed]")
        #expect(saved == rounds && conflicts == rounds && preserved == rounds && other == 0)
    }

    /// Real process death at each publisher boundary (M1-DUR-021-style owned-subprocess kill).
    @Test(arguments: [PublicationBoundary.candidateValidated, .priorRetained, .baseChecked, .stagedFlushed, .published, .readBackVerified])
    func processKillAtBoundary(_ boundary: PublicationBoundary) throws {
        let rig = Rig(label: "kill")
        let runs = 100
        var killed = 0, old = 0, new = 0, mixed = 0, zeroValid = 0
        var externalKillsRetried = 0
        let newTitle = "Killed at \(boundary.rawValue)"
        for index in 0..<runs {
            // The probe writes and fsyncs the boundary name to `marker` immediately before SIGKILLing itself. Only
            // the exact external-kill signature seen in #82 (SIGKILL with no marker, i.e. killed from outside before
            // the boundary) is retried with a fresh fixture; any other termination fails the case immediately.
            var attempt = 0
            while true {
                let model = Fixtures.show(seed: 9_000 + UInt64(index) + UInt64(attempt) * 100_000)
                let url = rig.url("Kill-\(index)-\(attempt).wwshow")
                let marker = rig.dir.url.appending(path: "marker-\(index)-\(attempt)")
                let (old2, _) = try rig.seedTwoRevisions(model, at: url)
                let (process, pipe) = try Self.launch(["kill-at", "--file", url.path, "--boundary", boundary.rawValue,
                                                       "--recovery", rig.recovery.root.path, "--marker", marker.path])
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                // Strict classification on every attempt: old = revision 2 exactly as seeded; new = the probe's
                // edit at revision 3; anything else readable is mixed. Invariants hold whatever ended the process.
                var outcome: String?
                switch rig.opener.open(url, key: .show(model.show.id)) {
                case let .editable(document, _):
                    if document.payload == old2, document.revision == 2 { outcome = "old" }
                    else if document.payload.show.title == newTitle, document.revision == 3 { outcome = "new" }
                    else { mixed += 1 }
                case .damaged, .unreadable, .refusedNewerFormat, .needsMigration:
                    zeroValid += 1
                }
                let sigkilled = process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
                let markerText = try? String(contentsOf: marker, encoding: .utf8)
                if sigkilled, markerText == boundary.rawValue {
                    killed += 1
                    if outcome == "old" { old += 1 } else if outcome == "new" { new += 1 }
                    break
                }
                guard sigkilled, markerText == nil else {
                    Issue.record("probe ended without reaching \(boundary.rawValue): reason \(process.terminationReason.rawValue) status \(process.terminationStatus) marker \(markerText ?? "none") \(output)")
                    break
                }
                externalKillsRetried += 1
                attempt += 1
                if attempt >= 3 {
                    Issue.record("probe SIGKILLed from outside before \(boundary.rawValue) on \(attempt) consecutive attempts")
                    break
                }
            }
        }
        Evidence.record("process kill (SIGKILL) boundary=\(boundary.rawValue) runs=\(runs) killed=\(killed) old=\(old) new=\(new) mixed=\(mixed) zeroValid=\(zeroValid) externalKillsRetried=\(externalKillsRetried) [simulated/local, not provider-observed]")
        // Retries are surfaced and bounded: more than a handful per 100 means the host, not the code, needs a look.
        #expect(externalKillsRetried <= 3, "external SIGKILLs before the boundary: \(externalKillsRetried)")
        #expect(killed == runs && mixed == 0 && zeroValid == 0 && old + new == runs)
    }

}

/// Anchors `Bundle(for:)` to the test bundle, which is built next to the `wwpersist-probe` executable.
private final class ProbeLocator {}
