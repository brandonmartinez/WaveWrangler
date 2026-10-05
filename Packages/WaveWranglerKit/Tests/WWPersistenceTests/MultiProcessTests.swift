import Foundation
import Testing
import WWCore
@testable import WWPersistence

/// Real multi-process evidence using the `wwpersist-probe` executable built alongside the tests:
/// two processes saving the same synthetic file, and real process death (SIGKILL) at each publisher
/// boundary. Local APFS only — **simulated/local, not provider-observed**.
@Suite("Multi-process (real processes)", .serialized)
struct MultiProcessTests {
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
            let barrier = rig.dir.sub("barrier-\(round)")
            let go = barrier.appending(path: "go")
            var running: [(Process, Pipe)] = []
            for writer in ["A", "B"] {
                running.append(try Self.launch(["save", "--file", url.path, "--title", "Process \(writer)", "--recovery", rig.recovery.root.path,
                                                "--ready", barrier.appending(path: "ready-\(writer)").path, "--go", go.path]))
            }
            for writer in ["A", "B"] { _ = waitFor(barrier.appending(path: "ready-\(writer)")) }
            FileManager.default.createFile(atPath: go.path, contents: Data())
            let results = running.map { process, pipe in
                let output = Self.output(pipe)
                process.waitUntilExit()
                return output
            }
            for result in results {
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
                default: other += 1
                }
            }
            guard case let .editable(document, _) = rig.opener.open(url) else { Issue.record("round \(round) unreadable"); continue }
            #expect(results.contains { $0["result"] as? String == "saved" && $0["title"] as? String == document.payload.show.title })
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
        for index in 0..<runs {
            // A kill counts only when the probe wrote the boundary marker right before SIGKILLing itself. Any
            // other termination (e.g. an external SIGKILL under load, #82) is retried with a fresh fixture.
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
                // Invariants hold whatever ended the process.
                switch rig.opener.open(url, key: .show(model.show.id)) {
                case let .editable(document, _):
                    if document.payload != old2, document.payload.show.title != "Killed at \(boundary.rawValue)" { mixed += 1 }
                case .damaged, .unreadable, .refusedNewerFormat, .needsMigration:
                    zeroValid += 1
                }
                let atBoundary = process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL
                    && (try? String(contentsOf: marker, encoding: .utf8)) == boundary.rawValue
                if atBoundary {
                    killed += 1
                    if case let .editable(document, _) = rig.opener.open(url, key: .show(model.show.id)) {
                        if document.payload == old2, document.revision == 2 { old += 1 }
                        else if document.revision == 3 { new += 1 }
                    }
                    break
                }
                attempt += 1
                externalKillsRetried += 1
                if attempt >= 3 {
                    Issue.record("probe did not die at \(boundary.rawValue) after \(attempt) attempts: status \(process.terminationStatus) \(output)")
                    break
                }
            }
        }
        Evidence.record("process kill (SIGKILL) boundary=\(boundary.rawValue) runs=\(runs) killed=\(killed) old=\(old) new=\(new) mixed=\(mixed) zeroValid=\(zeroValid) externalKillsRetried=\(externalKillsRetried) [simulated/local, not provider-observed]")
        #expect(killed == runs && mixed == 0 && zeroValid == 0 && old + new == runs)
    }

    func waitFor(_ url: URL, timeout: Double = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            usleep(2_000)
        }
        return false
    }
}

/// Anchors `Bundle(for:)` to the test bundle, which is built next to the `wwpersist-probe` executable.
private final class ProbeLocator {}
