import AVFoundation
import CoreAudio
import Foundation

public enum CaptureError: Error, CustomStringConvertible {
    case noAudioUnit
    case setDevice(OSStatus)
    case start(Error)
    case wrongDevice(AudioDeviceID)

    public var description: String {
        switch self {
        case .noAudioUnit: return "input node has no audio unit"
        case .setDevice(let s): return "could not select the device (OSStatus \(s))"
        case .start(let e): return "engine start failed: \(e)"
        case .wrongDevice(let id): return "engine came up bound to device \(id) instead of the requested input"
        }
    }
}

/// Pulls mono float audio from one specific input device (not the system default)
/// and delivers fixed-size hops on a private serial queue.
public final class InputCapture {
    public let device: AudioInputDevice
    public private(set) var sampleRate: Double = 0
    public private(set) var hop: Int = 480

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "fxmic.capture")
    private var pending: [Float] = []
    private let onHop: ([Float]) -> Void
    private var configObserver: NSObjectProtocol?
    private var _lastHopAt = Date()

    /// Called (on an arbitrary thread) when the engine stops on its own, e.g. the audio hardware was reconfigured.
    public var onStopped: ((String) -> Void)?
    /// When the last audio buffer arrived. CoreAudio delivers buffers continuously, silence included.
    public var lastHopAt: Date { queue.sync { _lastHopAt } }
    public var isRunning: Bool { engine.isRunning }

    public init(device: AudioInputDevice, hopSeconds: Double = 0.010, onHop: @escaping ([Float]) -> Void) throws {
        self.device = device
        self.onHop = onHop
        let input = engine.inputNode
        guard let unit = input.audioUnit else { throw CaptureError.noAudioUnit }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureError.setDevice(status) }
        AudioDevices.setBufferFrameSize(device.id, frames: 480)
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        hop = max(1, Int((format.sampleRate * hopSeconds).rounded()))
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(hop), format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        // AVAudioEngine stops itself when the hardware configuration changes (output device switch, unplug, sample
        // rate change). Without this the app would sit "armed" with no audio flowing.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            // Our own setup (device binding, buffer size) also fires this right after a start; that one is noise.
            if Date().timeIntervalSince(self.startedAt) < 1.0 { return }
            self.onStopped?("audio configuration changed")
        }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    public private(set) var startedAt = Date.distantPast

    public func start() throws {
        do { try engine.start() } catch { throw CaptureError.start(error) }
        startedAt = Date()
        queue.async { [self] in _lastHopAt = Date() }
        // After a hardware reconfiguration AVAudioEngine can come back on the system default input instead of the
        // device we bound. Audio then flows (from the wrong mic) and nothing else reveals it, so check explicitly.
        if let bound = boundDeviceID(), bound != device.id {
            engine.stop()
            throw CaptureError.wrongDevice(bound)
        }
    }

    /// The device the engine's input unit is actually connected to right now.
    public func boundDeviceID() -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr ? id : nil
    }

    public func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver); self.configObserver = nil }
        onStopped = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Runs `block` on the processing queue, after any hops already queued.
    public func sync(_ block: () -> Void) {
        queue.sync(execute: block)
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        if channels == 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: data[0], count: frames)
            }
        } else {
            let scale = 1 / Float(channels)
            for c in 0..<channels {
                let src = data[c]
                for i in 0..<frames { mono[i] += src[i] * scale }
            }
        }
        queue.async { [self] in
            _lastHopAt = Date()
            pending.append(contentsOf: mono)
            while pending.count >= hop {
                let chunk = Array(pending[0..<hop])
                pending.removeFirst(hop)
                onHop(chunk)
            }
        }
    }
}
