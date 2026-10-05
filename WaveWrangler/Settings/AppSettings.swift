import AppKit
import Observation
import SwiftUI
import WWOrganizer

/// Live, observable view of the app preferences. Writes go straight to `UserDefaults` under the
/// documented `PreferenceKey`s, which the persistence and source lanes read. Settings changes are not
/// undoable (commands-keyboard §3).
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private var observer: NSObjectProtocol?

    var autosaveEnabled: Bool {
        didSet { if preferences.autosaveEnabled != autosaveEnabled { preferences.autosaveEnabled = autosaveEnabled } }
    }

    var downloadSourcesAutomatically: Bool {
        didSet {
            if preferences.downloadSourcesAutomatically != downloadSourcesAutomatically {
                preferences.downloadSourcesAutomatically = downloadSourcesAutomatically
            }
        }
    }

    var textSize: TextSize {
        didSet { if preferences.textSize != textSize { preferences.textSize = textSize } }
    }

    init(defaults: UserDefaults = .standard) {
        preferences = AppPreferences(defaults: defaults)
        autosaveEnabled = preferences.autosaveEnabled
        downloadSourcesAutomatically = preferences.downloadSourcesAutomatically
        textSize = preferences.textSize
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        if autosaveEnabled != preferences.autosaveEnabled { autosaveEnabled = preferences.autosaveEnabled }
        if downloadSourcesAutomatically != preferences.downloadSourcesAutomatically {
            downloadSourcesAutomatically = preferences.downloadSourcesAutomatically
        }
        if textSize != preferences.textSize { textSize = preferences.textSize }
    }

    func makeTextBigger() { if let next = textSize.bigger { textSize = next } }
    func makeTextSmaller() { if let next = textSize.smaller { textSize = next } }
    func resetTextSize() { textSize = .actual }
}

// MARK: - In-app text size (CMD-20)

extension EnvironmentValues {
    @Entry var wwTextSize: TextSize = .actual
}

/// macOS text styles' base point sizes, scaled by the in-app text size.
enum WWTextStyle {
    case largeTitle, title, title2, title3, headline, body, callout, subheadline, footnote, caption

    var baseSize: Double {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption: 10
        }
    }

    var weight: Font.Weight {
        switch self {
        case .headline, .title, .title2, .title3, .largeTitle: .semibold
        default: .regular
        }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.wwTextSize) private var textSize
    let style: WWTextStyle

    func body(content: Content) -> some View {
        content.font(.system(size: textSize.pointSize(forBase: style.baseSize), weight: style.weight))
    }
}

/// Applies the user's in-app text size to a window's root view, plus the matching control size so
/// controls stay at least the default hit size and grow with text.
private struct TextScaleRoot: ViewModifier {
    @Environment(\.wwTextSize) private var textSize

    func body(content: Content) -> some View {
        content
            .font(.system(size: textSize.pointSize(forBase: WWTextStyle.body.baseSize)))
            .controlSize(textSize.percent >= 150 ? .large : .regular)
    }
}

private struct AppEnvironmentRoot: ViewModifier {
    let settings: AppSettings

    func body(content: Content) -> some View {
        content
            .modifier(TextScaleRoot())
            .environment(\.wwTextSize, settings.textSize)
            .environment(settings)
    }
}

extension View {
    func wwFont(_ style: WWTextStyle) -> some View {
        modifier(ScaledFont(style: style))
    }

    /// Root modifier for every WaveWrangler window: text size and shared settings.
    func wwAppEnvironment(_ settings: AppSettings = .shared) -> some View {
        modifier(AppEnvironmentRoot(settings: settings))
    }
}

/// Reduce Motion: honour the system setting or the `-WWForceReduceMotion YES` test override (C05).
enum MotionPolicy {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || UserDefaults.standard.bool(forKey: "WWForceReduceMotion")
    }

    /// `nil` (no animation) when Reduce Motion is on.
    static func animation(_ animation: Animation = .default) -> Animation? {
        reduceMotion ? nil : animation
    }
}
