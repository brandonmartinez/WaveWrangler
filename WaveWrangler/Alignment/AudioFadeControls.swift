import AppKit
import SwiftUI
import WWCommonEdit
import WWCore

struct AudioFadeInput {
    struct Refusal: LocalizedError {
        let errorDescription: String?
        init(_ reason: String) { errorDescription = reason }
    }

    static func amplitude(_ text: String, silence: Bool) throws -> Double {
        if silence { return 0 }
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, (0...1).contains(value) else {
            throw Refusal("Enter a finite linear amplitude from 0 to 1, or select Silence. 1 is full level; 0 is exact silence.")
        }
        return value
    }

    static func coordinate(_ text: String) throws -> AudioEnvelopeCoordinate {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let numerator = Int64(parts[0]) else {
            throw Refusal("Enter an exact clip-local frame: a whole number or numerator/denominator.")
        }
        let denominator: Int64
        if parts.count == 2 {
            guard let value = Int64(parts[1]), value > 0 else {
                throw Refusal("The frame denominator must be a positive whole number.")
            }
            denominator = value
        } else { denominator = 1 }
        return try AudioEnvelopeCoordinate(numerator: numerator, denominator: denominator)
    }

    static func frameText(_ coordinate: AudioEnvelopeCoordinate) -> String {
        coordinate.denominator == 1 ? String(coordinate.numerator) : "\(coordinate.numerator)/\(coordinate.denominator)"
    }

    static func levelText(_ amplitude: Double) -> String { amplitude == 0 ? "Silence" : String(amplitude) }

    static func describe(_ error: Error) -> String {
        if let reason = (error as? LocalizedError)?.errorDescription { return reason }
        if let error = error as? AudioEnvelopeEditError {
            return switch error {
            case .invalidInterval: "The fade must start inside the audible trimmed clip and end later, no later than its exclusive endpoint."
            case .invalidDirection: "Fade In must increase from the start amplitude to the end amplitude; Fade Out must decrease. Adjust either endpoint."
            case .unknownPoint: "This fade point is no longer available. Cancel and reopen point editing."
            case .retainedSupportIsReadOnly: "This is retained curve support outside the audible trim, not an editable local point."
            case .replacementRequired: "Review and explicitly approve replacement of the listed automation before applying."
            }
        }
        if let error = error as? AudioEnvelopeCoordinateError {
            return switch error {
            case .invalidDenominator: "The frame denominator must be a positive whole number."
            case .unrepresentableDenominator: "That frame fraction cannot be represented exactly. Use a whole frame or a reduced denominator no larger than 192000."
            case .outsideEnvelope: "That frame is outside the supported envelope bounds."
            case .nonCanonical, .invalidFraction: "The retained frame coordinate is invalid. The curve has not been changed."
            }
        }
        if let error = error as? AudioEnvelopeError {
            switch error {
            case .outsideClip, .outsideClipCoordinate:
                return "Place the point inside the audible trimmed clip, or exactly at its exclusive end."
            case .invalidAmplitude:
                return "Enter a finite linear amplitude from 0 to 1, or select Silence."
            default: break
            }
        }
        return "Fade edit refused: \(error)"
    }
}

@MainActor
final class AudioFadeSession: Identifiable {
    enum Purpose {
        case fade(AudioFadeDirection, start: Int64)
        case point(Int)
    }
    let id = UUID()
    let purpose: Purpose
    let generation: UInt64
    let selectionVersion: UUID
    let lifetime: UUID
    let episode: Episode
    let projected: ProgramAudioClip
    let editing: AudioEnvelopeEditing
    let initialLocalFrame: String
    let currentAmplitude: Double
    weak var owner: ShowWindowState?
    weak var originWindow: NSWindow?
    let requiresOwner: Bool

    init(purpose: Purpose, generation: UInt64, selectionVersion: UUID, lifetime: UUID,
         episode: Episode, projected: ProgramAudioClip, owner: ShowWindowState?) throws {
        self.purpose = purpose
        self.generation = generation
        self.selectionVersion = selectionVersion
        self.lifetime = lifetime
        self.episode = episode
        self.projected = projected
        self.owner = owner
        originWindow = owner?.window
        requiresOwner = owner != nil
        editing = try .init(envelope: projected.clip.envelope, durationFrames: Int64(projected.programFrames.count))
        switch purpose {
        case .fade(_, let start):
            initialLocalFrame = String(start)
            currentAmplitude = try editing.evaluator.amplitude(atLocalFrame: start)
        case .point(let index):
            guard projected.clip.envelope.points.indices.contains(index) else { throw AudioEnvelopeEditError.unknownPoint }
            initialLocalFrame = AudioFadeInput.frameText(try editing.localCoordinate(of: projected.clip.envelope.points[index]))
            currentAmplitude = projected.clip.envelope.points[index].amplitude
        }
    }

    var title: String {
        switch purpose {
        case .fade(.fadeIn, _): "Fade In"
        case .fade(.fadeOut, _): "Fade Out"
        case .point: "Edit Fade Point"
        }
    }
}

@MainActor
struct AudioFadeDraft {
    var length: String
    var usingEnd = false
    var level: String
    var silence: Bool
    var startLevel: String
    var startSilence: Bool
    var localFrame: String
    var removing = false
    var replacing = false

    init(session: AudioFadeSession) {
        switch session.purpose {
        case .fade(let direction, let start):
            length = AudioInsertionSheet.seconds(min(48_000, session.editing.evaluator.durationFrames - start))
            startLevel = direction == .fadeIn ? "0" : String(session.currentAmplitude)
            startSilence = direction == .fadeIn || session.currentAmplitude == 0
            level = direction == .fadeIn ? String(session.currentAmplitude) : "0"
            silence = direction == .fadeOut || session.currentAmplitude == 0
            localFrame = session.initialLocalFrame
        case .point(let index):
            let point = session.projected.clip.envelope.points[index]
            length = ""
            level = String(point.amplitude)
            silence = point.amplitude == 0
            startLevel = ""
            startSilence = false
            localFrame = session.initialLocalFrame
        }
    }
}

struct AudioClipFadeControls: View {
    @Bindable var editor: AudioClipEditorModel
    let playhead: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Clip Fades").font(.subheadline.bold())
            HStack {
                Button("Fade In…") {
                    Task { await editor.requestFade(.fadeIn, programSeconds: playhead) }
                }.accessibilityIdentifier("ww.audioFade.in")
                Button("Fade Out…") {
                    Task { await editor.requestFade(.fadeOut, programSeconds: playhead) }
                }.accessibilityIdentifier("ww.audioFade.out")
            }
            .disabled(editor.isPreparingFade)
            Text("Starts at the playhead. Linear amplitude: 1 = full, 0.25 = low, 0 = Silence.")
                .font(.caption).foregroundStyle(.secondary)
            if let selected = editor.selected {
                Text("\(selected.clip.envelope.points.count) fade points")
                    .font(.caption).accessibilityIdentifier("ww.audioFade.count")
                Menu("Edit Fade Point…") {
                    switch editor.fadePoints() {
                    case .success(let points):
                        if points.isEmpty { Text("No fade points") }
                        ForEach(points, id: \.index) { point in
                            Button("\(AudioFadeInput.frameText(point.local)) frames · \(AudioFadeInput.levelText(point.amplitude))\(point.editable ? "" : " · retained outside trim")") {
                                Task { await editor.requestFadePoint(point.index) }
                            }
                            .disabled(!point.editable || editor.isPreparingFade)
                            .accessibilityIdentifier("ww.audioFade.point.\(point.index)")
                        }
                    case .failure(let error): Text(AudioFadeInput.describe(error))
                    }
                }
                .accessibilityIdentifier("ww.audioFade.points")
            }
        }
    }
}

struct AudioFadeSheet: View {
    @Bindable var editor: AudioClipEditorModel
    let session: AudioFadeSession
    @State private var draft: AudioFadeDraft

    init(editor: AudioClipEditorModel, session: AudioFadeSession) {
        self.editor = editor
        self.session = session
        _draft = State(initialValue: AudioFadeDraft(session: session))
    }

    private var preview: Result<AudioEnvelopeEditPreview, Error> {
        Result { try editor.fadePreview(session, draft: draft) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(session.title).font(.title2)
            Text("Clip-local output time; original source samples, timing, transcripts, and waveform measurements stay unchanged.")
                .font(.caption).foregroundStyle(.secondary)
            switch session.purpose {
            case .fade(_, let start):
                Text("Starts at program \(AudioInsertionSheet.seconds(session.projected.programFrames.lowerBound + start)) s · clip-local frame \(start).")
                    .accessibilityIdentifier("ww.audioFade.start")
                Text("Evaluated current amplitude: \(AudioFadeInput.levelText(session.currentAmplitude))")
                    .accessibilityIdentifier("ww.audioFade.current")
                HStack {
                    Picker("Fade length", selection: $draft.usingEnd) {
                        Text("Duration (seconds)").tag(false)
                        Text("End (program seconds)").tag(true)
                    }.accessibilityIdentifier("ww.audioFade.lengthMode")
                    TextField("Fade length", text: $draft.length)
                        .accessibilityIdentifier("ww.audioFade.length")
                }
                HStack {
                    Text("Start amplitude (0…1)")
                    TextField("Start amplitude", text: $draft.startLevel)
                        .disabled(draft.startSilence)
                        .accessibilityIdentifier("ww.audioFade.startLevel")
                    Toggle("Silence", isOn: $draft.startSilence)
                        .accessibilityIdentifier("ww.audioFade.startSilence")
                }
                .textFieldStyle(.roundedBorder)
            case .point:
                LabeledContent("Clip-local frame (integer or fraction)") {
                    TextField("Clip-local frame", text: $draft.localFrame)
                        .accessibilityIdentifier("ww.audioFade.localFrame")
                }.disabled(draft.removing)
                Text("Moving a point reconnects the adjacent linear segments. Exact fractions preserve off-grid trim coordinates.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Remove this point", isOn: $draft.removing)
                    .accessibilityIdentifier("ww.audioFade.remove")
            }
            HStack {
                Text(amplitudeLabel)
                TextField(amplitudeLabel, text: $draft.level)
                    .disabled(draft.silence || draft.removing)
                    .accessibilityIdentifier("ww.audioFade.level")
                Toggle("Silence", isOn: $draft.silence)
                    .disabled(draft.removing)
                    .accessibilityIdentifier("ww.audioFade.silence")
            }
            .textFieldStyle(.roundedBorder)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    switch preview {
                    case .success(let edit):
                        Text(draft.removing && edit.envelope.points.isEmpty
                             ? "Removing the last point restores the empty, unity envelope."
                             : "\(edit.envelope.points.count) points after this edit. Endpoints hold; each ramp is linear amplitude.")
                            .accessibilityIdentifier("ww.audioFade.preview")
                        if edit.overlapsRamp {
                            Text("The new interval crosses existing ramp automation. Applying replaces that interval.")
                        }
                        ForEach(Array(edit.replacedPoints.enumerated()), id: \.offset) { _, point in
                            if let local = try? session.editing.localCoordinate(of: point) {
                                Text("Replace/remove local frame \(AudioFadeInput.frameText(local)), amplitude \(AudioFadeInput.levelText(point.amplitude)).")
                                    .font(.caption).monospacedDigit()
                            } else {
                                Text("Retained point coordinate is unavailable. Cancel and reopen this editor.")
                                    .foregroundStyle(.red)
                            }
                        }
                        if case .point = session.purpose {
                            Text("Only the selected point and any explicitly listed collision are changed. Adjacent linear segments reconnect; every other knot remains exact.")
                                .font(.caption)
                        } else if let held = edit.heldUntil {
                            Text("Hold the target until local frame \(AudioFadeInput.frameText(held)), then follow the next ramp. Changed hold/start levels are listed above. Following ramp endpoints and outside-trim support stay retained.")
                                .font(.caption)
                        } else {
                            Text("Hold the target through the audible clip end. Outside-trim support stays retained.")
                                .font(.caption)
                        }
                        if edit.requiresReplacement {
                            Toggle("Replace the listed automation and affected connecting intervals", isOn: $draft.replacing)
                                .accessibilityIdentifier("ww.audioFade.replace")
                        }
                    case .failure(let error):
                        Label(AudioFadeInput.describe(error), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).accessibilityIdentifier("ww.audioFade.refusal")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 140, maxHeight: 240)
            if let error = editor.error {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("ww.audioFade.error")
            }
            HStack {
                Text("Fade preview is not saved. Apply is one Undo action.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { editor.dismissFade() }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("ww.audioFade.cancel")
                Button(draft.removing ? "Remove Point" : "Apply Fade") {
                    editor.commitFade(session, draft: draft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled({
                    if case .success(let edit) = preview { return edit.requiresReplacement && !draft.replacing }
                    return true
                }())
                .accessibilityIdentifier("ww.audioFade.apply")
            }
        }
        .padding(20)
        .frame(minWidth: 580, idealWidth: 660, minHeight: 420)
        .onChange(of: draft.usingEnd) { _, usingEnd in
            draft.replacing = false
            guard case .fade(_, let local) = session.purpose,
                  let value = try? AudioClipEditorModel.programFrame(draft.length) else { return }
            let start = session.projected.programFrames.lowerBound + local
            draft.length = AudioInsertionSheet.seconds(usingEnd ? start + value : value - start)
        }
        .onChange(of: draft.length) { _, _ in draft.replacing = false }
        .onChange(of: draft.level) { _, _ in draft.replacing = false }
        .onChange(of: draft.silence) { _, _ in draft.replacing = false }
        .onChange(of: draft.startLevel) { _, _ in draft.replacing = false }
        .onChange(of: draft.startSilence) { _, _ in draft.replacing = false }
        .onChange(of: draft.localFrame) { _, _ in draft.replacing = false }
        .onChange(of: draft.removing) { _, _ in draft.replacing = false }
    }

    private var amplitudeLabel: String {
        switch session.purpose {
        case .fade: "End amplitude (0…1)"
        case .point: "Point amplitude (0…1)"
        }
    }
}
