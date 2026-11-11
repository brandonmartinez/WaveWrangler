import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
import WWCore
import WWMix

private struct MixerInsertDrag: Codable, Hashable, Sendable, Identifiable, Transferable {
    static let type = UTType(exportedAs: "com.brandonmartinez.wavewrangler.mixer-insert", conformingTo: .data)
    let scope: String
    let slot: AudioUnitSlotID
    var id: Self { self }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: type).visibility(.ownProcess)
    }
}

struct MixerConsoleRack: View {
    @Bindable var presentation: EpisodeMixerPresentation
    let bus: MixerBus
    @State private var targetedRow: Int?
    @State private var targetedAfter = false
    private var slots: [AudioUnitSlot] { presentation.inserts(bus) }
    private var canEdit: Bool {
        presentation.canEditMix && presentation.state?.store.document?.mixerTransactions.isBusy != true
    }
    private var firstBlank: Int? {
        (0..<EpisodeMixState.maximumInsertsPerBus).first { row in slot(at: row) == nil }
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<presentation.insertRowCount, id: \.self) { row in
                ZStack {
                    if let slot = slot(at: row) {
                        MixerConsoleInsert(presentation: presentation, bus: bus, slot: slot, row: row)
                    } else {
                        Menu {
                            MixerEffectChoices(presentation: presentation) { component in
                                presentation.changeInserts(bus, action: "Add Audio Unit") {
                                    try MixerInsertRack.adding(component.newSlot, at: row, to: $0)
                                }
                            }
                        } label: {
                            HStack {
                                Spacer(minLength: 0)
                                Image(systemName: "plus").font(.system(size: 9))
                            }.padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 24)
                                .contentShape(Rectangle())
                                .accessibilityElement(children: .combine)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .frame(maxWidth: .infinity)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15)) }
                        .accessibilityLabel("Add effect at insert \(row + 1)")
                        .accessibilityIdentifier(row == firstBlank ? "ww.mixer.strip.\(bus.identifier).add"
                                                   : "ww.mixer.strip.\(bus.identifier).empty.\(row)")
                        .help(row < 64 ? "Add an effect at insert \(row + 1). Empty rows do not process audio."
                                      : "64-slot rack limit reached. Fill an earlier empty slot or remove an effect.")
                        .disabled(row >= EpisodeMixState.maximumInsertsPerBus)
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .overlay(alignment: targetedAfter ? .bottom : .top) {
                    if targetedRow == row {
                        Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                    }
                }
                .dropDestination(for: MixerInsertDrag.self,
                                 isEnabled: canEdit && row < EpisodeMixState.maximumInsertsPerBus) { items, _ in
                    guard items.count == 1, let item = items.first,
                          item.scope == presentation.insertDragOrigin(for: bus),
                          slots.contains(where: { $0.id == item.slot }) else { return }
                    presentation.changeInserts(bus, action: "Move Audio Unit") {
                        try MixerInsertRack.moving(item.slot, to: row, in: $0)
                    }
                }
                .dropConfiguration { session in
                    DropConfiguration(operation: source(in: session) == nil ? .forbidden : .move)
                }
                .onDropSessionUpdated { session in
                    switch session.phase {
                    case .entering, .active:
                        guard let source = source(in: session),
                              let index = slots.firstIndex(where: { $0.id == source.id }) else { return }
                        targetedAfter = slot(at: row) != nil
                            && MixerInsertRack.position(of: source, at: index) < row
                        targetedRow = row
                    default:
                        if targetedRow == row { targetedRow = nil }
                    }
                }
            }
        }
        .disabled(!canEdit)
        .opacity(presentation.usesProductionMix ? 1 : 0.4)
        .accessibilityElement(children: .contain).accessibilityLabel("Insert effects")
    }

    private func slot(at row: Int) -> AudioUnitSlot? {
        slots.enumerated().first { MixerInsertRack.position(of: $0.element, at: $0.offset) == row }?.element
    }

    private func source(in session: DropSession) -> AudioUnitSlot? {
        guard canEdit, session.itemsCount == 1,
              let items = session.localSession?.draggedItemIDs(for: MixerInsertDrag.self),
              items.count == 1, let source = items.first,
              source.scope == presentation.insertDragOrigin(for: bus) else { return nil }
        return slots.first { $0.id == source.slot }
    }
}

private extension EpisodeMixerPresentation {
    func insertDragOrigin(for bus: MixerBus) -> String {
        "\(insertDragScope)|\(episode?.id.description ?? "")|\(bus.identifier)"
    }
}

private extension MixerComponent {
    var newSlot: AudioUnitSlot {
        AudioUnitSlot(component: identity, productName: name, version: String(version))
    }
}

private struct MixerEffectChoices: View {
    let presentation: EpisodeMixerPresentation
    let select: (MixerComponent) -> Void
    var body: some View {
        ForEach(presentation.componentGroups) { group in
            Menu(group.manufacturer) {
                ForEach(group.components) { component in Button(component.name) { select(component) } }
            }
        }
        if presentation.components.isEmpty { Text("No installed effects found") }
    }
}

private struct MixerConsoleInsert: View {
    @Bindable var presentation: EpisodeMixerPresentation
    let bus: MixerBus
    let slot: AudioUnitSlot
    let row: Int
    @State private var hovered = false
    @FocusState private var focus: Focus?
    private enum Focus: Hashable { case pill, power, editor, actions }
    private var identifier: String { "ww.mixer.slot.\(slot.id)" }
    private var missing: Bool { !presentation.components.contains { $0.identity == slot.component } }
    private var expanded: Bool { hovered || focus != nil }
    private var name: String { slot.productName ?? "Audio Unit" }
    private var diagnostics: String {
        if missing { return "Not installed. Saved state retained. Install this unit or replace/remove the effect." }
        if let status = presentation.controller?.unitStatuses.first(where: { $0.slot == slot.id }) {
            return "\(status.loadedInProcess ? "In process" : "Out of process"), \(status.latencyFrames) latency frames."
        }
        return "Not loaded."
    }
    private var payload: MixerInsertDrag {
        MixerInsertDrag(scope: presentation.insertDragOrigin(for: bus), slot: slot.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal").font(.system(size: 8))
                .frame(width: 14, height: 24).contentShape(Rectangle())
                .accessibilityLabel("Reorder \(name)")
                .accessibilityIdentifier("\(identifier).drag")
            ZStack {
                HStack(spacing: 3) {
                    if missing { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(compactName).lineLimit(1).truncationMode(.tail)
                        .accessibilityIdentifier("\(identifier).name")
                    Spacer(minLength: 0)
                    Image(systemName: slot.bypassed ? "power" : "chevron.down").font(.system(size: 8))
                }
                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 7)
                .opacity(expanded ? 0 : 1)
                .accessibilityHidden(expanded)
                HStack(spacing: 0) {
                    Button { bypass() } label: { Image(systemName: "power").frame(width: 27, height: 24) }
                        .accessibilityLabel(slot.bypassed ? "Enable \(name)" : "Bypass \(name)")
                        .accessibilityIdentifier("\(identifier).bypass").focused($focus, equals: .power)
                    Button {
                        if NSEvent.modifierFlags.contains(.option) { bypass() } else { openEditor() }
                    } label: {
                        Image(systemName: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 24)
                    }
                    .accessibilityLabel("Open \(name) editor").accessibilityIdentifier("\(identifier).editor")
                    .focused($focus, equals: .editor)
                    Menu { actions } label: { Image(systemName: "chevron.down").frame(width: 25, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .accessibilityLabel("Actions for \(name)").accessibilityIdentifier("\(identifier).actions")
                        .focused($focus, equals: .actions)
                }
                .buttonStyle(.plain).opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
            }
        }
        .frame(height: 24)
        .foregroundStyle(slot.bypassed ? .secondary : .primary)
        .background(slot.bypassed ? Color.primary.opacity(0.05) : Color.accentColor.opacity(0.2),
                    in: RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(focus != nil ? 0.7 : 0.2)) }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .background { MixerOptionClick(action: bypass) }
        .onTapGesture(count: 2) {
            if NSEvent.modifierFlags.contains(.option) { bypass() } else { openEditor() }
        }

        .focusable().focused($focus, equals: .pill)
        .onKeyPress(.return) { openEditor(); return .handled }
        .onKeyPress(.space) { bypass(); return .handled }
        .draggable(MixerInsertDrag.self, item: payload)
        .dragConfiguration(DragConfiguration(
            operationsWithinApp: .init(allowCopy: false, allowMove: true),
            operationsOutsideApp: .init(allowCopy: false)))
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), insert \(row + 1)\(slot.bypassed ? ", bypassed" : "")\(missing ? ", not installed" : "")")
        .accessibilityIdentifier(identifier)
        .accessibilityAction(named: Text("Toggle bypass")) { bypass() }
        .accessibilityAction(named: Text("Open editor")) { openEditor() }
        .help("\(name). \(diagnostics) Option-click to enable or bypass. Double-click for settings. Drag to move within this strip.")
    }

    private var compactName: String {
        let shortName = presentation.controller?.unitStatuses.first { $0.slot == slot.id }?.shortName
        let manufacturer = presentation.components.first { $0.identity == slot.component }?.manufacturer
        return MixerAudioUnits.compactName(name, shortName: shortName, manufacturer: manufacturer)
    }

    @ViewBuilder private var actions: some View {
        Button(slot.bypassed ? "Enable" : "Bypass") { bypass() }
        Button("Open Editor") { openEditor() }
        Button("Generic Parameters") { openEditor(generic: true) }
            .accessibilityIdentifier("\(identifier).generic")
        Divider()
        Menu("Replace Effect") {
            MixerEffectChoices(presentation: presentation) { component in
                presentation.changeInserts(bus, action: "Replace Audio Unit") {
                    try MixerInsertRack.replacing(slot.id, with: component.newSlot, in: $0)
                }
            }
        }
        Button("Move Earlier") { move(to: row - 1) }.disabled(row == 0)
            .accessibilityIdentifier("\(identifier).earlier")
        Button("Move Later") { move(to: row + 1) }.disabled(row >= 63)
            .accessibilityIdentifier("\(identifier).later")
        Button("Remove") {
            presentation.changeInserts(bus, action: "Remove Audio Unit") {
                try MixerInsertRack.removing(slot.id, from: $0)
            }
        }.accessibilityIdentifier("\(identifier).remove")
        Divider()
        Text(diagnostics)
    }

    private func openEditor(generic: Bool = false) {
        guard presentation.canEditMix else { return }
        hovered = false
        focus = nil
        presentation.openEditor(slot, generic: generic)
    }

    private func move(to row: Int) {
        presentation.changeInserts(bus, action: "Move Audio Unit") {
            try MixerInsertRack.moving(slot.id, to: row, in: $0)
        }
    }
    private func bypass() {
        presentation.changeInserts(bus, action: "Bypass Audio Unit", replacingInstances: false) { slots in
            guard let index = slots.firstIndex(where: { $0.id == slot.id }) else { throw MixerInsertRack.Failure.missingSlot }
            var result = slots
            result[index].bypassed.toggle()
            return result
        }
    }
}

struct MixerOptionClick: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView(action: action) }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.action = action
        view.isEnabled = context.environment.isEnabled
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var action: () -> Void
        var isEnabled = true
        private var monitor: Any?
        private var consumedDown = false

        init(action: @escaping () -> Void) {
            self.action = action
            super.init(frame: .zero)
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consume(event) == true }
                return consumed ? nil : event
            }
        }

        private func consume(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            if event.type == .leftMouseUp, consumedDown {
                consumedDown = false
                return true
            }
            guard event.type == .leftMouseDown else { return false }
            consumedDown = false
            let point = convert(event.locationInWindow, from: nil)
            guard isEnabled, !isHiddenOrHasHiddenAncestor, window.attachedSheet == nil,
                  event.modifierFlags.contains(.option),
                  bounds.contains(point), visibleRect.contains(point) else { return false }
            // Handle the original event before a child button or native menu starts tracking.
            consumedDown = true
            action()
            return true
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            consumedDown = false
        }
    }
}
