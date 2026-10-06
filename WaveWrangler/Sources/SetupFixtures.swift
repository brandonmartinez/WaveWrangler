import Foundation
import SwiftUI
import WWCore
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
        engine.afterPerform = { action, id in
            Task { @MainActor in SimulatedNetwork.performed(action, on: id) }
        }
        engine.transferOutcome = { action, current in
            var next = current
            switch action {
            case .download, .retry: next.transfer = .downloading(fraction: nil)  // as WWSources' `.requested`
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

#if DEBUG
/// F-OFFLINE sources (simulated, T29/T30): network loss and reconnect for the fixture engine. Driven only by
/// the DEBUG Source › "Simulate Network Offline/Reconnect" items, which exist only in fixture mode; until
/// one is used the fixture's states stay static (other tests are unaffected). Every state is a simulated
/// provider state; nothing touches the file system or the network.
@MainActor
enum SimulatedNetwork {
    private(set) static var engaged = false
    private(set) static var online = true
    /// Time per simulated transfer step (Downloading… → Ready).
    /// Long enough for UI tests to observe "Downloading…" before "Ready".
    static let step: Duration = .milliseconds(2500)

    /// The network drops: every active download fails with "No connection", in one update.
    static func goOffline() {
        guard let engine = SetupFixtures.statesEngine() else { return }
        engaged = true
        online = false
        engine.setStatuses(engine.allStatuses.filter { $0.value.transfer.isActive }.mapValues { status in
            var next = status
            next.transfer = .noConnection
            return next
        })
    }

    /// The network returns. With downloads on, "No connection" downloads are requeued automatically (the
    /// fixture stand-in for WWSources' `ReconnectRetry`, which is unit-tested on the real engine); with
    /// downloads off nothing is requested.
    static func reconnect() {
        guard let engine = SetupFixtures.statesEngine() else { return }
        engaged = true
        online = true
        guard AppSettingsDownloadPreference.shared.downloadsAutomatically else { return }
        transfer(Set(engine.allStatuses.filter { $0.value.transfer == .noConnection }.keys), in: engine)
    }

    /// Download/Retry once the simulation is engaged: proceeds when online, fails "No connection" offline.
    static func performed(_ action: TransferAction, on id: SourceID) {
        guard engaged, action == .download || action == .retry, let engine = SetupFixtures.statesEngine() else { return }
        transfer([id], in: engine)
    }

    /// Downloading… → Ready (or → No connection while offline), as the real engine reports a request
    /// (`.requested` is "Downloading…"; it never shows "Waiting"). One batched update per step, so the
    /// attention count changes once and no row is announced on its own.
    private static func transfer(_ ids: Set<SourceID>, in engine: InMemorySourceSetupEngine) {
        guard !ids.isEmpty else { return }
        apply(ids, engine, from: [.noConnection, .downloading(fraction: nil), .cancelled]) { $0.transfer = .downloading(fraction: nil) }
        Task { @MainActor in
            try? await Task.sleep(for: step)
            guard online else { return apply(ids, engine, from: [.downloading(fraction: nil)]) { $0.transfer = .noConnection } }
            apply(ids, engine, from: [.downloading(fraction: nil)]) {
                $0.transfer = .idle
                $0.residency = .local
            }
        }
    }

    /// Changes only sources still in one of `states` (a cancel or another action meanwhile wins).
    private static func apply(_ ids: Set<SourceID>, _ engine: InMemorySourceSetupEngine, from states: [TransferStatus], _ change: (inout SourceStatusSnapshot) -> Void) {
        var updates: [SourceID: SourceStatusSnapshot] = [:]
        for (id, status) in engine.allStatuses where ids.contains(id) && states.contains(status.transfer) {
            var next = status
            change(&next)
            updates[id] = next
        }
        engine.setStatuses(updates)
    }
}
#endif

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
