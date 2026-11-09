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
        let contentHeight = NSScreen.main.map { min(730, $0.visibleFrame.height - 48) } ?? 730
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: ControlBarCustomization(settings: .shared, contentHeight: contentHeight)))
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
    let contentHeight: CGFloat

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
                Section("Controls") {
                    ForEach(settings.controlBar.groups, id: \.self) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(group.title).fontWeight(.semibold)
                                Spacer()
                                Button("Move \(group.title) Earlier", systemImage: "chevron.up") { move(group, by: -1) }
                                    .disabled(settings.controlBar.groups.first == group)
                                Button("Move \(group.title) Later", systemImage: "chevron.down") { move(group, by: 1) }
                                    .disabled(settings.controlBar.groups.last == group)
                            }
                            ForEach(ControlBarConfiguration.Control.allCases.filter { $0.group == group }, id: \.self) { control in
                                Toggle(control.title, isOn: Binding(
                                    get: { settings.controlBar.controls.contains(control) },
                                    set: { enabled in
                                        if enabled { settings.controlBar.controls.insert(control) }
                                        else { settings.controlBar.controls.remove(control) }
                                    }))
                                .toggleStyle(.checkbox)
                                .accessibilityIdentifier("ww.controlBar.control.\(control.rawValue)")
                            }
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
            Text("Transport and the centered display always stay visible. Unchecked controls and controls that do not fit remain in More. Groups with no selected controls are hidden.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = settings.controlBarError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Done") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460, height: contentHeight)
    }

    private func move(_ group: ControlBarConfiguration.Group, by offset: Int) {
        guard let index = settings.controlBar.groups.firstIndex(of: group) else { return }
        let target = index + offset
        guard settings.controlBar.groups.indices.contains(target) else { return }
        settings.controlBar.groups.swapAt(index, target)
    }
}
