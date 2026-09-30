import Foundation

/// Offline checks only. This file is deliberately excluded from the iPhone app target.
@main
struct ProbeSignalAccumulatorCheck {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func tone(_ frequencies: [Double], rate: Double, seconds: Double = 0.12) -> [Float] {
        let count = Int(seconds * rate)
        let fade = Int(0.005 * rate)
        return (0..<count).map { sample in
            let edge = min(1, Double(min(sample, count - sample - 1)) / Double(fade))
            return Float(frequencies.reduce(0) { $0 + 0.12 * sin(2 * .pi * $1 * Double(sample) / rate) } * edge)
        }
    }

    static func silence(_ seconds: Double, rate: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    static func feed(_ signal: [Float], sizes: [Int], into accumulator: ProbeSignalAccumulator) throws -> ProbeSignalSnapshot {
        var offset = 0
        var index = 0
        var last: ProbeSignalSnapshot?
        while offset < signal.count {
            let end = min(signal.count, offset + sizes[index % sizes.count])
            last = try accumulator.consume(Array(signal[offset..<end]))
            offset = end
            index += 1
        }
        require(last != nil, "test signal must contain frames")
        return last!
    }

    static func main() throws {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            let accumulator = try ProbeSignalAccumulator(sampleRate: rate)
            let signal = silence(0.1, rate: rate)
                + tone([17_000, 18_500], rate: rate)
                + silence(0.3, rate: rate)
                + tone([17_000, 18_500], rate: rate)  // Duplicate press must stay one gesture.
                + silence(0.3, rate: rate)
                + tone([12_000, 13_000], rate: rate)
                + silence(0.3, rate: rate)
                + tone([14_000, 15_000], rate: rate)
                + silence(0.2, rate: rate)
            let fragmented = try feed(signal, sizes: [1, 63, 1024, 7, 513, 2048, 119], into: accumulator)
            let reference = try feed(signal, sizes: [accumulator.hopFrames],
                                     into: ProbeSignalAccumulator(sampleRate: rate))
            require(fragmented.pressCount == 1 && fragmented.releaseCount == 1 && fragmented.cancelCount == 1,
                    "full marker gesture was not recovered at \(rate)")
            require(!fragmented.held, "release did not clear held state")
            require(fragmented.frames == UInt64(signal.count), "callback frames were lost or duplicated")
            require(fragmented.nonzeroSamples == UInt64(signal.filter { $0 != 0 }.count), "nonzero count is not real input")
            require(fragmented.pressCount == reference.pressCount && fragmented.releaseCount == reference.releaseCount,
                    "variable callbacks changed marker recognition")

            let fresh = try ProbeSignalAccumulator(sampleRate: rate)
            let releaseOnly = try feed(tone([14_000, 15_000], rate: rate) + silence(0.1, rate: rate),
                                       sizes: [1024, 200], into: fresh)
            require(releaseOnly.releaseCount == 0 && !releaseOnly.held, "a new run inherited held state")
        }

        let speech = try ProbeSignalAccumulator(sampleRate: 48_000)
        let ordinary = tone([200, 400, 800], rate: 48_000, seconds: 0.4)
            + silence(0.2, rate: 48_000) + tone([15_500, 16_500], rate: 48_000)
        let speechResult = try feed(ordinary, sizes: [323, 1024, 511], into: speech)
        require(speechResult.pressCount == 0 && speechResult.releaseCount == 0, "speech or legacy tap became a handle event")

        let invalid = try ProbeSignalAccumulator(sampleRate: 48_000)
        for bad in [[Float](), [.nan], [.infinity], [Float](repeating: 0, count: 32_769)] {
            do { _ = try invalid.consume(bad); fatalError("invalid buffer was accepted") }
            catch ProbeSignalError.invalidBuffer { }
        }
        let zero = try invalid.consume([Float](repeating: 0, count: 480))
        require(zero.callbacks == 1 && zero.frames == 480 && zero.nonzeroSamples == 0 && zero.levelDB == -160,
                "zero input or failed callbacks fabricated sample activity")
        for rate in [Double.nan, .infinity, 0, 16_000, 384_000] {
            do { _ = try ProbeSignalAccumulator(sampleRate: rate); fatalError("invalid sample rate was accepted") }
            catch ProbeSignalError.invalidSampleRate { }
        }
        print("Probe signal checks passed: variable callback sizes at 44.1/48/96 kHz, marker pairing, restart, silence and malformed buffers.")
    }
}
