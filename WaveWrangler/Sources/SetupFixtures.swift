import Foundation
import SwiftUI
import WWEpisodeSetup

/// Synthetic UI-test fixtures (F-MESSY import tree and F-STATES simulated provider states). Selected only
/// by the `WW_SETUP_ENGINE=fixture-states` environment variable; no file is read or written and every
/// state here is labelled "simulated provider state".
@MainActor
enum SetupFixtures {
    /// Debug builds only; Release builds ignore `WW_SETUP_ENGINE` entirely.
    static var isActive: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["WW_SETUP_ENGINE"] == "fixture-states"
        #else
        false
        #endif
    }

    /// In fixture mode the Relink/Grant Access panel is replaced by this synthetic candidate.
    static var relinkCandidateOverride: URL? {
        #if DEBUG
        isActive ? URL(filePath: "/WaveWranglerFixture/ZOOM0001/tr2.wav") : nil
        #else
        nil
        #endif
    }

    /// The shared scripted engine in fixture mode, otherwise nil.
    static func statesEngine() -> InMemorySourceSetupEngine? {
        #if DEBUG
        guard isActive else { return nil }
        if let shared { return shared }
        let engine = makeStatesEngine()
        shared = engine
        return engine
        #else
        return nil
        #endif
    }

    #if DEBUG
    private static var shared: InMemorySourceSetupEngine?

    private static func makeStatesEngine() -> InMemorySourceSetupEngine {
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        func details(_ name: String, _ folder: String?, size: Int64 = 1_210_000_000) -> FileDetails {
            FileDetails(name: name, size: size, created: created, modified: created, kind: "WAV audio", folderName: folder)
        }
        func candidate(_ name: String, _ folder: String?, residency: ResidencyStatus = .local, kind: ImportCandidate.Kind = .recording(typeFromNameOnly: true), already: Bool = false, size: Int64 = 1_210_000_000) -> ImportCandidate {
            ImportCandidate(details: details(name, folder, size: size), kind: kind, alreadyInEpisode: already, residency: residency)
        }
        let scan = ImportScan(candidates: [
            candidate("tr1.wav", "ZOOM0001"),
            candidate("tr2.wav", "ZOOM0001", residency: .cloudOnly),
            candidate("tr3.wav", "ZOOM0001"),
            candidate("ana-zoom.m4a", "Ana", residency: .cloudOnly),
            candidate("tr1.wav", "Backup", size: 900),
            candidate("intro.wav", nil),
            candidate("denied.wav", nil),
            candidate("changed.wav", nil),
            candidate("offline.wav", nil, residency: .cloudOnly),
            candidate("notes.txt", nil, kind: .notRecording),
            candidate("cover.png", nil, kind: .notRecording),
            candidate(".hidden", nil, kind: .hidden),
        ], chosenDisplayName: "Ana Interview", folderCount: 3, fileCount: 12)

        let engine = InMemorySourceSetupEngine(scanResult: scan, pauseSupported: false)
        let ready = SourceStatusSnapshot(location: .known, access: .granted, residency: .local, transfer: .idle, identity: .notChecked, checkedAt: Dictionary(uniqueKeysWithValues: SourceDimension.allCases.map { ($0, created) }))
        func with(_ change: (inout SourceStatusSnapshot) -> Void) -> SourceStatusSnapshot {
            var s = ready
            change(&s)
            return s
        }
        engine.importedStatus = ready
        engine.importedStatusByName = [
            "tr2.wav": with { $0.residency = .cloudOnly; $0.transfer = .downloading(fraction: 0.42) },
            "tr3.wav": with { $0.access = .needsPermission; $0.residency = .cloudOnly },
            "ana-zoom.m4a": with { $0.residency = .cloudOnly; $0.transfer = .downloading(fraction: nil) },
            "intro.wav": with { $0.location = .missing(sameNamedFileAtOriginalLocation: true) },
            "denied.wav": with { $0.access = .denied },
            "changed.wav": with { $0.identity = .changed(differences: "size differs", acceptedByUser: false) },
            "offline.wav": with { $0.residency = .cloudOnly; $0.transfer = .noConnection },
        ]
        engine.candidateDetails = [URL(filePath: "/WaveWranglerFixture/ZOOM0001/tr2.wav"): details("tr2.wav", "ZOOM0001", size: 1_210_000_001)]
        engine.transferOutcome = { action, current in
            var next = current
            switch action {
            case .download, .retry: next.transfer = .queued
            case .pause: next.transfer = .paused
            case .resume: next.transfer = .downloading(fraction: nil)
            case .cancel: next.transfer = .cancelled
            }
            return next
        }
        return engine
    }
    #endif
}

// MARK: - In-app text size (CMD-20)

private struct SetupTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// WaveWrangler's own text scale (1.0–2.0). Hosts pass Settings › Text size; UI tests may pass
    /// `-WWSetupTextScale 2` to exercise 200 %.
    var setupTextScale: CGFloat {
        get { self[SetupTextScaleKey.self] }
        set { self[SetupTextScaleKey.self] = newValue }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.setupTextScale) private var scale
    let style: NSFont.TextStyle
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(.system(size: NSFont.preferredFont(forTextStyle: style).pointSize * scale, weight: weight))
    }
}

extension View {
    func setupFont(_ style: NSFont.TextStyle = .body, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFont(style: style, weight: weight))
    }
}
