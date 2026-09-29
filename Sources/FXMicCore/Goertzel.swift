import Foundation

public enum Goertzel {
    /// Power at `freq`, normalized so a full-scale sine returns 1.0 (0 dB).
    public static func power(_ x: [Float], sampleRate: Double, freq: Double) -> Float {
        let n = Float(x.count)
        guard n > 0 else { return 0 }
        let k = Float(freq / sampleRate) * n
        let w = 2 * Float.pi * k / n
        let c = 2 * cos(w)
        var s1: Float = 0, s2: Float = 0
        for v in x {
            let s0 = v + c * s1 - s2
            s2 = s1
            s1 = s0
        }
        let p = s1 * s1 + s2 * s2 - c * s1 * s2
        return max(0, p * 4 / (n * n))
    }

    public static func powerDb(_ x: [Float], sampleRate: Double, freq: Double) -> Float {
        let p = power(x, sampleRate: sampleRate, freq: freq)
        return p > 0 ? 10 * log10(p) : -160
    }
}
