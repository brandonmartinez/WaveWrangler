import Foundation

/// App-level `UserDefaults` keys. Persistence and source lanes read these; the Settings window writes them.
///
/// A missing key always means the product default (see `AppPreferences`), so readers never depend on
/// `register(defaults:)` having run first.
public enum PreferenceKey {
    /// Bool. "Save changes automatically". Default **true** (autosave ON).
    public static let autosaveEnabled = "WWAutosaveEnabled"
    /// Bool. "Download sources automatically". Default **true** (source downloads ON).
    public static let downloadSourcesAutomatically = "WWDownloadSourcesAutomatically"
    /// Int percent, one of `TextSize.allowedPercents`. Default **100**.
    public static let textSizePercent = "WWTextSizePercent"
    /// String raw value of the last Settings pane shown.
    public static let settingsLastPane = "WWSettingsLastPane"
}

/// Typed accessor over a `UserDefaults` store with the product defaults applied.
public struct AppPreferences {
    public static let defaultAutosaveEnabled = true
    public static let defaultDownloadSourcesAutomatically = true

    /// Values for `UserDefaults.register(defaults:)`.
    public static var registrationDefaults: [String: Any] {
        [
            PreferenceKey.autosaveEnabled: defaultAutosaveEnabled,
            PreferenceKey.downloadSourcesAutomatically: defaultDownloadSourcesAutomatically,
            PreferenceKey.textSizePercent: TextSize.actual.percent,
        ]
    }

    public let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var autosaveEnabled: Bool {
        get { defaults.object(forKey: PreferenceKey.autosaveEnabled) as? Bool ?? Self.defaultAutosaveEnabled }
        nonmutating set { defaults.set(newValue, forKey: PreferenceKey.autosaveEnabled) }
    }

    public var downloadSourcesAutomatically: Bool {
        get {
            defaults.object(forKey: PreferenceKey.downloadSourcesAutomatically) as? Bool
                ?? Self.defaultDownloadSourcesAutomatically
        }
        nonmutating set { defaults.set(newValue, forKey: PreferenceKey.downloadSourcesAutomatically) }
    }

    public var textSize: TextSize {
        get { TextSize(storedPercent: defaults.object(forKey: PreferenceKey.textSizePercent) as? Int) }
        nonmutating set { defaults.set(newValue.percent, forKey: PreferenceKey.textSizePercent) }
    }
}

/// In-app text size (CMD-20). macOS has no Dynamic Type, so WaveWrangler scales its own text 100%–200%.
public struct TextSize: Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let allowedPercents = [100, 125, 150, 175, 200]
    public static let actual = TextSize(percent: 100)
    public static let all = allowedPercents.map { TextSize(percent: $0) }

    public let percent: Int

    private init(percent: Int) {
        self.percent = percent
    }

    /// Snaps an arbitrary stored value to the nearest allowed step; `nil` or garbage gives 100%.
    public init(storedPercent: Int?) {
        guard let storedPercent else {
            self = .actual
            return
        }
        let nearest = Self.allowedPercents.min { abs($0 - storedPercent) < abs($1 - storedPercent) } ?? 100
        self.init(percent: nearest)
    }

    public var scale: Double { Double(percent) / 100 }
    public var description: String { "\(percent)%" }

    public var bigger: TextSize? {
        Self.allowedPercents.first { $0 > percent }.map { TextSize(percent: $0) }
    }

    public var smaller: TextSize? {
        Self.allowedPercents.last { $0 < percent }.map { TextSize(percent: $0) }
    }

    public static func < (lhs: TextSize, rhs: TextSize) -> Bool { lhs.percent < rhs.percent }

    /// Point size for a base macOS text style size (e.g. body 13 pt) at this scale.
    public func pointSize(forBase base: Double) -> Double { (base * scale).rounded() }
}

/// Settings panes (commands-keyboard §7).
public enum SettingsPane: String, CaseIterable, Sendable {
    case general
    case sources

    public var title: String {
        switch self {
        case .general: "General"
        case .sources: "Sources"
        }
    }

    public var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .sources: "music.mic"
        }
    }
}

/// Exact Settings wording (commands-keyboard §7, states-and-recovery §6).
public enum SettingsWording {
    public static let autosaveTitle = "Save changes automatically"
    public static let autosaveOnCaption =
        "WaveWrangler saves your changes as you work. You can also choose File › Save at any time."
    public static let autosaveOffCaption =
        "Changes are saved only when you choose File › Save (⌘S). WaveWrangler will ask before closing a show with unsaved changes."
    public static let textSizeTitle = "Text size"
    public static let textSizeCaption = "Makes text in WaveWrangler windows larger. Also in View › Text Size."
    public static let downloadTitle = "Download sources automatically"
    public static let downloadOnCaption =
        "WaveWrangler asks your cloud service to download sources that aren't on this Mac so they're ready for later steps. Downloads use disk space."
    public static let downloadOffCaption =
        "WaveWrangler uses only file names and file details. It doesn't open, read, preview or download source files. You can still download one source at a time with Source › Download."

    public static func autosaveCaption(enabled: Bool) -> String {
        enabled ? autosaveOnCaption : autosaveOffCaption
    }

    public static func downloadCaption(enabled: Bool) -> String {
        enabled ? downloadOnCaption : downloadOffCaption
    }

    /// New Show save-panel accessory text (commands-keyboard §2, File › New Show…).
    public static func newShowAccessory(autosaveEnabled: Bool) -> String {
        autosaveEnabled
            ? "Autosave is On. You can change this in Settings."
            : "Autosave is Off. Use File › Save to save changes."
    }
}
