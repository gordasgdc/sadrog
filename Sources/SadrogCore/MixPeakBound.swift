import Foundation

/// Conservative upper bound of the mixed peak (linear), shared by the editor and its tests.
/// A1 plays one main clip at a time (two while a dissolve overlaps): the bound takes the LOUDEST recording, doubled when the montage has dissolves.
/// A2 items may overlap anything, so their peaks are added; the mix volume applies last.
public enum MixPeakBound {
    public static func linear(perRecording: [Double], dissolves: Bool, layers: Double, masterLinear: Double) -> Double {
        let a1 = (perRecording.max() ?? 0) * (dissolves ? 2 : 1)
        return (a1 + layers) * masterLinear
    }
}
