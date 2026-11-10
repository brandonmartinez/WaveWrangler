import AppKit
import SwiftUI
import WWMix

struct MixerConsoleDial: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let identifier: String
    let endEditing: () -> Void
    @State private var previousDrag: CGFloat = 0
    @FocusState private var focused: Bool

    private var position: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }
    var body: some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                Circle().trim(from: 0.125, to: 0.875)
                    .stroke(.quaternary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().trim(from: 0.125, to: 0.125 + position * 0.75)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(90))
                Circle().fill(.background).padding(6)
                    .overlay { Circle().strokeBorder(.primary.opacity(focused ? 0.8 : 0.2)).padding(6) }
                Capsule().fill(.primary).frame(width: 2, height: 11)
                    .offset(y: -10).rotationEffect(.degrees(-135 + position * 270))
            }
            .frame(width: 42, height: 42).contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                focused = true
                let delta = previousDrag - drag.translation.height
                previousDrag = drag.translation.height
                let fine = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                set(value + Double(delta) / 160 * (range.upperBound - range.lowerBound) * fine)
            }.onEnded { _ in previousDrag = 0; endEditing() })
            .onTapGesture(count: 2) { set(0); endEditing() }
            .onTapGesture { focused = true }
            .focusable().focused($focused)
            .onKeyPress(.upArrow) { step(1); return .handled }
            .onKeyPress(.rightArrow) { step(1); return .handled }
            .onKeyPress(.downArrow) { step(-1); return .handled }
            .onKeyPress(.leftArrow) { step(-1); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(value.formatted(.number.precision(.fractionLength(2))))
            .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
            .accessibilityIdentifier("\(identifier).dial")
            .help("Drag vertically to adjust. Hold Shift for fine adjustment. Double-click to reset to zero.")
            MixerNumberControl(title: title, value: $value, range: range, identifier: identifier,
                               endEditing: endEditing, compact: true)
        }
        .onDisappear { endEditing() }
    }

    private func set(_ next: Double) { value = min(range.upperBound, max(range.lowerBound, next)) }
    private func step(_ direction: Double) {
        let increment = (range.upperBound - range.lowerBound) > 2 ? 0.5 : 0.01
        set(value + direction * increment * (NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1))
        endEditing()
    }
}

struct MixerConsoleFader: View {
    @Binding var value: Double
    let identifier: String
    let endEditing: () -> Void
    @State private var previousDrag: CGFloat = 0
    @FocusState private var focused: Bool
    private let travel: CGFloat = 142

    var body: some View {
        ZStack {
            Capsule().fill(.primary.opacity(0.18)).frame(width: 4, height: travel)
            ForEach([-96.0, -48, -12, 0, 12, 24], id: \.self) { db in
                HStack(spacing: 4) {
                    Text(db == -96 ? "-96" : String(Int(db))).font(.system(size: 9))
                        .foregroundStyle(db == 0 ? .primary : .secondary)
                        .frame(width: 22, alignment: .trailing)
                    Rectangle().fill(.primary.opacity(db == 0 ? 0.7 : 0.25))
                        .frame(width: db == 0 ? 13 : 7, height: 1)
                }
                .offset(x: -20, y: (0.5 - MixerConsoleScale.faderPosition(db)) * travel)
            }
            RoundedRectangle(cornerRadius: 3).fill(.background)
                .frame(width: 28, height: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(focused ? 0.9 : 0.45))
                    Rectangle().fill(.primary).frame(width: 20, height: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 2, y: 2)
                .offset(y: (0.5 - MixerConsoleScale.faderPosition(value)) * travel)
        }
        .frame(width: 70, height: 164).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
            focused = true
            let delta = previousDrag - drag.translation.height
            previousDrag = drag.translation.height
            let fine = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
            let position = MixerConsoleScale.faderPosition(value) + Double(delta / travel) * fine
            value = MixerConsoleScale.faderDecibels(position)
        }.onEnded { _ in previousDrag = 0; endEditing() })
        .onTapGesture(count: 2) { value = 0; endEditing() }
        .onTapGesture { focused = true }
        .focusable().focused($focused)
        .onKeyPress(.upArrow) { step(1); return .handled }
        .onKeyPress(.downArrow) { step(-1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Output volume")
        .accessibilityValue("\(value.formatted(.number.precision(.fractionLength(1)))) dB")
        .accessibilityAdjustableAction { step($0 == .increment ? 1 : -1) }
        .accessibilityIdentifier("\(identifier).fader")
        .help("Output volume, -96 to +24 dB. Drag vertically; Shift adjusts finely. Double-click for unity gain.")
        .onDisappear { endEditing() }
    }

    private func step(_ direction: Double) {
        value = min(24, max(-96, value + direction * (NSEvent.modifierFlags.contains(.shift) ? 0.1 : 0.5)))
        endEditing()
    }
}

struct MixerConsoleMeterView: View {
    let levels: [MixerConsoleLevel]
    let updatedAt: Date
    let playing: Bool
    let identifier: String
    @State private var decayFinished = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: levels.isEmpty || (!playing && decayFinished))) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(updatedAt))
            Canvas { context, size in
                let channels = levels.isEmpty ? [MixerConsoleLevel(), MixerConsoleLevel()] : levels
                let width = (size.width - CGFloat(channels.count - 1) * 2) / CGFloat(channels.count)
                for (index, level) in channels.enumerated() {
                    let x = CGFloat(index) * (width + 2)
                    context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)),
                                 with: .color(.primary.opacity(0.1)))
                    for db in stride(from: -60.0, through: -1, by: 2) {
                        let top = size.height * (1 - MixerConsoleScale.meterPosition(db + 1))
                        let bottom = size.height * (1 - MixerConsoleScale.meterPosition(db))
                        if db <= level.rmsDB - elapsed * 20 {
                            let color: Color = db >= -6 ? .yellow : .green
                            context.fill(Path(CGRect(x: x, y: top, width: width, height: max(1, bottom - top))),
                                         with: .color(color))
                        }
                    }
                    let peak = size.height * (1 - MixerConsoleScale.meterPosition(level.peakDB - elapsed * 20))
                    context.fill(Path(CGRect(x: x, y: max(0, peak - 1), width: width, height: 2)),
                                 with: .color(level.clipped ? .red : .primary))
                    if level.clipped {
                        context.fill(Path(CGRect(x: x, y: 0, width: width, height: 3)), with: .color(.red))
                    }
                }
            }
        }
        .frame(width: 20, height: 142)
        .task(id: playing) {
            decayFinished = false
            guard !playing else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            decayFinished = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Post-fader peak and RMS levels")
        .accessibilityValue(levels.map { level in
            "Peak \(db(level.peakDB)), RMS \(db(level.rmsDB))\(level.clipped ? ", clipped" : "")"
        }.joined(separator: "; "))
        .accessibilityIdentifier(identifier)
        .help("Sample peak marker and 300 ms RMS bars, -60 to 0 dBFS. Prepared digital PCM on the playback clock, not acoustic or true-peak measurement.")
    }

    private func db(_ value: Double) -> String { value.isFinite ? String(format: "%.1f dBFS", value) : "silence" }
}
