import Foundation
import SwiftUI
import WWCommonEdit
import WWCore

enum EpisodeTimeDisplay {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, abs(seconds) <= 172_800 else { return "Unavailable" }
        let milliseconds = Int64((abs(seconds) * 1000).rounded())
        return String(
            format: "%@%02lld:%02lld:%02lld.%03lld",
            seconds < 0 && milliseconds != 0 ? "-" : "", milliseconds / 3_600_000,
            milliseconds / 60_000 % 60, milliseconds / 1000 % 60, milliseconds % 1000)
    }

    static func parse(_ text: String) throws -> Double {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let negative = value.hasPrefix("-")
        let unsigned = negative ? String(value.dropFirst()) : value
        let parts = unsigned.split(separator: ":", omittingEmptySubsequences: false)
        let seconds: Double
        if parts.count == 1, let number = Double(value) {
            seconds = number
        } else if parts.count == 3,
            let hours = Int(parts[0]), (0...48).contains(hours),
            let minutes = Int(parts[1]), (0..<60).contains(minutes),
            let last = Double(parts[2]), (0..<60).contains(last)
        {
            seconds = (Double(hours * 3600 + minutes * 60) + last) * (negative ? -1 : 1)
        } else {
            throw EpisodeProductionError.invalidClockPosition
        }
        guard seconds.isFinite, abs(seconds) <= 172_800 else {
            throw EpisodeProductionError.invalidClockPosition
        }
        return seconds
    }
}

struct EpisodeClockDisplay: View {
    @Bindable var model: EpisodeAlignmentModel
    @Binding var clock: EpisodeClock
    var configuration = ControlBarConfiguration()
    @State private var draft = ""
    @FocusState private var editing: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var displayInk: Color {
        colorScheme == .dark ? Color(red: 0.78, green: 0.91, blue: 0.78) : Color(red: 0.12, green: 0.20, blue: 0.14)
    }

    private var displayBackground: Color {
        colorScheme == .dark ? Color(red: 0.08, green: 0.13, blue: 0.11) : Color(red: 0.82, green: 0.88, blue: 0.80)
    }

    private var title: String {
        if model.isSourceTimePreview { return "Source Time" }
        if !model.listening.usesProductionMix { return "Source Audition Time" }
        return clock.title
    }

    private var displayed: String {
        do {
            guard let seconds = try model.displayClockSeconds(at: model.waveformPlayheadSeconds, clock: clock) else {
                return "Unavailable"
            }

            return EpisodeTimeDisplay.format(seconds)
        } catch { return "Unavailable" }
    }

    private var additionalReadout: String? {
        guard model.listening.usesProductionMix else { return nil }
        var values: [String] = []
        if let secondary = configuration.secondaryClock {
            do {
                let value = try model.displayClockSeconds(at: model.waveformPlayheadSeconds, clock: secondary)
                values.append(secondary.title + " " + (value.map(EpisodeTimeDisplay.format) ?? "Unavailable"))
            } catch { values.append(secondary.title + " Unavailable") }
        }
        let duration = model.audioEditor.production?.episodeFrames.map { Double($0.count) / 48_000 }
        switch configuration.readout {
        case .none: break
        case .duration:
            values.append("Duration " + (duration.map(EpisodeTimeDisplay.format) ?? "Unavailable"))
        case .remaining:
            do {
                let position = try model.displayClockSeconds(at: model.waveformPlayheadSeconds, clock: .episode)
                let remaining = duration.flatMap { end in position.map { max(0, end - $0) } }
                values.append("Remaining " + (remaining.map(EpisodeTimeDisplay.format) ?? "Unavailable"))
            } catch { values.append("Remaining Unavailable") }
        case .selection:
            let length = model.listening.selection.map { $0.upperBound - $0.lowerBound }
            values.append("Selection " + (length.map(EpisodeTimeDisplay.format) ?? "None"))
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 2) {
            Menu {
                Picker("Primary clock", selection: $clock) {
                    ForEach(EpisodeClock.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } label: {
                Text(title).font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!model.listening.usesProductionMix)
            .accessibilityIdentifier("ww.controlBar.clock")
            TextField(title, text: $draft)
                .font(.system(size: 21, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .textFieldStyle(.plain)
                .frame(width: 175)
                .focused($editing)
                .onSubmit { editing = false }
                .onChange(of: editing) { _, focused in
                    if !focused {
                        model.seekDisplayClock(draft, clock: clock)
                        draft = displayed
                    }
                }
                .accessibilityIdentifier("alignment.waveforms.playhead")
                .accessibilityLabel(title + ", hours minutes seconds and milliseconds")
            if let additionalReadout {
                Text(additionalReadout).font(.system(.caption2, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(width: 196)
                    .accessibilityIdentifier("ww.controlBar.readout")
            }
        }
        .frame(width: 196)
        .foregroundStyle(displayInk)
        .tint(displayInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(displayBackground, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.35))
                .overlay(alignment: .top) {
                    Rectangle().fill(.black.opacity(0.18)).frame(height: 1).padding(.horizontal, 5)
                }
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ww.controlBar.display")
        .help("Enter signed HH:MM:SS.mmm or seconds in the selected clock. Changing clocks never moves audio.")
        .onAppear { draft = displayed }
        .onChange(of: displayed) { _, value in if !editing { draft = value } }
    }
}
