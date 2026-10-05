import AppKit
import OSLog
import WWOrganizer

#if DEBUG
/// Local-only measurement of Library sidebar selection (WW-007 / #106). Debug builds only; never in Release.
///
/// `-WWMeasureSidebarSwitches N` (with a library fixture such as `-WWUITestLibraryFixture lib100`): once the
/// library has loaded, the Library window is sized to `-WWMeasureWindowSize WxH` (content size; default
/// 1000x600, the window's normal size), then the sidebar selection is changed N times through the same state
/// path the List selection binding uses for arrow keys, walking down and up the 8 rows like the SCALE-001
/// harness. Each change is measured from the change until the entry list shows the new rows (end of the first
/// committed run-loop pass with every visible row realized), logged as a `WWBENCH` line, summarised, and the
/// app then quits.
///
/// Read results with:
/// `log show --last 10m --predicate 'subsystem == "com.brandonmartinez.wavewrangler" AND category == "Benchmark"'`
@MainActor
enum SidebarSwitchBenchmark {
    private static let logger = Logger(subsystem: "com.brandonmartinez.wavewrangler", category: "Benchmark")

    static func startIfRequested(state: LibraryWindowState) {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: "WWMeasureSidebarSwitches")
        guard count > 0 else { return }
        let size = parseSize(defaults.string(forKey: "WWMeasureWindowSize")) ?? NSSize(width: 1000, height: 600)
        Task { @MainActor in
            // Wait for the library to load and the window to settle.
            while !state.store.isLoaded || state.store.library.entries.isEmpty {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let window = state.window {
                window.setContentSize(size)
                LaunchFixtures.placeForTesting(window)
            }
            try? await Task.sleep(for: .seconds(1))
            await run(count: count, state: state, size: size)
            NSApp.terminate(nil)
        }
    }

    private static func run(count: Int, state: LibraryWindowState, size: NSSize) async {
        let items: [LibrarySidebarItem] = [.shows, .recent, .unavailable] + state.store.library.collections.map { .collection($0.id) }
        var position = items.firstIndex(of: state.sidebarSelection ?? .shows) ?? 0
        var direction = 1
        var all: [Double] = []
        var toShows: [Double] = []
        for step in 0..<count {
            if !items.indices.contains(position + direction) { direction = -direction }
            position += direction
            let item = items[position]
            let expected = state.store.rows(for: item).count
            let (ms, passes) = await measure(expectedRows: expected, window: state.window) { state.sidebarSelection = item }
            all.append(ms)
            if item == .shows { toShows.append(ms) }
            let realized = realizedRows(in: state.window)
            logger.notice("WWBENCH step=\(step, privacy: .public) item=\(name(item), privacy: .public) rows=\(state.store.rows(for: item).count, privacy: .public) passes=\(passes, privacy: .public) realized=\(realized.realized, privacy: .public) visible=\(realized.visible, privacy: .public) ms=\(ms, format: .fixed(precision: 3), privacy: .public)")
            try? await Task.sleep(for: .milliseconds(60))
        }
        let window = state.window?.contentLayoutRect.size ?? size
        logger.notice("WWBENCH summary window=\(Int(window.width), privacy: .public)x\(Int(window.height), privacy: .public) all n=\(all.count, privacy: .public) p50=\(percentile(all, 0.5), format: .fixed(precision: 1), privacy: .public) p95=\(percentile(all, 0.95), format: .fixed(precision: 1), privacy: .public) max=\(all.max() ?? 0, format: .fixed(precision: 1), privacy: .public) toShows n=\(toShows.count, privacy: .public) p50=\(percentile(toShows, 0.5), format: .fixed(precision: 1), privacy: .public) p95=\(percentile(toShows, 0.95), format: .fixed(precision: 1), privacy: .public) max=\(toShows.max() ?? 0, format: .fixed(precision: 1), privacy: .public)")
    }

    /// From the change to the end of the first run-loop pass (after Core Animation's commit) at which the entry
    /// list shows the new content: the table has the new row count and a row view for every visible row. A pass
    /// that commits before the rows are realized doesn't count as ready (no undercounting).
    private static func measure(expectedRows: Int, window: NSWindow?, _ change: () -> Void) async -> (ms: Double, passes: Int) {
        let start = ProcessInfo.processInfo.systemUptime
        change()
        return await withCheckedContinuation { continuation in
            var passes = 0
            var observer: CFRunLoopObserver?
            observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
                passes += 1
                let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
                guard MainActor.assumeIsolated({ isReady(expectedRows: expectedRows, window: window) }) || elapsed > 3_000 else { return }
                if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
                continuation.resume(returning: (elapsed, passes))
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private static func isReady(expectedRows: Int, window: NSWindow?) -> Bool {
        guard expectedRows > 0 else { return entryTable(in: window) == nil }
        guard let table = entryTable(in: window), table.numberOfRows == expectedRows else { return false }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return false }
        return (visible.location..<(visible.location + visible.length)).allSatisfy { table.rowView(atRow: $0, makeIfNecessary: false) != nil }
    }

    private static func entryTable(in window: NSWindow?) -> NSTableView? {
        func tables(_ view: NSView) -> [NSTableView] {
            ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables)
        }
        guard let content = window?.contentView else { return nil }
        // The sidebar is a one-column outline; the entry list has five columns.
        return tables(content).first { $0.numberOfColumns > 1 }
    }

    /// Row views the entry table holds after the switch vs. rows in its visible rect (realized-rows hypothesis).
    private static func realizedRows(in window: NSWindow?) -> (realized: Int, visible: Int) {
        guard let table = entryTable(in: window) else { return (-1, -1) }
        var realized = 0
        table.enumerateAvailableRowViews { _, _ in realized += 1 }
        return (realized, table.rows(in: table.visibleRect).length)
    }

    private static func name(_ item: LibrarySidebarItem) -> String {
        switch item {
        case .shows: "shows"
        case .recent: "recent"
        case .unavailable: "unavailable"
        case .collection: "collection"
        }
    }

    private static func parseSize(_ text: String?) -> NSSize? {
        guard let parts = text?.split(separator: "x"), parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return NSSize(width: w, height: h)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded(.up)))]
    }
}
#endif
