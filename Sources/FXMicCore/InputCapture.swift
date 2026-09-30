import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

public enum CaptureError: Error, CustomStringConvertible {
    case noAudioUnit
    case setDevice(OSStatus)
    case start(Error)
    case wrongDevice(AudioDeviceID)
    case captureDeviceUnavailable(String)
    case sessionConfiguration(String)
    case sessionStartFailed
    case invalidInputFormat

    public var description: String {
        switch self {
        case .noAudioUnit: return "input node has no audio unit"
        case .setDevice(let s): return "could not select the device (OSStatus \(s))"
        case .start(let e): return "engine start failed: \(e)"
        case .wrongDevice(let id): return "capture is bound to device \(id) instead of the requested input"
        case .captureDeviceUnavailable(let uid): return "selected audio device is unavailable to AVCapture (UID \(uid))"
        case .sessionConfiguration(let message): return "capture session configuration failed: \(message)"
        case .sessionStartFailed: return "selected-device capture session did not start"
        case .invalidInputFormat: return "selected audio device has an invalid native PCM format"
        }
    }
}

/// A snapshot of actual callbacks and decoded audio, distinct from engine.isRunning.
public struct CaptureDiagnostics {
    public let rawCallbackCount: UInt64
    public let rawFrameCount: UInt64
    public let usableHopCount: UInt64
    public let lastBufferFormat: String?
    /// Seconds since the most recent raw callback, or nil if none has arrived.
    public let inputCallbackAge: TimeInterval?
    public let lastDecodeError: String?
}

private struct CaptureBufferFormat {
    let commonFormat: AVAudioCommonFormat
    let sampleRate: Double
    let channels: AVAudioChannelCount
    let interleaved: Bool
    let stride: Int

    var summary: String {
        let name: String
        switch commonFormat {
        case .pcmFormatFloat32: name = "Float32"
        case .pcmFormatFloat64: name = "Float64"
        case .pcmFormatInt16: name = "Int16"
        case .pcmFormatInt32: name = "Int32"
        default: name = "format \(commonFormat.rawValue)"
        }
        return "\(name), \(sampleRate) Hz, \(channels) ch, \(interleaved ? "interleaved" : "planar"), stride \(stride)"
    }
}

/// Input-only capture from one exact device. No playback node or default output is used.
public final class InputCapture {
    public let device: AudioInputDevice
    public private(set) var setupFormatDescription = ""
    public private(set) var sampleRate: Double = 0
    public private(set) var hop: Int = 480
    public private(set) var startedAt = Date.distantPast

    private let session = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let captureInput: AVCaptureDeviceInput
    private let controlQueue = DispatchQueue(label: "fxmic.capture.control")
    private let queue = DispatchQueue(label: "fxmic.capture")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let onHop: ([Float]) -> Void
    private var delegate: CaptureSampleDelegate?
    private var observers: [NSObjectProtocol] = []
    // controlQueue owns session configuration and generation creation.
    private var generation: UInt64 = 0
    // queue owns processing, acceptance, and all diagnostics.
    private var activeGeneration: UInt64?
    private var failureReported = false
    private var pending: [Float] = []
    private var _lastHopAt = Date()
    private var rawCallbackCount: UInt64 = 0
    private var rawFrameCount: UInt64 = 0
    private var usableHopCount: UInt64 = 0
    private var lastCallbackAt: Date?
    private var lastBufferFormat: CaptureBufferFormat?
    private var lastDecodeError: String?

    /// Called on main when the session stops unexpectedly or its format changes.
    public var onStopped: ((String) -> Void)?
    public var lastHopAt: Date { processingSync { _lastHopAt } }
    public var isRunning: Bool { session.isRunning }
    public var diagnostics: CaptureDiagnostics {
        processingSync {
            CaptureDiagnostics(rawCallbackCount: rawCallbackCount, rawFrameCount: rawFrameCount,
                usableHopCount: usableHopCount, lastBufferFormat: lastBufferFormat?.summary,
                inputCallbackAge: lastCallbackAt.map { max(0, Date().timeIntervalSince($0)) },
                lastDecodeError: lastDecodeError)
        }
    }

    public init(device: AudioInputDevice, hopSeconds: Double = 0.010,
                configureBufferSize: Bool = true, onHop: @escaping ([Float]) -> Void) throws {
        self.device = device
        self.onHop = onHop
        // Keep the argument for callers; AVCapture chooses its own delivery buffer size.
        // In particular, it never mutates the hardware buffer size or default output.
        _ = configureBufferSize
        guard !device.uid.isEmpty,
              let selected = AVCaptureDevice(uniqueID: device.uid),
              selected.uniqueID == device.uid, selected.hasMediaType(.audio) else {
            throw CaptureError.captureDeviceUnavailable(device.uid)
        }
        captureInput = try AVCaptureDeviceInput(device: selected)
        queue.setSpecific(key: queueKey, value: 1)
        try controlQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(captureInput) else {
                throw CaptureError.sessionConfiguration("cannot add the selected audio input")
            }
            session.addInput(captureInput)
            guard session.canAddOutput(audioOutput) else {
                throw CaptureError.sessionConfiguration("cannot add the audio data output")
            }
            // nil requests the selected device's native format on macOS.
            audioOutput.audioSettings = nil
            session.addOutput(audioOutput)
        }
        guard let format = CMAudioFormatDescriptionGetStreamBasicDescription(selected.activeFormat.formatDescription),
              format.pointee.mFormatID == kAudioFormatLinearPCM,
              format.pointee.mSampleRate.isFinite, format.pointee.mSampleRate > 0,
              format.pointee.mChannelsPerFrame > 0,
              hopSeconds.isFinite, hopSeconds > 0,
              format.pointee.mSampleRate * hopSeconds < Double(Int.max) else {
            throw CaptureError.invalidInputFormat
        }
        sampleRate = format.pointee.mSampleRate
        hop = max(1, Int((sampleRate * hopSeconds).rounded()))
        setupFormatDescription = "AVCapture exact selected input; device nominal \(device.sampleRate) Hz; native input \(sampleRate) Hz / \(format.pointee.mChannelsPerFrame) ch / \(format.pointee.mBitsPerChannel)-bit; no playback output"
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        // Do not wait for the callback queue from a possible callback-thread deinit.
        let output = audioOutput
        let capturedSession = session
        controlQueue.async {
            output.setSampleBufferDelegate(nil, queue: nil)
            capturedSession.stopRunning()
        }
    }

    /// Synchronous lifecycle API; call from the host thread, not from onHop.
    public func start() throws {
        try controlQueue.sync {
            guard !session.isRunning else { return }
            generation &+= 1
            let token = generation
            processingSync {
                activeGeneration = token
                failureReported = false
                pending.removeAll(keepingCapacity: true)
                rawCallbackCount = 0; rawFrameCount = 0; usableHopCount = 0
                lastCallbackAt = nil; lastBufferFormat = nil; lastDecodeError = nil
                _lastHopAt = Date() // Startup grace only; readiness uses usableHopCount.
            }
            let proxy = CaptureSampleDelegate(owner: self, generation: token)
            delegate = proxy
            audioOutput.setSampleBufferDelegate(proxy, queue: queue)
            installObservers(generation: token)
            session.startRunning()
            guard session.isRunning else {
                stopOnControlQueue()
                throw CaptureError.sessionStartFailed
            }
            startedAt = Date()
        }
    }

    /// Exact AVCapture UID binding, never a fallback to the system default input.
    public func boundDeviceID() -> AudioDeviceID? {
        captureInput.device.uniqueID == device.uid && captureInput.device.isConnected ? device.id : nil
    }

    public func stop() {
        controlQueue.sync { stopOnControlQueue() }
        onStopped = nil
    }

    private func stopOnControlQueue() {
        // Invalidate before stopping so already queued delegates cannot deliver old audio.
        processingSync { activeGeneration = nil; pending.removeAll(keepingCapacity: true) }
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        session.stopRunning()
        delegate = nil
    }

    public func sync(_ block: () -> Void) { processingSync(block) }

    private func processingSync<T>(_ block: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try block() }
        return try queue.sync(execute: block)
    }

    private func installObservers(generation: UInt64) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = [AVCaptureSession.runtimeErrorNotification,
                     AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.didStopRunningNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] note in
                let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
                    ?? "selected-device capture stopped or was interrupted"
                self?.queue.async { [weak self] in self?.reportFailure(detail, generation: generation) }
            }
        }
    }

    // Only called on queue. A dispatched error is checked again before reaching the host.
    private func reportFailure(_ reason: String, generation: UInt64) {
        guard activeGeneration == generation, !failureReported else { return }
        failureReported = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.processingSync({ self.activeGeneration == generation }) else { return }
            self.onStopped?(reason)
        }
    }

    fileprivate func ingest(_ sample: CMSampleBuffer, generation: UInt64) {
        guard activeGeneration == generation else { return }
        let receivedAt = Date()
        let frames = CMSampleBufferGetNumSamples(sample)
        rawCallbackCount &+= 1
        rawFrameCount &+= UInt64(max(0, frames))
        lastCallbackAt = receivedAt
        do {
            // Copy before the delegate returns; no borrowed sample memory escapes this call.
            let buffer = try SampleBufferPCMDecoder.copyPCM(sample)
            lastBufferFormat = CaptureBufferFormat(commonFormat: buffer.format.commonFormat,
                sampleRate: buffer.format.sampleRate, channels: buffer.format.channelCount,
                interleaved: buffer.format.isInterleaved, stride: buffer.stride)
            guard abs(buffer.format.sampleRate - sampleRate) < 0.5 else {
                let reason = "input sample rate changed from \(sampleRate) to \(buffer.format.sampleRate) Hz"
                lastDecodeError = reason
                reportFailure(reason, generation: generation)
                return
            }
            let mono = try PCMBufferDecoder.mono(buffer)
            guard !mono.isEmpty else { return }
            lastDecodeError = nil
            pending.append(contentsOf: mono)
            while pending.count >= hop {
                let chunk = Array(pending[0..<hop])
                pending.removeFirst(hop)
                _lastHopAt = receivedAt
                usableHopCount &+= 1
                onHop(chunk)
            }
        } catch {
            lastDecodeError = String(describing: error)
            reportFailure("input PCM decode failed: \(error)", generation: generation)
        }
    }
}

/// Each start gets a fresh proxy, so stale queued callbacks carry their original generation.
private final class CaptureSampleDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private weak var owner: InputCapture?
    private let generation: UInt64

    init(owner: InputCapture, generation: UInt64) {
        self.owner = owner
        self.generation = generation
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        owner?.ingest(sampleBuffer, generation: generation)
    }
}
