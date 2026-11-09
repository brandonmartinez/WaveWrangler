import AppKit
import SwiftUI
import WWCommonEdit

struct ControlBarLabelStyle: LabelStyle {
    let showsLabels: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if showsLabels { configuration.title }
        }
    }
}

@MainActor
final class ControlBarCustomizationController: NSWindowController {
    private static var instance: ControlBarCustomizationController?

    static func show() {
        let controller = instance ?? ControlBarCustomizationController()
        instance = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: ControlBarCustomization(settings: .shared)))
        window.title = "Customize Control Bar and Display"
        window.styleMask = [.titled, .closable]
        window.tabbingMode = .disallowed
        window.setAccessibilityIdentifier("ww.controlBar.customization")
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct ControlBarCustomization: View {
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Changes apply to every episode window on this Mac.")
                .foregroundStyle(.secondary)
            HStack {
                Menu("Apply Preset") {
                    ForEach(ControlBarConfiguration.Preset.allCases, id: \.self) { preset in
                        Button(preset.rawValue) { settings.controlBar = .preset(preset) }
                    }
                }
                Spacer()
                Button("Restore Defaults") { settings.restoreControlBar() }
                    .accessibilityIdentifier("ww.controlBar.restoreDefaults")
            }
            Form {
                Section("Control groups") {
                    ForEach(settings.controlBar.groups, id: \.self) { group in
                        HStack {
                            Toggle(group.title, isOn: Binding(
                                get: { settings.controlBar.visible.contains(group) },
                                set: { enabled in
                                    if enabled { settings.controlBar.visible.insert(group) }
                                    else { settings.controlBar.visible.remove(group) }
                                }))
                            Spacer()
                            Button("Move \(group.title) Earlier", systemImage: "chevron.up") { move(group, by: -1) }
                                .disabled(settings.controlBar.groups.first == group)
                            Button("Move \(group.title) Later", systemImage: "chevron.down") { move(group, by: 1) }
                                .disabled(settings.controlBar.groups.last == group)
                        }
                    }
                    .labelStyle(.iconOnly)
                    Toggle("Show icons and labels", isOn: $settings.controlBar.showsLabels)
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("ww.controlBar.labels")
                }
                Section("Display") {
                    Picker("Primary clock", selection: $settings.controlBar.primaryClock) {
                        ForEach(EpisodeClock.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("ww.controlBar.primary")
                    Picker("Secondary clock", selection: $settings.controlBar.secondaryClock) {
                        Text("None").tag(Optional<EpisodeClock>.none)
                        ForEach(EpisodeClock.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    Picker("Additional readout", selection: $settings.controlBar.readout) {
                        ForEach(ControlBarConfiguration.Readout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            .formStyle(.grouped)
            Text("Transport and the primary clock always stay visible. Hidden groups and controls that do not fit remain in More.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = settings.controlBarError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440, height: 610)
    }

    private func move(_ group: ControlBarConfiguration.Group, by offset: Int) {
        guard let index = settings.controlBar.groups.firstIndex(of: group) else { return }
        let target = index + offset
        guard settings.controlBar.groups.indices.contains(target) else { return }
        settings.controlBar.groups.swapAt(index, target)
    }
}
