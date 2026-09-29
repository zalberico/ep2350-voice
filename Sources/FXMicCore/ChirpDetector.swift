import Foundation

public struct ToneTarget {
    public let name: String
    public let freqs: [Double]
    /// Distance to the guard bins used as the noise reference.
    public let guardOffset: Double

    public init(name: String, freqs: [Double], guardOffset: Double = 600) {
        self.name = name
        self.freqs = freqs
        self.guardOffset = guardOffset
    }
}

public struct ChirpConfig {
    /// Weakest tone power that counts, in dB below full scale.
    public var minLevelDb: Float = -50
    /// Tone must beat the louder guard bin by this much.
    public var minSnrDb: Float = 12
    /// Consecutive hops that must qualify before an onset fires.
    public var minFrames = 4
    /// Hops the tone may drop out for without counting as released.
    public var dropTolerance = 2
    /// A tone held this long is a hold, not a tap.
    public var holdSeconds = 0.35
    /// A release within this long after the previous one extends the same tap group.
    public var tapWindowSeconds = 0.45
    public init() {}
}

public enum ChirpEvent {
    case onset(target: String, levelDb: Float, snrDb: Float)
    /// The tone has lasted `holdSeconds` and is still sounding.
    case hold(target: String)
    case release(target: String, seconds: Double)
    /// Short presses grouped by the tap window: 1 = single, 2 = double.
    case tap(target: String, count: Int)
}

/// Narrow-band tone burst detector with tap, double tap, and hold semantics.
public final class ChirpDetector {
    public let targets: [ToneTarget]
    public let config: ChirpConfig
    private let sampleRate: Double
    private let hopSeconds: Double

    private var run: [Int]
    private var miss: [Int]
    private var holdFired: [Bool]
    private var time: Double = 0
    private var lastRelease: Double?
    private var tapTarget: String?
    private var tapCount = 0

    /// True while any target tone is currently sounding.
    public private(set) var toneActive = false

    public init(targets: [ToneTarget], sampleRate: Double, hopSeconds: Double, config: ChirpConfig = ChirpConfig()) {
        self.targets = targets
        self.config = config
        self.sampleRate = sampleRate
        self.hopSeconds = hopSeconds
        run = Array(repeating: 0, count: targets.count)
        miss = Array(repeating: 0, count: targets.count)
        holdFired = Array(repeating: false, count: targets.count)
    }

    public func process(_ frame: [Float]) -> [ChirpEvent] {
        time += hopSeconds
        var events: [ChirpEvent] = []
        var anyActive = false
        let holdFrames = Int((config.holdSeconds / hopSeconds).rounded())

        for (i, target) in targets.enumerated() {
            var level = Float.greatestFiniteMagnitude
            var snr = Float.greatestFiniteMagnitude
            for f in target.freqs {
                let tone = Goertzel.powerDb(frame, sampleRate: sampleRate, freq: f)
                let lower = Goertzel.powerDb(frame, sampleRate: sampleRate, freq: f - target.guardOffset)
                let upper = Goertzel.powerDb(frame, sampleRate: sampleRate, freq: f + target.guardOffset)
                level = min(level, tone)
                snr = min(snr, tone - max(lower, upper))
            }
            let hit = level > config.minLevelDb && snr > config.minSnrDb

            if hit {
                miss[i] = 0
                run[i] += 1
                if run[i] == config.minFrames {
                    events.append(.onset(target: target.name, levelDb: level, snrDb: snr))
                }
                if run[i] == holdFrames, !holdFired[i] {
                    holdFired[i] = true
                    events.append(.hold(target: target.name))
                }
            } else if run[i] > 0 {
                miss[i] += 1
                if miss[i] > config.dropTolerance {
                    let frames = run[i] - miss[i] + 1
                    if frames >= config.minFrames {
                        let seconds = Double(frames) * hopSeconds
                        events.append(.release(target: target.name, seconds: seconds))
                        if !holdFired[i] {
                            if let last = lastRelease, tapTarget == target.name, time - last <= config.tapWindowSeconds {
                                tapCount += 1
                            } else {
                                if let previous = tapTarget, lastRelease != nil {
                                    events.append(.tap(target: previous, count: tapCount))
                                }
                                tapTarget = target.name
                                tapCount = 1
                            }
                            lastRelease = time
                        }
                    }
                    run[i] = 0
                    miss[i] = 0
                    holdFired[i] = false
                } else {
                    run[i] += 1
                }
            }
            if run[i] >= config.minFrames { anyActive = true }
        }
        toneActive = anyActive

        if let last = lastRelease, let target = tapTarget, time - last > config.tapWindowSeconds {
            events.append(.tap(target: target, count: tapCount))
            lastRelease = nil
            tapTarget = nil
            tapCount = 0
        }
        return events
    }
}
