import Foundation

struct ProbeSignalSnapshot: Sendable {
    let callbacks: UInt64
    let frames: UInt64
    let nonzeroSamples: UInt64
    let levelDB: Float
    let held: Bool
    let pressCount: UInt64
    let releaseCount: UInt64
    let cancelCount: UInt64
}

enum ProbeSignalError: Error {
    case invalidSampleRate, invalidBuffer
}

/// Pure, queue-confined live sample accumulator. No I/O, simulated samples, or audio storage.
/// At most one incomplete 10 ms hop is retained after each callback.
final class ProbeSignalAccumulator {
    let sampleRate: Double
    let hopFrames: Int
    private let monitor: NativeHandleMonitor
    private var pending: [Float] = []
    private var callbacks: UInt64 = 0
    private var frames: UInt64 = 0
    private var nonzeroSamples: UInt64 = 0
    private var held = false
    private var pressCount: UInt64 = 0
    private var releaseCount: UInt64 = 0
    private var cancelCount: UInt64 = 0

    init(sampleRate: Double) throws {
        // Highest marker plus guard bin is 19.1 kHz. Reject rates that cannot carry it.
        guard sampleRate.isFinite, sampleRate >= 40_000, sampleRate <= 192_000 else {
            throw ProbeSignalError.invalidSampleRate
        }
        self.sampleRate = sampleRate
        hopFrames = max(1, Int((sampleRate * 0.010).rounded()))
        monitor = NativeHandleMonitor(sampleRate: sampleRate, hopSeconds: Double(hopFrames) / sampleRate)
    }

    func consume(_ mono: [Float]) throws -> ProbeSignalSnapshot {
        guard !mono.isEmpty, mono.count <= 32_768, mono.allSatisfy(\.isFinite) else {
            throw ProbeSignalError.invalidBuffer
        }
        callbacks &+= 1
        frames &+= UInt64(mono.count)
        nonzeroSamples &+= UInt64(mono.lazy.filter { $0 != 0 }.count)
        pending.append(contentsOf: mono)
        var cursor = 0
        while cursor + hopFrames <= pending.count {
            for event in monitor.process(Array(pending[cursor..<(cursor + hopFrames)])) {
                switch event {
                case .pressed: held = true; pressCount &+= 1
                case .released: held = false; releaseCount &+= 1
                case .cancelSignal: cancelCount &+= 1
                }
            }
            cursor += hopFrames
        }
        if cursor > 0 { pending.removeFirst(cursor) }
        return ProbeSignalSnapshot(callbacks: callbacks, frames: frames, nonzeroSamples: nonzeroSamples,
            levelDB: Levels.rmsDb(mono), held: held, pressCount: pressCount,
            releaseCount: releaseCount, cancelCount: cancelCount)
    }
}
