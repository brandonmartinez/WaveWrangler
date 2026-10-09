import Foundation
import Speech

@available(macOS 26.0, *)
@main
struct SyntheticSpeechNativeProbe {
    struct Availability: Encodable {
        let availability: String
        let locale: String
        let assetVersion: String
        let assetHash: String
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--availability" else {
                throw ProbeError.invalidArguments
            }
            try emit(await checkAvailability())
        } catch {
            fputs("native availability probe refused\n", stderr)
            exit(1)
        }
    }

    static func checkAvailability() async -> Availability {
        let locale = Locale(identifier: "en_US")
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        let installed = await SpeechTranscriber.installedLocales
        let status: String
        if supported == nil {
            status = "unsupported"
        } else if !installed.contains(where: { $0.identifier == supported?.identifier }) {
            status = "supportedOnly"
        } else {
            let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
            status = await AssetInventory.status(forModules: [transcriber]) == .installed
                ? "installed" : "supportedOnly"
        }
        return Availability(
            availability: status,
            locale: locale.identifier,
            assetVersion: "UNKNOWN-system-managed",
            assetHash: "UNKNOWN-system-managed"
        )
    }

    static func emit<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        guard let line = String(data: data, encoding: .utf8) else {
            throw ProbeError.encodingFailed
        }
        print(line)
    }

    enum ProbeError: Error {
        case invalidArguments
        case encodingFailed
    }
}
