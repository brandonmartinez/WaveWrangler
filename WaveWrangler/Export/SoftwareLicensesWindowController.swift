import AppKit
import SwiftUI
import WWExport

enum SoftwareLicenses {
    static func notices(appBundle: Bundle = .main) throws -> [ExportLicensing.Notice] {
        var notices = try ExportLicensing.notices()
        guard let url = appBundle.url(forResource: "WhisperCPULICENSE", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile,
                userInfo: [NSLocalizedDescriptionKey: "The bundled Whisper CPU license could not be found."])
        }
        notices.append(.init(id: "whisper", title: "Whisper CPU - MIT notices",
                             text: try String(contentsOf: url, encoding: .utf8)))
        return notices
    }
}

@MainActor
final class SoftwareLicensesWindowController: NSWindowController {
    private static var instance: SoftwareLicensesWindowController?

    static func show() {
        let controller = instance ?? SoftwareLicensesWindowController()
        instance = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let hosting = NSHostingController(rootView: SoftwareLicensesView())
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Software Licenses"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(.init(width: 720, height: 540))
        window.contentMinSize = .init(width: 540, height: 360)
        window.tabbingMode = .disallowed
        window.setAccessibilityIdentifier("ww.licenses.window")
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct SoftwareLicensesView: View {
    @State private var notices: [ExportLicensing.Notice] = []
    @State private var selection: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("WaveWrangler & Third-Party Software").font(.headline).padding()
            Divider()
            if let error {
                ContentUnavailableView("Software licenses unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                HSplitView {
                    List(notices, selection: $selection) { notice in
                        Text(notice.title).tag(notice.id)
                    }.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                        .accessibilityIdentifier("ww.licenses.list")
                    ScrollView {
                        Text(notices.first { $0.id == selection }?.text ?? "Select a license.")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                            .accessibilityIdentifier("ww.licenses.text")
                            .id(selection)
                    }.frame(minWidth: 300)
                }
            }
        }
        .task {
            do {
                notices = try SoftwareLicenses.notices()
                selection = notices.first?.id
            } catch { self.error = error.localizedDescription }
        }
        .frame(minWidth: 540, minHeight: 360)
    }
}
