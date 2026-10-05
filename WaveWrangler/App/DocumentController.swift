import AppKit

/// The app's shared document controller (created first in `AppDelegate.main()`, so it becomes
/// `NSDocumentController.shared`).
///
/// #126: errors it presents app-modally, i.e. without a window (a show that could not be opened: the T17
/// recovery offer, the T20 unknown-newer refusal, other open failures), use `OpaqueErrorPresenter` instead of
/// a translucent `NSAlert`. Wording, buttons and recovery are unchanged (see `OpaqueErrorPanel`).
/// Window-modal (sheet) presentation is left to AppKit.
final class DocumentController: NSDocumentController {
    override func presentError(_ error: Error) -> Bool {
        let error = willPresentError(error)
        if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSUserCancelledError { return false }
        return MainActor.assumeIsolated { OpaqueErrorPresenter.presentModally(error) }
    }
}
