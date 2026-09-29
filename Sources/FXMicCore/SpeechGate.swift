import Foundation

public struct GateConfig {
    /// Speech gate opens when RMS stays above this for `openFrames` hops.
    public var openDb: Float = -50
    /// Speech gate closes after RMS stays below this for `holdFrames` hops.
    public var closeDb: Float = -58
    public var openFrames = 3
    public var holdFrames = 70
    /// "Mic on" (handle squeezed) is the noise floor rising above digital silence.
    public var micOnDb: Float = -74
    public var micOnFrames = 5
    public var micOffFrames = 100
    public init() {}
}

public enum GateEvent {
    case micOn(levelDb: Float)
    case micOff
    case opened(levelDb: Float)
    case closed(frames: Int)
}

/// Two-stage energy gate: a slow "mic on" detector on the noise floor and a speech gate with hysteresis.
public final class SpeechGate {
    public let config: GateConfig
    public private(set) var isOpen = false
    public private(set) var micLive = false

    private var aboveOpen = 0
    private var belowClose = 0
    private var openFrameCount = 0
    private var aboveMic = 0
    private var belowMic = 0

    public init(config: GateConfig = GateConfig()) {
        self.config = config
    }

    /// Closes the speech gate immediately without emitting an event.
    public func forceClose() {
        isOpen = false
        aboveOpen = 0
        belowClose = 0
    }

    /// Opens the speech window without emitting an event (used when the handle, not the audio, defines the message).
    public func forceOpenSilently() {
        isOpen = true
        openFrameCount = 0
        belowClose = 0
    }

    /// Treats the handle as released right now; a continued squeeze re-triggers micOn after `micOnFrames`.
    public func forceRelease() {
        forceClose()
        micLive = false
        aboveMic = 0
        belowMic = 0
    }

    public func process(rmsDb: Float) -> [GateEvent] {
        var events: [GateEvent] = []

        if rmsDb > config.micOnDb { aboveMic += 1; belowMic = 0 } else { belowMic += 1; aboveMic = 0 }
        if !micLive, aboveMic >= config.micOnFrames {
            micLive = true
            events.append(.micOn(levelDb: rmsDb))
        } else if micLive, belowMic >= config.micOffFrames {
            micLive = false
            events.append(.micOff)
        }

        if !isOpen {
            if rmsDb > config.openDb { aboveOpen += 1 } else { aboveOpen = 0 }
            if aboveOpen >= config.openFrames {
                isOpen = true
                openFrameCount = aboveOpen
                belowClose = 0
                events.append(.opened(levelDb: rmsDb))
            }
        } else {
            openFrameCount += 1
            if rmsDb < config.closeDb { belowClose += 1 } else { belowClose = 0 }
            if belowClose >= config.holdFrames {
                isOpen = false
                aboveOpen = 0
                events.append(.closed(frames: openFrameCount))
            }
        }
        return events
    }
}
