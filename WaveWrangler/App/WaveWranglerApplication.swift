import AppKit

/// The app's `NSApplication` (created first in `AppDelegate.main()`, so it is `NSApp`; also the Info.plist
/// principal class).
///
/// #126: every app-modal error presentation ends here, whoever starts it: `NSDocumentController`'s default
/// `presentError(_:)` (File › Open, Finder/`odoc` opens, `XCUIApplication.open`, launch-time reopening)
/// forwards to `NSApp.presentError(_:)`, as do direct callers. Those errors (e.g. the T17 recovery offer and
/// the T20 unknown-newer refusal, shown when a show could not be opened and so has no window) use the opaque
/// `OpaqueErrorPanel` instead of a translucent `NSAlert`. Wording, buttons and recovery are unchanged.
/// The routing decision is `OpaqueErrorPresenter.route(for:window:)` (unit-tested); only a sheet on an
/// on-screen window is left to AppKit.
@objc(WaveWranglerApplication)
final class WaveWranglerApplication: NSApplication {
    override func presentError(_ error: Error) -> Bool {
        let error = MainActor.assumeIsolated { OpaqueErrorPresenter.prepare(error, delegate: delegate, application: self) }
        return presentWindowless(error)
    }

    override func presentError(_ error: Error, modalFor window: NSWindow?, delegate: Any?,
                               didPresent didPresentSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let onScreen = MainActor.assumeIsolated { OpaqueErrorPresenter.route(for: error, window: window.map(OpaqueErrorPresenter.WindowState.init)) == .sheet }
        if let window, onScreen {
            super.presentError(error, modalFor: window, delegate: delegate, didPresent: didPresentSelector, contextInfo: contextInfo)
            return
        }
        let prepared = MainActor.assumeIsolated { OpaqueErrorPresenter.prepare(error, delegate: self.delegate, application: self) }
        let recovered = presentWindowless(prepared)
        MainActor.assumeIsolated {
            OpaqueErrorPresenter.notify(delegate, didPresent: didPresentSelector, didRecover: recovered, contextInfo: contextInfo)
        }
    }

    private func presentWindowless(_ error: Error) -> Bool {
        MainActor.assumeIsolated {
            switch OpaqueErrorPresenter.route(for: error, window: nil) {
            case .opaquePanel: OpaqueErrorPresenter.presentModally(error)
            case .suppressed, .sheet: false
            }
        }
    }
}
