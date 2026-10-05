import AppKit
import Darwin
import OSLog

/// Responsiveness instrumentation (WW-007 / M1-SCALE-001 native).
///
/// Every interval runs from the triggering input event (`NSEvent.timestamp`, so queueing delay before the
/// handler counts) to the end of the main run-loop pass that committed the resulting UI change. A one-shot
/// `beforeWaiting` observer at the highest order runs after AppKit's display cycle and Core Animation's
/// commit, so the measured end is "the change has been handed to the render server". The final frame
/// composition (≤ one display refresh) is not included.
///
/// Intervals are emitted as signposts (subsystem `com.brandonmartinez.wavewrangler`, category
/// `Responsiveness`) whenever signposts are being recorded. In Debug UI-test runs launched with
/// `-WWUITestTimingLog YES` each interval is also logged as one `WWTIMING` line that the harness extracts
/// with `log show`. Otherwise nothing is installed, so normal runs pay only the `isEnabled` checks.
@MainActor
enum Responsiveness {
    struct Token {
        let name: StaticString
        let start: TimeInterval
        let handlerStart: TimeInterval
        let signpost: OSSignpostIntervalState?
    }

    private static let subsystem = "com.brandonmartinez.wavewrangler"
    private static let signposter = OSSignposter(subsystem: subsystem, category: "Responsiveness")
    private static let logger = Logger(subsystem: subsystem, category: "Responsiveness")
    private static var pendingShowOpen: Token?
    private static var libraryReadyReported = false
    private static var showOpenCount = 0

    static let logsTimings: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "WWUITestTimingLog")
        #else
        return false
        #endif
    }()

    private static var isActive: Bool { logsTimings || signposter.isEnabled }

    /// A user interaction whose UI change is made synchronously by the caller.
    static func interaction(_ name: StaticString) {
        guard let token = begin(name) else { return }
        endAfterCommit(token)
    }

    static func begin(_ name: StaticString) -> Token? {
        guard isActive else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        // Use the triggering event's timestamp when it is the event being handled now (same time base).
        var start = now
        if let event = NSApp.currentEvent, event.timestamp > 0, now - event.timestamp < 1 { start = event.timestamp }
        let state = signposter.isEnabled ? signposter.beginInterval(name) : nil
        return Token(name: name, start: start, handlerStart: now, signpost: state)
    }

    static func endAfterCommit(_ token: Token, detail: String = "") {
        afterCommit {
            let end = ProcessInfo.processInfo.systemUptime
            if let state = token.signpost { signposter.endInterval(token.name, state) }
            report("\(token.name)", eventMs: (end - token.start) * 1000, handlerMs: (end - token.handlerStart) * 1000, detail: detail)
        }
    }

    /// Opening a show from the library: from the Open command's event until the show window's first commit.
    static func beginShowOpen() {
        pendingShowOpen = begin("show.open")
    }

    static func showWindowAttached() {
        guard let token = pendingShowOpen else { return }
        pendingShowOpen = nil
        showOpenCount += 1
        // openIndex 1 is the first show opened in this process (cold document code paths); later are warm.
        endAfterCommit(token, detail: "openIndex=\(showOpenCount)")
    }

    /// Process launch → the Library window's first commit with the loaded library (once per process).
    static func libraryReady(entryCount: Int) {
        guard isActive, !libraryReadyReported else { return }
        libraryReadyReported = true
        guard let launched = processStartDate() else { return }
        afterCommit {
            let ms = Date().timeIntervalSince(launched) * 1000
            signposter.emitEvent("library.ready")
            report("launch.libraryReady", eventMs: ms, handlerMs: ms, detail: "entries=\(entryCount)")
        }
    }

    private static func report(_ name: String, eventMs: Double, handlerMs: Double, detail: String) {
        guard logsTimings else { return }
        let main = Thread.isMainThread ? "main" : "background"
        logger.notice("WWTIMING name=\(name, privacy: .public) eventMs=\(eventMs, format: .fixed(precision: 3), privacy: .public) handlerMs=\(handlerMs, format: .fixed(precision: 3), privacy: .public) thread=\(main, privacy: .public) \(detail, privacy: .public)")
    }

    private static func afterCommit(_ body: @escaping @MainActor () -> Void) {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func processStartDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }
}
