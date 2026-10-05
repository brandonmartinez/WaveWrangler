import AppKit

/// The app's `NSApplication` (created first in `AppDelegate.main()`, so it is `NSApp`; also the Info.plist
/// principal class).
///
/// #126: every app-modal error presentation ends here, whoever starts it: `NSDocumentController`'s default
/// `presentError(_:)` (File › Open, Finder/`odoc` opens, `XCUIApplication.open`, launch-time reopening)
/// forwards to `NSApp.presentError(_:)`, as do direct callers. Those errors (e.g. the T17 recovery offer and
/// the T20 unknown-newer refusal, shown when a show could not be opened and so has no window) use the opaque
/// `OpaqueErrorPanel` instead of a translucent `NSAlert`. Wording, buttons and recovery are unchanged.
/// Presentation as a sheet on a visible window is left to AppKit.
@objc(WaveWranglerApplication)
final class WaveWranglerApplication: NSApplication {
    override func presentError(_ error: Error) -> Bool {
        let error = willPresent(error)
        guard !Self.isUserCancelled(error) else { return false }
        return MainActor.assumeIsolated { OpaqueErrorPresenter.presentModally(error) }
    }

    /// With no visible window there is nothing to attach a sheet to; present app-modally on the opaque panel
    /// and report to the delegate as AppKit would.
    override func presentError(_ error: Error, modalFor window: NSWindow?, delegate: Any?,
                               didPresent didPresentSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        if let window, window.isVisible {
            super.presentError(error, modalFor: window, delegate: delegate, didPresent: didPresentSelector, contextInfo: contextInfo)
            return
        }
        let error = willPresent(error)
        let recovered = Self.isUserCancelled(error) ? false : MainActor.assumeIsolated { OpaqueErrorPresenter.presentModally(error) }
        OpaqueErrorPresenter.notify(delegate, didPresent: didPresentSelector, didRecover: recovered, contextInfo: contextInfo)
    }

    private func willPresent(_ error: Error) -> Error {
        guard let delegate, delegate.responds(to: #selector(NSApplicationDelegate.application(_:willPresentError:))) else { return error }
        return delegate.application?(self, willPresentError: error) ?? error
    }

    private static func isUserCancelled(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError
    }
}
