import AVFoundation
import Combine
import Foundation
import UIKit

/// Diagnostic probe only. Session mixing is a request, not proof that Remote can
/// share this microphone. No playback, network requests, transcription or recordings.
@MainActor
final class ProbeCapture: ObservableObject {
    @Published private(set) var status = "Stopped. Connect the Sonos USB input, then start a test."
    @Published private(set) var route = "No active probe route"
    @Published private(set) var capturedRoute = "No capture in this test"
    @Published private(set) var sampleRate: Double = 0
    @Published private(set) var callbacks: UInt64 = 0
    @Published private(set) var frames: UInt64 = 0
    @Published private(set) var nonzeroSamples: UInt64 = 0
    @Published private(set) var levelDB: Float = -160
    @Published private(set) var held = false
    @Published private(set) var pressCount: UInt64 = 0
    @Published private(set) var releaseCount: UInt64 = 0
    @Published private(set) var cancelCount: UInt64 = 0
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var remainingSeconds = 0
    let runLimitSeconds = 90

    private let session = AVAudioSession.sharedInstance()
    private var requestID = UUID()
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var activationAttempted = false
    private var audioRun: ProbeAudioRun?
    private var observers: [NSObjectProtocol] = []
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var selectedUID: String?
    private var expiryWork: DispatchWorkItem?
    private var progressTimer: Timer?
    private var startedAt: TimeInterval = 0
    private var lastCallbackAt: TimeInterval = 0

    init() {
        updateRoute()
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.starting, !self.running else { return }
                    self.finish("Pending start canceled when the app entered the background. Retry explicitly.")
                }
            })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkAfterForegroundReturn() }
            })
    }

    func start() {
        guard !running, !starting else { return }
        requestID = UUID()
        let token = requestID
        starting = true
        status = "Checking microphone permission…"
        callbacks = 0; frames = 0; nonzeroSamples = 0
        pressCount = 0; releaseCount = 0; cancelCount = 0
        levelDB = -160; held = false; sampleRate = 0
        remainingSeconds = 0
        capturedRoute = "No capture in this test"
        updateRoute()
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            begin(token: token)
        case .denied:
            finish("Microphone permission is denied. Enable it in Settings before retrying.")
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == token, self.starting else { return }
                    if granted { self.begin(token: token) }
                    else { self.finish("Microphone permission was not granted.") }
                }
            }
        @unknown default:
            finish("Microphone permission is unavailable.")
        }
    }

    func stop() { finish("Stopped. Start again explicitly for another test.") }

    private func begin(token: UUID) {
        guard requestID == token, starting else { return }
        guard UIApplication.shared.applicationState != .background else {
            finish("Return to the app and start the test explicitly.")
            return
        }
        do {
            // No Bluetooth options, output overrides, preferred sample rate or IO-duration changes.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            activationAttempted = true
            try session.setActive(true)
            let inputs = (session.availableInputs ?? []).filter { $0.portType == .usbAudio }
            guard !inputs.isEmpty else { throw ProbeFailure("No USB audio input is available. The built-in microphone will not be used.") }
            let selected: AVAudioSessionPortDescription
            if let routed = session.currentRoute.inputs.first(where: { $0.portType == .usbAudio }),
               let available = inputs.first(where: { $0.uid == routed.uid }) {
                selected = available
            } else if inputs.count == 1 {
                selected = inputs[0]
            } else {
                throw ProbeFailure("More than one USB input is available. Select the intended input before retrying.")
            }
            try session.setPreferredInput(selected)
            guard Self.isExactUSBRoute(session.currentRoute, uid: selected.uid) else {
                throw ProbeFailure("iOS did not route the selected USB input. No fallback capture was started.")
            }
            let candidate = AVAudioEngine()
            let format = candidate.inputNode.outputFormat(forBus: 0)
            guard format.commonFormat == .pcmFormatFloat32, format.channelCount > 0,
                  format.channelCount <= 8 else {
                throw ProbeFailure("The USB input did not provide a supported Float32 audio format.")
            }
            let accumulator = try ProbeSignalAccumulator(sampleRate: format.sampleRate)
            let run = ProbeAudioRun(uid: selected.uid, rate: format.sampleRate, channels: format.channelCount,
                                    accumulator: accumulator, lifetime: TimeInterval(runLimitSeconds),
                                    publish: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == token, self.running else { return }
                    self.receive(snapshot)
                }
            }, fail: { [weak self] reason in
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == token else { return }
                    self.finish(reason)
                }
            })
            engine = candidate
            audioRun = run
            candidate.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [run] buffer, _ in
                run.consume(buffer)
            }
            tapInstalled = true
            try candidate.start()
            guard candidate.isRunning, Self.isExactUSBRoute(session.currentRoute, uid: selected.uid) else {
                throw ProbeFailure("The USB route changed during startup. Retry explicitly when the route is stable.")
            }
            sampleRate = format.sampleRate
            selectedUID = selected.uid
            startedAt = Date().timeIntervalSinceReferenceDate
            lastCallbackAt = startedAt
            running = true
            starting = false
            remainingSeconds = runLimitSeconds
            status = "USB capture started; waiting for real samples. Remote microphone sharing is unverified."
            updateRoute()
            capturedRoute = route  // Keep the measured route when Stop releases the session.
            observeRun(candidate, run: run, token: token)
            startTimers(run: run, token: token)
        } catch let error as ProbeFailure {
            finish(error.message)
        } catch ProbeSignalError.invalidSampleRate {
            finish("The input sample rate cannot carry the microphone's high-frequency markers.")
        } catch {
            finish("Could not start USB capture: \(error.localizedDescription)")
        }
    }

    private func receive(_ snapshot: ProbeSignalSnapshot) {
        callbacks = snapshot.callbacks
        frames = snapshot.frames
        nonzeroSamples = snapshot.nonzeroSamples
        levelDB = snapshot.levelDB
        held = snapshot.held
        pressCount = snapshot.pressCount
        releaseCount = snapshot.releaseCount
        cancelCount = snapshot.cancelCount
        lastCallbackAt = Date().timeIntervalSinceReferenceDate
        status = snapshot.nonzeroSamples == 0
            ? "Audio callbacks are arriving, but all monitored mono samples are zero."
            : "Real USB samples are arriving. Verify that Remote still hears you."
    }

    private func observeRun(_ engine: AVAudioEngine, run: ProbeAudioRun, token: UUID) {
        let center = NotificationCenter.default
        let reasons: [(Notification.Name, AnyObject?, String)] = [
            (AVAudioSession.interruptionNotification, session, "Audio session interrupted. Capture stopped; retry explicitly."),
            (AVAudioSession.routeChangeNotification, session, "Audio route changed. Capture stopped; retry explicitly."),
            (AVAudioSession.mediaServicesWereLostNotification, session, "Audio services were lost. Capture stopped."),
            (AVAudioSession.mediaServicesWereResetNotification, session, "Audio services restarted. Retry explicitly."),
            (.AVAudioEngineConfigurationChange, engine, "Audio configuration changed. Capture stopped; retry explicitly.")
        ]
        observers = reasons.map { name, object, reason in
            center.addObserver(forName: name, object: object, queue: nil) { [weak self, run] _ in
                run.invalidate()  // Stop accepting samples before a main-queue cleanup can run.
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == token else { return }
                    self.finish(reason)
                }
            }
        }
    }

    private func startTimers(run: ProbeAudioRun, token: UUID) {
        // Background audio permits a real lock-screen test; it is not an unlimited run.
        let expiry = DispatchWorkItem { [weak self, run] in
            run.invalidate()
            Task { @MainActor [weak self] in
                guard let self, self.requestID == token else { return }
                self.finish("The 90-second test ended. Capture released; retry explicitly.")
            }
        }
        expiryWork = expiry
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(runLimitSeconds), execute: expiry)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == token, self.running else { return }
                let now = Date().timeIntervalSinceReferenceDate
                self.remainingSeconds = min(self.runLimitSeconds, max(0, self.runLimitSeconds - Int(now - self.startedAt)))
                if now - self.startedAt >= TimeInterval(self.runLimitSeconds) {
                    self.finish("The 90-second test ended. Capture released; retry explicitly.")
                } else if now - self.lastCallbackAt > 5 {
                    self.finish("No audio samples arrived for five seconds. Capture released; retry explicitly.")
                }
            }
        }
    }

    private func checkAfterForegroundReturn() {
        guard running else { updateRoute(); return }
        let now = Date().timeIntervalSinceReferenceDate
        if now - startedAt >= TimeInterval(runLimitSeconds) {
            finish("The 90-second test expired while away. Capture released; retry explicitly.")
        } else if now - lastCallbackAt > 5 {
            finish("Capture did not remain active while away. Retry explicitly.")
        } else if let selectedUID, !Self.isExactUSBRoute(session.currentRoute, uid: selectedUID) {
            finish("The USB route changed while away. Retry explicitly.")
        }
    }

    private func finish(_ message: String) {
        requestID = UUID()  // Revoke permission and callback completions first.
        audioRun?.invalidate()
        audioRun = nil
        expiryWork?.cancel(); expiryWork = nil
        progressTimer?.invalidate(); progressTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        engine = nil
        tapInstalled = false
        selectedUID = nil
        held = false
        running = false
        starting = false
        remainingSeconds = 0
        levelDB = -160
        var releaseError: String?
        if activationAttempted {
            do { try session.setActive(false, options: [.notifyOthersOnDeactivation]) }
            catch { releaseError = error.localizedDescription }
        }
        activationAttempted = false
        updateRoute()
        status = releaseError.map { message + " Session release reported: " + $0 } ?? message
    }

    private func updateRoute() {
        let current = session.currentRoute
        let inputs = current.inputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        let outputs = current.outputs.map { "\($0.portName) [\($0.portType.rawValue)]" }.joined(separator: ", ")
        route = "Input: \(inputs.isEmpty ? "none" : inputs) · Output: \(outputs.isEmpty ? "none" : outputs) · Session: \(Int(session.sampleRate)) Hz"
    }

    nonisolated fileprivate static func isExactUSBRoute(_ route: AVAudioSessionRouteDescription, uid: String) -> Bool {
        route.inputs.count == 1 && route.inputs[0].portType == .usbAudio && route.inputs[0].uid == uid
    }

    isolated deinit {
        audioRun?.invalidate()
        expiryWork?.cancel()
        progressTimer?.invalidate()
        for observer in observers + lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        if activationAttempted { try? session.setActive(false, options: [.notifyOthersOnDeactivation]) }
    }
}

private struct ProbeFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Tap-queue state protected by one lock. No borrowed buffer escapes consume().
private final class ProbeAudioRun: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private let uid: String
    private let rate: Double
    private let channels: AVAudioChannelCount
    private let accumulator: ProbeSignalAccumulator
    private let deadline: TimeInterval
    private let wallDeadline: TimeInterval
    private var lastPublish: TimeInterval = -.infinity
    private var previousHeld = false
    private let publish: @Sendable (ProbeSignalSnapshot) -> Void
    private let fail: @Sendable (String) -> Void

    init(uid: String, rate: Double, channels: AVAudioChannelCount, accumulator: ProbeSignalAccumulator,
         lifetime: TimeInterval, publish: @escaping @Sendable (ProbeSignalSnapshot) -> Void,
         fail: @escaping @Sendable (String) -> Void) {
        self.uid = uid; self.rate = rate; self.channels = channels; self.accumulator = accumulator
        deadline = ProcessInfo.processInfo.systemUptime + lifetime
        wallDeadline = Date().timeIntervalSinceReferenceDate + lifetime
        self.publish = publish; self.fail = fail
    }

    func invalidate() { lock.lock(); accepting = false; lock.unlock() }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        var failure: String?
        var update: ProbeSignalSnapshot?
        if now >= deadline || Date().timeIntervalSinceReferenceDate >= wallDeadline {
            failure = "The bounded audio test ended. Capture released; retry explicitly."
        } else if !ProbeCapture.isExactUSBRoute(AVAudioSession.sharedInstance().currentRoute, uid: uid) {
            failure = "The selected USB input is no longer the actual input. Capture stopped without using a fallback."
        } else if buffer.format.commonFormat != .pcmFormatFloat32
                    || abs(buffer.format.sampleRate - rate) >= 0.5 || buffer.format.channelCount != channels {
            failure = "The input format changed. Capture stopped; retry explicitly."
        } else if buffer.frameLength > 0 {
            let count = Int(buffer.frameLength)
            if count > 32_768 || buffer.frameLength > buffer.frameCapacity || buffer.stride < 1 {
                failure = "The input delivered an invalid or oversized audio buffer."
            } else if let data = buffer.floatChannelData {
                var mono = [Float](repeating: 0, count: count)
                let scale = 1 / Float(channels)
                for channel in 0..<Int(channels) {
                    for frame in 0..<count { mono[frame] += data[channel][frame * buffer.stride] * scale }
                }
                do {
                    let snapshot = try accumulator.consume(mono)
                    // UI updates are limited to 10 Hz, except immediate handle-state changes.
                    if now - lastPublish >= 0.1 || snapshot.held != previousHeld {
                        update = snapshot
                        lastPublish = now
                    }
                    previousHeld = snapshot.held
                } catch {
                    failure = "The input delivered invalid PCM samples."
                }
            } else {
                failure = "The input audio data is unavailable."
            }
        }
        if failure != nil { accepting = false }
        lock.unlock()
        if let failure { fail(failure) }
        else if let update { publish(update) }
    }
}
