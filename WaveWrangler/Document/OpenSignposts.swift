import Foundation
import OSLog

/// os_signpost intervals for opening a show (M1-SCALE-001 cold-open attribution).
///
/// Subsystem `com.brandonmartinez.wavewrangler`, category `ShowOpen`. Intervals are recorded only while
/// signposts are being collected (Instruments, `xctrace`, `log stream --signpost`). In Debug runs launched
/// with `-WWUITestTimingLog YES` (the acceptance lane's timing flag) each interval is also logged as one
/// `WWOPEN` line for `log show` extraction. Otherwise each call costs only the `isActive` check.
///
/// Stages, in order, for one open:
/// - `library.openShow`: the library's open request until NSDocumentController returns the document.
/// - `document.init`, `document.read` (with `document.decode`), `document.makeWindowControllers`.
/// - `window.firstCommit`: from showing the window until the end of the run-loop pass that committed it.
/// - `window.attach`: the show window's post-attach work (toolbar bridging, chrome, library bookkeeping).
/// - `document.deferred`: work moved after the first frame (provider-version inspection, the C2b offer scan).
enum OpenSignposts {
    struct Interval {
        let name: StaticString
        let start: TimeInterval
        let state: OSSignpostIntervalState?
    }

    static let subsystem = "com.brandonmartinez.wavewrangler"
    private static let signposter = OSSignposter(subsystem: subsystem, category: "ShowOpen")
    private static let logger = Logger(subsystem: subsystem, category: "ShowOpen")

    static let logsTimings: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "WWUITestTimingLog")
        #else
        return false
        #endif
    }()

    static var isActive: Bool { logsTimings || signposter.isEnabled }

    static func begin(_ name: StaticString) -> Interval? {
        guard isActive else { return nil }
        let state = signposter.isEnabled ? signposter.beginInterval(name) : nil
        return Interval(name: name, start: ProcessInfo.processInfo.systemUptime, state: state)
    }

    static func end(_ interval: Interval?, _ detail: String = "") {
        guard let interval else { return }
        if let state = interval.state { signposter.endInterval(interval.name, state) }
        guard logsTimings else { return }
        let ms = (ProcessInfo.processInfo.systemUptime - interval.start) * 1000
        logger.notice("WWOPEN stage=\("\(interval.name)", privacy: .public) ms=\(ms, format: .fixed(precision: 3), privacy: .public) \(detail, privacy: .public)")
    }

    @discardableResult
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = begin(name)
        defer { end(interval) }
        return try body()
    }

    /// Ends `interval` at the end of the current main run-loop pass (after AppKit's display cycle and Core
    /// Animation's commit), the same end point the acceptance lane's `Responsiveness` uses.
    @MainActor
    static func endAfterCommit(_ interval: Interval?, _ detail: String = "") {
        guard let interval else { return }
        afterCommit { end(interval, detail) }
    }

    /// Runs `body` once, at the end of the current main run-loop pass (after the display cycle and Core
    /// Animation's commit). Use `afterFirstFrame` to run work on the following turn instead.
    @MainActor
    static func afterCommit(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Runs `body` on the main queue turn after the current pass has committed its frame, so it never delays
    /// that frame. The work still runs (it is deferred, not dropped).
    @MainActor
    static func afterFirstFrame(_ body: @escaping @MainActor () -> Void) {
        afterCommit { DispatchQueue.main.async { MainActor.assumeIsolated { body() } } }
    }
}
