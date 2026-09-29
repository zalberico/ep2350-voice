import Foundation

public enum Levels {
    public static func rmsDb(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return -160 }
        var acc: Float = 0
        for v in x { acc += v * v }
        let rms = (acc / Float(x.count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }

    public static func peakDb(_ x: [Float]) -> Float {
        var peak: Float = 0
        for v in x { peak = max(peak, abs(v)) }
        return peak > 0 ? 20 * log10(peak) : -160
    }
}
