import Foundation

/// An editing reference for pause-gated, unweighted RMS, not delivery loudness in LUFS.
public enum AutoInputGainTarget {
    public static let defaultDBFS: Double = -20
    public static let rangeDBFS: ClosedRange<Double> = -36 ... -12

    public static func isValid(_ value: Double) -> Bool {
        value.isFinite && rangeDBFS.contains(value)
    }
}
