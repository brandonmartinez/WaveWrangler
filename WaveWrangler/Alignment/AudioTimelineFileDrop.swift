import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
import WWCore

enum AudioImportTrackIntent: Hashable {
    case defaultTrack
    case existing(AudioTrackID)
    case newTrack
}

enum AudioImportLayout: String, CaseIterable {
    case sequential
    case overlay
}

struct AudioImportDestination: Equatable {
    let frame: Int64
    let track: AudioImportTrackIntent
}

enum AudioTimelineFileDropPayload {
    static func validate(_ locations: [NSItemProvider], itemCount: Int) throws {
        guard itemCount > 0, locations.count == itemCount else {
            throw StagedAudioImportCoordinator.Refusal(
                "Every dragged item must provide a local file location (\(locations.count) locations for \(itemCount) items). Drop files separately from web links, recording rows, or file promises.")
        }
        try validate(locations)
    }

    static func validate(_ providers: [NSItemProvider]) throws {
        guard !providers.isEmpty, providers.allSatisfy({
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                && !$0.hasItemConformingToTypeIdentifier(SetupSourceDrag.contentType.identifier)
        }) else {
            throw StagedAudioImportCoordinator.Refusal(
                "Drop local file locations only. Recording rows, web URLs, file promises, and mixed payloads cannot become Audio Clips.")
        }
    }
}

/// One target's live, whole-session inventory. Exiting or consuming clears every usable count.
struct AudioTimelineDropSessionMetadata<SessionID: Hashable> {
    enum Phase: String, Equatable { case entering, active, exiting, ended }
    private struct Snapshot {
        let id: SessionID
        let phase: Phase
        let itemCount: Int
    }
    private var isTargeted = false
    private var pending: Snapshot?
    private var bound: Snapshot?
    private var endedIDs: Set<SessionID> = []
    private var lastObservedPhase: Phase?

    mutating func entered() {
        isTargeted = true
        bound = pending
        pending = nil
    }

    mutating func updated(id: SessionID, phase nextPhase: Phase, itemCount count: Int) {
        lastObservedPhase = nextPhase
        switch nextPhase {
        case .entering, .active:
            guard !endedIDs.contains(id) else { return }
            let snapshot = Snapshot(id: id, phase: nextPhase, itemCount: count)
            if isTargeted {
                if bound == nil || bound?.id == id {
                    bound = snapshot
                } else {
                    isTargeted = false
                    bound = nil
                    pending = snapshot
                }
            } else {
                pending = snapshot
            }
        case .exiting:
            if bound?.id == id {
                isTargeted = false
                bound = nil
            }
            if pending?.id == id { pending = nil }
        case .ended:
            endedIDs.insert(id)
            if bound?.id == id {
                isTargeted = false
                bound = nil
            }
            if pending?.id == id { pending = nil }
        }
    }

    mutating func exited() {
        isTargeted = false
        pending = nil
        bound = nil
    }

    mutating func consumeCount() throws -> Int {
        guard isTargeted, let bound, !endedIDs.contains(bound.id),
              bound.phase == .active, bound.itemCount > 0 else {
            throw StagedAudioImportCoordinator.Refusal(
                "The current drag session metadata is unavailable or stale (last phase: \(lastObservedPhase?.rawValue ?? "none")). Move the files onto the canvas and drop again.")
        }
        endedIDs.insert(bound.id)
        exited()
        return bound.itemCount
    }
}

/// Coordinates are local to the waveform canvas, excluding its row header and padding.
struct AudioTimelineDropGeometry {
    let size: CGSize
    let start: Double
    let duration: Double
    let projection: AudioTimelineProjection
    let track: AudioImportTrackIntent

    func destination(at point: CGPoint) throws -> AudioImportDestination {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              point.x.isFinite, point.y.isFinite, point.x >= 0, point.x <= size.width,
              point.y >= 0, point.y <= size.height,
              start.isFinite, duration.isFinite, duration > 0 else {
            throw StagedAudioImportCoordinator.Refusal("Drop on a timeline canvas, not its header or padding.")
        }
        let display = start + point.x / size.width * duration
        guard let program = projection.programTime(forDisplayTime: display) else {
            throw StagedAudioImportCoordinator.Refusal(
                "Audio cannot be placed inside Show cut's expanded review-only interval. Hide the cut or choose a program position.")
        }
        return .init(frame: try AudioClipEditorModel.programFrame(program), track: track)
    }
}

struct AudioTimelineFileDropTarget: ViewModifier {
    let importer: StagedAudioImportCoordinator
    let state: ShowWindowState?
    let start: Double
    let duration: Double
    let projection: AudioTimelineProjection
    let track: AudioImportTrackIntent
    var measureCanvas: ((CGRect) -> Void)? = nil
    @State private var point: CGPoint?
    @State private var feedback: String?
    @State private var canvasSize: CGSize = .zero
    @State private var inventory = AudioTimelineDropSessionMetadata<DropSession.ID>()

    func body(content: Content) -> some View {
        let dropGeometry = AudioTimelineDropGeometry(size: canvasSize, start: start,
            duration: duration, projection: projection, track: track)
        content
            .background {
                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                canvasSize = $0.size
                measureCanvas?($0)
            }
            .onDrop(of: [UTType.fileURL.identifier, SetupSourceDrag.contentType.identifier],
                delegate: AudioTimelineFileDropDelegate(importer: importer, state: state,
                    geometry: dropGeometry, inventory: $inventory, point: $point, feedback: $feedback))
            .onDropSessionUpdated { session in
                let phase: AudioTimelineDropSessionMetadata<DropSession.ID>.Phase
                switch session.phase {
                case .entering: phase = .entering
                case .active: phase = .active
                case .exiting: phase = .exiting
                case .ended, .dataTransferCompleted: phase = .ended
                @unknown default:
                    inventory.exited()
                    return
                }
                inventory.updated(id: session.id, phase: phase, itemCount: session.itemsCount)
            }
            .onDisappear { inventory.exited() }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let point, let feedback {
                        Rectangle().fill(Color.accentColor).frame(width: 2)
                            .offset(x: point.x)
                        Text(feedback).font(.caption2).padding(5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .offset(x: max(0, min(point.x + 5, canvasSize.width - 210)), y: 3)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct AudioTimelineFileDropDelegate: DropDelegate {
    let importer: StagedAudioImportCoordinator
    let state: ShowWindowState?
    let geometry: AudioTimelineDropGeometry
    @Binding var inventory: AudioTimelineDropSessionMetadata<DropSession.ID>
    @Binding var point: CGPoint?
    @Binding var feedback: String?

    func validateDrop(info: DropInfo) -> Bool {
        state?.canEdit == true && state?.alignmentModel?.audioEditor.canPlaceDroppedAudio == true
            && importer.canBeginImport
            && info.hasItemsConforming(to: [UTType.fileURL.identifier, SetupSourceDrag.contentType.identifier])
    }

    func dropEntered(info: DropInfo) {
        inventory.entered()
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        let valid = state?.alignmentModel?.audioEditor.canPlaceDroppedAudio == true
            && !info.hasItemsConforming(to: [SetupSourceDrag.contentType.identifier])
            && (try? geometry.destination(at: info.location)) != nil
        return DropProposal(operation: valid ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        inventory.exited()
        point = nil
        feedback = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { inventory.exited(); point = nil; feedback = nil }
        guard let state else { return false }
        guard state.alignmentModel?.audioEditor.canPlaceDroppedAudio == true,
              state.alignmentModel?.presentationTimeline == geometry.projection else {
            importer.refuseDrop("The timeline projection changed. Wait for the current canvas, then drop the files again.")
            return false
        }
        guard !info.hasItemsConforming(to: [SetupSourceDrag.contentType.identifier]) else {
            importer.refuseDrop("Recording rows cannot become Audio Clips. Drop local audio files from Finder; mixed recording/file drags are not accepted.")
            return false
        }
        do {
            let destination = try geometry.destination(at: info.location)
            let itemCount = try inventory.consumeCount()
            let locations = info.itemProviders(for: [UTType.fileURL.identifier])
            try AudioTimelineFileDropPayload.validate(locations, itemCount: itemCount)
            return importer.receiveDrop(locations, in: state, destination: destination)
        } catch {
            importer.refuseDrop(error.localizedDescription)
            return false
        }
    }

    private func update(_ info: DropInfo) {
        point = info.location
        if info.hasItemsConforming(to: [SetupSourceDrag.contentType.identifier]) {
            feedback = "Recording rows cannot become Audio Clips"
        } else {
            do {
                let destination = try geometry.destination(at: info.location)
                feedback = String(format: "Add Audio at %.3f s", Double(destination.frame) / 48_000)
            } catch {
                feedback = "No program placement here"
            }
        }
    }
}
