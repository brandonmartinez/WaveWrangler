import AppKit
import SwiftUI
import WWOrganizer

/// Settings window (commands-keyboard §7): non-customisable toolbar with General and Sources panes, title
/// matching the pane, minimize/zoom dimmed, reopens on the last pane. Changes apply immediately.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var instance: SettingsWindowController?
    private let tabs = SettingsTabViewController()

    static func show(pane: SettingsPane? = nil) {
        let controller = instance ?? SettingsWindowController()
        instance = controller
        if let pane { controller.tabs.select(pane) }
        controller.showWindow(nil)
        if let window = controller.window { LaunchFixtures.placeForTesting(window) }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.setAccessibilityIdentifier("ww.settings.window")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        tabs.select(SettingsPane(rawValue: UserDefaults.standard.string(forKey: PreferenceKey.settingsLastPane) ?? "") ?? .general)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class SettingsTabViewController: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = true
        for pane in SettingsPane.allCases {
            let root: AnyView = switch pane {
            case .general: AnyView(GeneralSettingsView().wwAppEnvironment())
            case .sources: AnyView(SourcesSettingsView().wwAppEnvironment())
            }
            let hosting = NSHostingController(rootView: root)
            hosting.sizingOptions = .preferredContentSize
            hosting.title = pane.title
            hosting.view.setAccessibilityLabel("\(pane.title) settings")
            let item = NSTabViewItem(viewController: hosting)
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: pane.title)
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func select(_ pane: SettingsPane) {
        if let index = tabViewItems.firstIndex(where: { $0.identifier as? String == pane.rawValue }) {
            selectedTabViewItemIndex = index
        }
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let id = tabViewItem?.identifier as? String {
            UserDefaults.standard.set(id, forKey: PreferenceKey.settingsLastPane)
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                let connected = AutosavePolicyConnection.isConnected
                let effective = AutosavePolicyConnection.effectiveAutosaveEnabled
                Toggle(SettingsWording.autosaveTitle, isOn: Binding(
                    get: { effective },
                    set: { AutosavePolicyConnection.setEnabled($0) }
                ))
                    .toggleStyle(.switch)
                    .disabled(!connected)
                    .help(SettingsWording.autosaveCaption(enabled: effective))
                    .accessibilityIdentifier("ww.settings.autosave")
                caption(SettingsWording.autosaveCaption(enabled: effective))
                if !connected {
                    caption(AutosavePolicyConnection.notConnectedNote)
                }
            }
            Section {
                Picker(SettingsWording.textSizeTitle, selection: $settings.textSize) {
                    ForEach(TextSize.all, id: \.self) { size in
                        Text(size.description).tag(size)
                    }
                }
                .accessibilityIdentifier("ww.settings.textSize")
                caption(SettingsWording.textSizeCaption)
            }
            Section {
                LibraryLocationControl()
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct SourcesSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(SettingsWording.downloadTitle, isOn: $settings.downloadSourcesAutomatically)
                    .toggleStyle(.switch)
                    .help(SettingsWording.downloadCaption(enabled: settings.downloadSourcesAutomatically))
                    .accessibilityIdentifier("ww.settings.downloadSources")
                caption(SettingsWording.downloadCaption(enabled: settings.downloadSourcesAutomatically))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor @ViewBuilder
private func caption(_ text: String) -> some View {
    Text(text)
        .wwFont(.body)
        .foregroundStyle(Color.primary)
        .fixedSize(horizontal: false, vertical: true)
}

/// Settings › General › Library location (states-and-recovery §5.1). A UI shell over the persistence
/// lane's `LibraryLocationControlling`: shows the current location and library-level state honestly; a
/// move is confirmed explicitly and is not undoable (ST-35).
private struct LibraryLocationControl: View {
    @State private var moveError: String?
    @State private var selection = Selection.current

    private enum Selection: Hashable {
        case current
        case inWaveWrangler
        case chooseFolder
    }

    private var controller: LibraryLocationControlling { LibraryUIStore.shared.services.location }

    var body: some View {
        let location = controller.location
        VStack(alignment: .leading, spacing: 6) {
            Picker("Library location", selection: $selection) {
                if case .folder = location {
                    Text(location.title).tag(Selection.current)
                    Text(LibraryLocationChoice.inWaveWranglerTitle).tag(Selection.inWaveWrangler)
                } else {
                    Text(LibraryLocationChoice.inWaveWranglerTitle).tag(Selection.current)
                }
                Divider()
                Text(LibraryLocationChoice.chooseFolderTitle).tag(Selection.chooseFolder)
            }
            .accessibilityIdentifier("ww.settings.libraryLocation")
            .onChange(of: selection) { _, choice in handleChoice(choice) }
            caption(location.caption)
            if let phase = controller.movePhase {
                HStack {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(phase.text)
                    Button("Cancel") { controller.cancelMove() }
                }
                .accessibilityElement(children: .combine)
            }
            if let level = LibraryLevelPresentation(controller.libraryState) {
                Label(level.heading, systemImage: level.symbolName)
                    .fixedSize(horizontal: false, vertical: true)
                if let pending = controller.pendingEditsStatus ?? level.pendingText { Text(pending) }
            }
            if let result = controller.resultMessage {
                Text(result).fixedSize(horizontal: false, vertical: true)
            }
            if !controller.isConnected {
                Label("This version keeps the library only while WaveWrangler is open; it isn't saved to disk yet.", systemImage: "info.circle")
                    .wwFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let moveError {
                Label(moveError, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func handleChoice(_ choice: Selection) {
        switch choice {
        case .current:
            return
        case .inWaveWrangler:
            selection = .current
            move(to: nil, choice: .inWaveWrangler)
        case .chooseFolder:
            selection = .current
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = LibraryLocationChoice.choosePanelPrompt
            panel.prompt = "Choose"
            panel.begin { response in
                MainActor.assumeIsolated {
                    guard response == .OK, let url = panel.url else { return }
                    move(to: url, choice: .folder(displayName: url.lastPathComponent))
                }
            }
        }
    }

    private func move(to url: URL?, choice: LibraryLocationChoice) {
        let wording = choice.moveConfirmation
        Task {
            guard await Dialogs.confirm(
                in: NSApp.keyWindow, message: wording.message, informative: wording.informative, confirmTitle: wording.button,
                destructive: false
            ) else { return }
            moveError = nil
            handle(await controller.moveLibrary(to: url))
        }
    }

    private func handle(_ result: LibraryMoveResult) {
        switch result {
        case .moved:
            moveError = nil
            Task { await LibraryUIStore.shared.libraryWasReplaced() }
        case .failed(let reason):
            moveError = "Couldn't move your library: \(reason)"
        case .destinationHasLibrary(let folder, let blockedReason):
            Task { await offerExistingLibrary(in: folder, blockedReason: blockedReason) }
        }
    }

    /// ST-33 step 6: Use That Library · Choose Another Folder… · Cancel, with no default button.
    private func offerExistingLibrary(in folder: URL, blockedReason: String?) async {
        let alert = NSAlert()
        // `folder` is already a folder (the adapter reduced persistence's file URL once).
        alert.messageText = LibraryMoveWording.existingLibraryTitle(folder.lastPathComponent)
        alert.informativeText = blockedReason ?? LibraryMoveWording.existingLibraryCombineText
        let use = alert.addButton(withTitle: "Use That Library")
        use.isEnabled = blockedReason == nil
        use.keyEquivalent = ""
        alert.addButton(withTitle: "Choose Another Folder…").keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn:
            handle(await controller.useExistingLibrary(in: folder))
        case .alertSecondButtonReturn:
            handleChoice(.chooseFolder)
        default:
            break
        }
    }
}
