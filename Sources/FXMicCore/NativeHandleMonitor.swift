import Foundation

/// Observations from the existing audio markers, never commands to an assistant.
public enum NativeHandleEvent: Equatable {
    case pressed
    case released
    case cancelSignal
}

/// A capture-only path for native subscription voice. No transcription, files or network.
/// Confine one instance to its capture queue and discard it when the input restarts.
public final class NativeHandleMonitor {
    private let detector: ChirpDetector
    private var held = false
    private var canceled = false

    public init(sampleRate: Double, hopSeconds: Double = 0.01,
                press: [Double] = [17000, 18500],
                release: [Double] = [14000, 15000],
                cancel: [Double] = [12000, 13000]) {
        detector = ChirpDetector(targets: [
            ToneTarget(name: "press", freqs: press),
            ToneTarget(name: "release", freqs: release),
            ToneTarget(name: "cancel", freqs: cancel),
        ], sampleRate: sampleRate, hopSeconds: hopSeconds)
    }

    public func process(_ samples: [Float]) -> [NativeHandleEvent] {
        var observations: [NativeHandleEvent] = []
        for event in detector.process(samples) {
            guard case .onset(let target, _, _) = event else { continue }
            switch target {
            case "press" where !held:
                held = true
                canceled = false
                observations.append(.pressed)
            case "release" where held:
                held = false
                canceled = false
                observations.append(.released)
            case "cancel" where held && !canceled:
                canceled = true
                observations.append(.cancelSignal)
            default: break
            }
        }
        return observations
    }
}
