import Darwin
import Foundation

/// Reviewed *relocated* whisper.cpp 1.9.4 / ggml 0.25.3 / libomp 23.1.2 closure.
/// System libraries remain supplied by macOS; there is no approval for an arbitrary CLI or model.
public enum ApprovedWhisperRuntime {
    public static let version = "whisper.cpp 1.9.4; ggml 0.25.3; libomp 23.1.2"

    static let artifacts: [(String, LocalSpeechAssetPin)] = [
        ("bin/whisper-cli", .init(name: "whisper-cli", version: version, sizeBytes: 657_008,
            sha256: "02b6938b489381f6a528a4a8883264ea56eed76c7423b803d21394297b2c4834",
            license: "MIT (whisper.cpp)", source: "https://github.com/ggml-org/whisper.cpp/tree/v1.9.4")),
        ("lib/libwhisper.1.dylib", .init(name: "libwhisper.1.dylib", version: version, sizeBytes: 421_104,
            sha256: "eca0dcf2178dd2f1903ebb502f10903932ee764070cc46d63d14ffd3d1fa024b",
            license: "MIT (whisper.cpp)", source: "https://github.com/ggml-org/whisper.cpp/tree/v1.9.4")),
        ("lib/libggml.0.dylib", .init(name: "libggml.0.dylib", version: version, sizeBytes: 60_896,
            sha256: "02256126859de0555e777e78e6447d8102b0edea4a995f275c3106b3a7c65db8",
            license: "MIT (ggml)", source: "https://github.com/ggml-org/ggml")),
        ("lib/libggml-base.0.dylib", .init(name: "libggml-base.0.dylib", version: version, sizeBytes: 515_952,
            sha256: "84a8ec249803e5da0c28800b0c1699c8a92e1b52e6d2931faecacf35e4901126",
            license: "MIT (ggml)", source: "https://github.com/ggml-org/ggml")),
        ("lib/libomp.dylib", .init(name: "libomp.dylib", version: version, sizeBytes: 721_776,
            sha256: "66ea5824d7cf242e3a00e00480d7ccd60e100bd0665bdb69dabb2326728e38f4",
            license: "MIT (LLVM OpenMP)", source: "https://github.com/llvm/llvm-project/tree/main/openmp")),
        ("libexec/libggml-blas.so", .init(name: "libggml-blas.so", version: version, sizeBytes: 59_216,
            sha256: "99ca2ef77f56896b07351ac8a03e242b28201546a417b2ff6ee5a9c395b252e2",
            license: "MIT (ggml)", source: "https://github.com/ggml-org/ggml")),
        ("libexec/libggml-cpu-apple_m1.so", .init(name: "libggml-cpu-apple_m1.so", version: version, sizeBytes: 601_520,
            sha256: "e01bd177f9889e95efb990203fde896910f78237e96a798e115fa662f025b46a",
            license: "MIT (ggml)", source: "https://github.com/ggml-org/ggml")),
        ("libexec/libggml-cpu-apple_m2_m3.so", .init(name: "libggml-cpu-apple_m2_m3.so", version: version, sizeBytes: 601_520,
            sha256: "827a2d6f05db7bd2fc2e4ee73e767ca54d381a86de5f1a71e2e6f91df12b6c8e",
            license: "MIT (ggml)", source: "https://github.com/ggml-org/ggml")),
        ("libexec/libggml-cpu-apple_m4.so", .init(name: "libggml-cpu-apple_m4.so", version: version, sizeBytes: 601_520,
            sha256: "c2fb157016389e35b61695a3c021675b715c6285b1caefdfa056a1d5e8624905",
            license: "MIT (ggml)", source: "https://github.com/ggml-org/ggml")),
        ("model/ggml-base.en.bin", .whisperBaseEnglish),
    ]

    /// Only an owner-private, local, uniquely staged bundle is eligible. Verify at each launch and
    /// after exit; a name, a checked source binary or a successful exec alone is not an identity pin.
    public static func verify(at root: URL) throws(SpeechAdmissionRefusal) {
        let name = root.lastPathComponent
        guard root.isFileURL, root.deletingLastPathComponent().path == "/private/tmp",
              name.hasPrefix("ww-speech-"), name.utf8.count == 18,
              name.dropFirst(10).utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) })
        else { throw .runtimeNotStaged }
        var state = stat()
        guard lstat(root.path, &state) == 0, state.st_mode & S_IFMT == S_IFDIR,
              state.st_uid == getuid(), state.st_mode & 0o077 == 0,
              state.st_flags & UInt32(SF_DATALESS) == 0
        else { throw .runtimeNotStaged }
        let values: URLResourceValues
        do {
            values = try root.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey])
        } catch { throw .runtimeNotStaged }
        guard values.volumeIsLocal == true, values.isUbiquitousItem != true
        else { throw .runtimeNotStaged }
        try verify(artifacts: artifacts, at: root)
    }

    package static func verify(artifacts: [(String, LocalSpeechAssetPin)], at root: URL)
        throws(SpeechAdmissionRefusal)
    {
        for (path, pin) in artifacts {
            do { try pin.verify(at: root.appendingPathComponent(path)) }
            catch { throw .runtimeDependencyMismatch }
        }
    }
}

/// The sandbox is default-deny: it can read only the staged closure, the one PCM proxy and
/// macOS system runtime, write only its unique scratch, and cannot create network sockets.
public struct OfflineWhisperPlan: Sendable {
    public let selection: PrimarySpeechSelection
    public let executable: URL
    public let arguments: [String]
    private let stage: URL
    private let scratch: URL

    package init(selection: PrimarySpeechSelection, stage: URL, inputWAV: URL, scratch: URL)
        throws(SpeechAdmissionRefusal)
    {
        try ApprovedWhisperRuntime.verify(at: stage)
        let scratchName = scratch.lastPathComponent
        guard scratch.deletingLastPathComponent() == stage, scratchName.hasPrefix("scratch-"),
              UUID(uuidString: String(scratchName.dropFirst(8))) != nil,
              inputWAV.deletingLastPathComponent() == scratch,
              inputWAV.lastPathComponent == "input.wav" else { throw .runtimeNotStaged }
        var info = stat()
        guard lstat(scratch.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw .runtimeNotStaged }
        self.selection = selection
        self.stage = stage
        self.scratch = scratch
        executable = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let outputPrefix = scratch.appendingPathComponent("result")
        arguments = [
            "-p", Self.profile(stage: stage, input: inputWAV, scratch: scratch,
                                executable: stage.appendingPathComponent("bin/whisper-cli")),
            stage.appendingPathComponent("bin/whisper-cli").path,
            "--model", stage.appendingPathComponent("model/ggml-base.en.bin").path,
            "--file", inputWAV.path, "--language", "en", "--threads", "4",
            "--no-gpu", "--output-json", "--output-file", outputPrefix.path, "--no-prints",
        ]
    }

    // Package-scoped for synthetic boundary tests; production plans always use the reviewed catalog.
    package static func profile(stage: URL, input: URL, scratch: URL, executable: URL) -> String {
        func quoted(_ path: String) -> String {
            let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return #""\#(escaped)""#
        }
        func literal(_ path: String) -> String { "(literal \(quoted(path)))" }
        let allowedFiles = ApprovedWhisperRuntime.artifacts.map { literal(stage.appendingPathComponent($0.0).path) }
        let ancestors = [stage.path, stage.appendingPathComponent("bin").path,
                         stage.appendingPathComponent("lib").path,
                         stage.appendingPathComponent("libexec").path,
                         stage.appendingPathComponent("model").path]
        return """
        (version 1)
        (deny default)
        (deny network*)
        (allow process-exec \(literal(executable.path)))
        (allow sysctl-read)
        (allow file-read-metadata \(ancestors.map(literal).joined(separator: " ")))
        (allow file-read*
            (subpath "/System/Library") (subpath "/usr/lib")
            (literal "/") (literal "/private") (literal "/private/tmp")
            \(allowedFiles.joined(separator: " "))
            \(literal(scratch.path)) \(literal(input.path)) \(literal(executable.path)))
        (allow file-read* (subpath \(quoted(scratch.path))))
        (allow file-write* (subpath \(quoted(scratch.path))))
        """
    }

    /// No inherited DYLD, proxy, home or tokenizer environment. No transcript text is logged.
    /// Caller must supply gateway-derived, explicitly selected-primary PCM in private scratch.
    package func run() async throws(SpeechAdmissionRefusal) -> URL {
        try ApprovedWhisperRuntime.verify(at: stage)
        let input = scratch.appendingPathComponent("input.wav")
        let output = scratch.appendingPathComponent("result.json")
        var info = stat()
        guard lstat(input.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { throw .runtimeNotStaged }
        guard lstat(output.path, &info) != 0, errno == ENOENT else { throw .runtimeNotStaged }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["HOME": scratch.path, "TMPDIR": scratch.path, "PATH": "/usr/bin:/bin",
                               "GGML_BACKEND_PATH": stage.appendingPathComponent("libexec/libggml-cpu-apple_m1.so").path]
        let stdout = Pipe()
        let stderr = Pipe()
        for pipe in [stdout, stderr] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }
        process.standardOutput = stdout
        process.standardError = stderr
        let finished = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch { throw .sandboxFailed }
        let watchdog = Task {
            var timedOut = false
            do {
                try await Task.sleep(for: .seconds(120))
                guard process.isRunning else { return false }
                timedOut = true
                process.terminate()
                try await Task.sleep(for: .seconds(5))
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            } catch is CancellationError {
                return timedOut
            } catch {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                return true
            }
            return timedOut
        }
        for await _ in finished { break }
        watchdog.cancel()
        let timedOut = await watchdog.value
        if Task.isCancelled {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            throw .sandboxFailed
        }
        try ApprovedWhisperRuntime.verify(at: stage)
        var outputState = stat()
        guard !timedOut, process.terminationStatus == 0,
              lstat(output.path, &outputState) == 0,
              outputState.st_mode & S_IFMT == S_IFREG, outputState.st_size > 0,
              outputState.st_flags & UInt32(SF_DATALESS) == 0
        else { throw .sandboxFailed }
        return output
    }
}
