import AppKit
import UniformTypeIdentifiers
import WWCore
import WWOrganizer

/// File › New Show… (IA-04: location first). The native save panel asks for a name and location before
/// the show exists, so there are no "Untitled" shows and no show lives only in an autosave area.
@MainActor
enum NewShowCommand {
    static func run() {
        let panel = NSSavePanel()
        panel.title = "New Show"
        panel.prompt = "Create"
        panel.nameFieldLabel = "Show name:"
        panel.nameFieldStringValue = "New Show"
        panel.allowedContentTypes = [.wwShow]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        panel.message = "Choose a name and where to save the show. It can be a folder that syncs, like iCloud Drive."
        let accessory = NSTextField(wrappingLabelWithString: SettingsWording.newShowAccessory(autosaveEnabled: AutosavePolicyConnection.effectiveAutosaveEnabled))
        accessory.frame = NSRect(x: 0, y: 0, width: 420, height: 34)
        panel.accessoryView = accessory
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                create(at: url)
            }
        }
    }

    static func create(at url: URL, episodes: [Episode] = []) {
        let name = url.deletingPathExtension().lastPathComponent
        var model = (try? ShowDocumentModel.untitled().renamingShow(to: name)) ?? .untitled()
        for episode in episodes {
            model = (try? model.addingEpisode(episode)) ?? model
        }
        create(at: url, model: model)
    }

    static func create(at url: URL, model: ShowDocumentModel) {
        let controller = NSDocumentController.shared
        do {
            guard let document = try controller.makeUntitledDocument(ofType: DocumentTypes.show) as? ShowDocument else { return }
            document.store.replaceLoadedModel(model)
            document.save(to: url, ofType: DocumentTypes.show, for: .saveAsOperation) { error in
                MainActor.assumeIsolated {
                    if let error {
                        NSApp.presentError(error)
                        return
                    }
                    controller.addDocument(document)
                    document.makeWindowControllers()
                    document.showWindows()
                    controller.noteNewRecentDocument(document)
                }
            }
        } catch {
            NSApp.presentError(error)
        }
    }
}
