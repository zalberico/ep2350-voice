import Foundation

/// Reports the strongest narrow bins in a frequency range. Used to learn which control tones survive the signal path.
public final class BandScanner {
    public let freqs: [Double]
    private let sampleRate: Double

    public init(sampleRate: Double, from: Double = 12000, to: Double = 22000, step: Double = 500) {
        self.sampleRate = sampleRate
        freqs = stride(from: from, through: to, by: step).map { $0 }
    }

    public func scan(_ frame: [Float], thresholdDb: Float = -55, top: Int = 3) -> [(freq: Double, db: Float)]? {
        let bins = freqs.map { (freq: $0, db: Goertzel.powerDb(frame, sampleRate: sampleRate, freq: $0)) }
        guard let best = bins.max(by: { $0.db < $1.db }), best.db > thresholdDb else { return nil }
        return Array(bins.sorted { $0.db > $1.db }.prefix(top))
    }
}
