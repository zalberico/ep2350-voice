import Foundation

/// Reads the handle from a pilot tone the mic plays whose level follows the squeeze.
/// The released level is learned as the running minimum; squeezed is a few dB above it.
public final class PilotDetector {
    public struct Reading {
        public let present: Bool
        public let levelDb: Float
        public let referenceDb: Float
        public let squeezed: Bool
        public let pressed: Bool     // squeeze began this frame
        public let released: Bool    // squeeze ended this frame (or the pilot vanished mid-squeeze)
        public let power: Float      // linear power of the pilot, for subtracting it from the speech energy
    }

    public let freq: Double
    private let sampleRate: Double
    private let hopSeconds: Double
    private let guardOffset: Double
    private let minLevelDb: Float
    private let minSnrDb: Float
    private let onDeltaDb: Float
    private let offDeltaDb: Float
    private let confirmFrames: Int
    private let absentFrames: Int

    private var presentRun = 0
    private var absentRun = 0
    private var smoothed: Float = -120
    private var reference: Float = 0
    private var haveReference = false
    private var squeezeRun = 0
    private var releaseRun = 0
    public private(set) var present = false
    public private(set) var squeezed = false

    public init(freq: Double, sampleRate: Double, hopSeconds: Double, guardOffset: Double = 600,
                minLevelDb: Float = -65, minSnrDb: Float = 10, onDeltaDb: Float = 5, offDeltaDb: Float = 3,
                confirmFrames: Int = 5, absentFrames: Int = 30) {
        self.freq = freq
        self.sampleRate = sampleRate
        self.hopSeconds = hopSeconds
        self.guardOffset = guardOffset
        self.minLevelDb = minLevelDb
        self.minSnrDb = minSnrDb
        self.onDeltaDb = onDeltaDb
        self.offDeltaDb = offDeltaDb
        self.confirmFrames = confirmFrames
        self.absentFrames = absentFrames
    }

    public func process(_ frame: [Float]) -> Reading {
        let power = Goertzel.power(frame, sampleRate: sampleRate, freq: freq)
        let level = power > 0 ? 10 * log10(power) : -160
        let lower = Goertzel.powerDb(frame, sampleRate: sampleRate, freq: freq - guardOffset)
        let upper = Goertzel.powerDb(frame, sampleRate: sampleRate, freq: freq + guardOffset)
        let hit = level > minLevelDb && level - max(lower, upper) > minSnrDb

        var pressed = false
        var released = false

        if hit { presentRun += 1; absentRun = 0 } else { absentRun += 1; presentRun = 0 }
        if !present, presentRun >= confirmFrames {
            present = true
            smoothed = level
            reference = level
            haveReference = true
        } else if present, absentRun >= absentFrames {
            present = false
            if squeezed { squeezed = false; released = true }
            squeezeRun = 0
            releaseRun = 0
        }

        if present, hit {
            smoothed += (level - smoothed) * 0.35
            if !squeezed {
                // The released level is the floor; follow it down at once and up slowly (about 1 dB per second).
                if smoothed < reference { reference = smoothed } else { reference += Float(hopSeconds) * 1.0 }
            }
            let delta = smoothed - reference
            if !squeezed {
                squeezeRun = delta > onDeltaDb ? squeezeRun + 1 : 0
                if squeezeRun >= confirmFrames { squeezed = true; pressed = true; releaseRun = 0 }
            } else {
                releaseRun = delta < offDeltaDb ? releaseRun + 1 : 0
                if releaseRun >= confirmFrames { squeezed = false; released = true; squeezeRun = 0 }
            }
        }

        return Reading(present: present, levelDb: smoothed, referenceDb: haveReference ? reference : -160,
                       squeezed: squeezed, pressed: pressed, released: released, power: hit ? power : 0)
    }
}
