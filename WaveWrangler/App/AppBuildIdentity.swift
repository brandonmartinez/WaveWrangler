import Foundation

struct AppBuildIdentity: Sendable, Equatable {
    let version: String?
    let buildNumber: String?

    static let current: AppBuildIdentity = {
        let identity = AppBuildIdentity(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
        if identity.version == nil || identity.buildNumber == nil {
            NSLog("WaveWrangler version/build metadata is missing from the running app bundle.")
        }
        return identity
    }()

    init(version: String?, buildNumber: String?) {
        self.version = Self.nonempty(version)
        self.buildNumber = Self.nonempty(buildNumber)
    }

    var label: String {
        "WaveWrangler \(version ?? "version unavailable") (build \(buildNumber ?? "unavailable"))"
    }

    func subtitle(context: String? = nil) -> String {
        guard let context, !context.isEmpty else { return label }
        return "\(context) | \(label)"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
