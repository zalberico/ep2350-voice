import AppKit
import AVFoundation
import FXMicCore
import SwiftUI

/// Configured before capture starts; subsequent state belongs to that capture's private queue.
private final class NativeMonitorBox {
    var monitor: NativeHandleMonitor?
    var held = false
    var meterLevel: Float = -60
    var meterDecayPerHop: Float = 1.5
    var lastMeterPush = -Double.infinity
}

/// Owns the audio pipeline, the transcriber, and the dispatch decisions.
/// Audio state is touched only on the capture queue; UI work is hopped to main.
final class AppController {
    enum State: String { case idle = "Idle", armed = "Armed", listening = "Listening" }

    private(set) var state: State = .idle {
        didSet { DispatchQueue.main.async { self.onStateChange?(); self.snapshot() } }
    }

    func snapshot() {
        let audio = capture?.diagnostics ?? lastCaptureDiagnostics
        Log.state([
            "state": state.rawValue,
            "device": deviceName ?? "",
            "transcriberReady": settings.nativeVoiceMode ? false : transcriberReady,
            "target": dispatcher.currentTarget?.title ?? "",
            "targetID": dispatcher.currentTarget?.id ?? "",
            "lastError": lastError ?? "",
            "micPermission": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
            "handleMode": handleMode,
            "composerDelivery": settings.composerDelivery,
            "shakeToCancel": settings.shakeToCancel,
            "captureRunning": capture?.isRunning ?? false,
            "audioCallbacks": audio?.rawCallbackCount ?? 0,
            "audioFrames": audio?.rawFrameCount ?? 0,
            "audioUsableHops": audio?.usableHopCount ?? 0,
            "audioFormat": audio?.lastBufferFormat ?? "",
            "audioDecodeError": audio?.lastDecodeError ?? "",
            "audioDiagnosticsFromStoppedCapture": capture == nil && lastCaptureDiagnostics != nil,
            "nativeAudioReady": nativeAudioReady,
            "nativeVoiceMode": settings.nativeVoiceMode,
            "nativeVoiceProvider": settings.nativeVoiceProvider,
            "nativePlaybackControl": "unavailable",
            "accessibilityTrusted": ComposerDelivery.isTrusted,
        ])
    }
    var onStateChange: (() -> Void)?
    var onActivity: ((StatusMenu.Activity) -> Void)?
    var onRecentChange: (() -> Void)?

    let settings = Settings.shared
    let hud = HUDController()
    let dispatcher = Dispatcher()
    let voiceBridge = VoiceBridge(suspended: Settings.shared.nativeVoiceMode)
    private let activity = ActivityWatcher()
    private(set) var recent: [(date: Date, text: String, outcome: String)] = []
    private(set) var lastError: String?
    var deviceName: String? { capture?.device.name }
    var transcriberReady: Bool { transcriber != nil }

    // Pipeline state, capture queue only.
    private var capture: InputCapture?
    private var lastCaptureDiagnostics: CaptureDiagnostics?
    private var gate = SpeechGate()
    private var chirps: ChirpDetector?
    private var handleMode = false          // true while an utterance was opened by a press marker: only the release marker ends it
    private var sampleRate: Double = 48000
    private var hopSeconds = 0.010
    private var preroll: [[Float]] = []
    private var speechFrames = 0
    private var openFrames = 0
    private var utterancePeak: Float = -160
    private var chirpDuringUtterance = false
    private var lastSpeechChirp = Date.distantPast
    private var canceled = false
    private var utteranceSerial = 0
    private var lastLevelPush = Date.distantPast
    private var meterLevel: Float = -60
    private var partials: [String: String] = [:]

    private let transcriberLock = NSLock()
    private var _transcriber: LiveTranscriber?
    private var transcriberStarting = false
    private var transcriber: LiveTranscriber? {
        transcriberLock.lock(); defer { transcriberLock.unlock() }
        return _transcriber
    }
    private func setTranscriber(_ t: LiveTranscriber?, starting: Bool) {
        transcriberLock.lock(); defer { transcriberLock.unlock() }
        if let t { _transcriber = t }
        transcriberStarting = starting
    }

    private var lastActivity = Date()
    private var idleTimer: Timer?
    private var pendingDeliveries = 0
    private var nativeCaptureID = UUID()
    private(set) var nativeAudioReady = false
    private var nativeRecoveryAttempts = 0
    private var nativeRequest: NativeActionToken?
    private var nativeRequestID = UUID()
    private(set) var nativeVoiceStatus = "Open the selected app and start its voice mode."
    var nativeProvider: NativeVoiceProvider {
        NativeVoiceProvider(rawValue: settings.nativeVoiceProvider) ?? .claude
    }

    // MARK: arm / idle

    init() {
        startSendFileWatcher()
    }

    private var lastToggle = Date.distantPast

    /// Called by the menu bar click and the hotkey. Ignores a second toggle within 600 ms (double-clicks).
    func toggleArmed(source: String) {
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.6 else { Log.write("toggle from \(source) ignored (debounce)"); return }
        lastToggle = now
        Log.write("toggle from \(source): \(state == .idle ? "pick up" : "hang up")")
        state == .idle ? arm() : disarm(reason: "hung up via \(source)")
    }

    func arm() {
        guard state == .idle else { return }
        lastCaptureDiagnostics = nil
        nativeRecoveryAttempts = 0
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            Log.write("waiting for microphone permission")
            snapshot()
            hud.flash("Microphone permission", detail: "Click Allow in the macOS dialog, then FXMic starts listening.", tint: .blue, icon: "mic.badge.plus", seconds: 6)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self.arm() } else { self.lastError = "Microphone access denied"; self.onStateChange?() }
                }
            }
            return
        case .denied, .restricted:
            lastError = "Microphone access denied. Allow FXMic in System Settings > Privacy & Security > Microphone."
            Log.write(lastError!)
            snapshot()
            hud.flash("Microphone access denied", detail: "System Settings > Privacy & Security > Microphone > FXMic", tint: .red, icon: "mic.slash", seconds: 4)
            onStateChange?()
            return
        default:
            break
        }
        guard let device = AudioDevices.find(settings.deviceQuery) else {
            lastError = "No input device matching \(settings.deviceQuery)"
            Log.write("no input device matching \(settings.deviceQuery)")
            hud.flash("Mic not found", detail: settings.deviceQuery, tint: .red, icon: "exclamationmark.triangle", seconds: 2.5)
            onStateChange?()
            return
        }
        do {
            try startCapture(device: device)
            Log.write("armed on \(device.name) at \(Int(sampleRate)) Hz")
            lastError = nil
            lastActivity = Date()
            state = .armed
            if !settings.nativeVoiceMode { ensureTranscriber() }
            startIdleTimer()
            startHeartbeat()
            if !settings.nativeVoiceMode, settings.composerDelivery { ComposerDelivery.warmUp() }
        } catch {
            lastError = "\(error)"
            Log.write("audio error: \(error)")
            hud.flash("Audio error", detail: "\(error)", tint: .red, icon: "exclamationmark.triangle", seconds: 3)
            onStateChange?()
        }
    }

    /// Opens the input and builds the detectors for it. Used by arm() and by recovery.
    private func startCapture(device: AudioInputDevice) throws {
        if settings.nativeVoiceMode {
            try startNativeCapture(device: device)
            return
        }
        let token = UUID()
        nativeCaptureID = token
        var config = GateConfig()
        config.openDb = settings.openDb
        config.closeDb = settings.closeDb
        config.openFrames = 5        // 50 ms of sustained energy starts a message; bumps and chirps do not count
        config.holdFrames = 60
        gate = SpeechGate(config: config)
        preroll = []
        let cap = try InputCapture(device: device) { [weak self] frame in self?.process(frame) }
        sampleRate = cap.sampleRate
        hopSeconds = Double(cap.hop) / cap.sampleRate
        chirps = ChirpDetector(targets: [
            ToneTarget(name: "tap", freqs: settings.chirpFreqs),
            ToneTarget(name: "press", freqs: settings.pressFreqs),
            ToneTarget(name: "release", freqs: settings.releaseFreqs),
            ToneTarget(name: "cancel", freqs: settings.cancelFreqs),
        ], sampleRate: sampleRate, hopSeconds: hopSeconds)
        handleMode = false
        cap.onStopped = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, self.nativeCaptureID == token else { return }
                self.recover(reason: reason)
            }
        }
        try cap.start()
        capture = cap
    }

    /// Monitor marker tones without creating a transcriber or delivering speech anywhere.
    private func startNativeCapture(device: AudioInputDevice) throws {
        nativeAudioReady = false
        let token = UUID()
        nativeCaptureID = token
        let box = NativeMonitorBox()
        let cap = try InputCapture(device: device, configureBufferSize: false) { [weak self, box] frame in
            let events = box.monitor?.process(frame) ?? []
            for event in events {
                switch event {
                case .pressed:
                    box.held = true
                    box.meterLevel = -60
                    box.lastMeterPush = -Double.infinity
                case .released:
                    box.held = false
                case .cancelSignal:
                    break
                }
            }
            var level: Float?
            if box.held {
                // Local input only: instant attack, 150 dB/s release, at most 30 UI updates/s.
                box.meterLevel = max(Levels.rmsDb(frame), box.meterLevel - box.meterDecayPerHop)
                let now = ProcessInfo.processInfo.systemUptime
                if now - box.lastMeterPush >= 1.0 / 30.0 {
                    box.lastMeterPush = now
                    level = box.meterLevel
                }
            }
            guard !events.isEmpty || level != nil else { return }
            DispatchQueue.main.async { [weak self, level] in
                guard let self, self.nativeCaptureID == token,
                      self.settings.nativeVoiceMode, self.state != .idle else { return }
                if !events.isEmpty { self.lastActivity = Date() }
                for event in events {
                    switch event {
                    case .pressed:
                        Log.write("native handle pressed")
                        self.state = .listening
                        self.hud.handleHeld()
                    case .released:
                        Log.write("native handle released")
                        self.state = .armed
                        self.hud.handleReleased()
                    case .cancelSignal:
                        Log.write("native handle cancel marker")
                        // Native voice may already have heard the audio; never claim it was discarded.
                        self.hud.flash("Shake detected", tint: .gray, icon: "hand.raised", seconds: 0.8)
                    }
                }
                if let level, self.state == .listening { self.hud.model.level = level }
            }
        }
        sampleRate = cap.sampleRate
        Log.write("native capture setup: \(cap.setupFormatDescription)")
        box.monitor = NativeHandleMonitor(sampleRate: cap.sampleRate,
            hopSeconds: Double(cap.hop) / cap.sampleRate,
            press: settings.pressFreqs, release: settings.releaseFreqs, cancel: settings.cancelFreqs)
        box.meterDecayPerHop = Float(Double(cap.hop) / cap.sampleRate * 150)
        cap.onStopped = { [weak self] reason in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.nativeCaptureID == token else { return }
                self.recover(reason: reason)
            }
        }
        try cap.start()
        capture = cap
        handleMode = false
        // Recovery discards the previous detector's held state; do not leave a stale held HUD.
        if state != .idle { state = .armed; hud.hide() }
    }

    // MARK: recovery

    private var recovering = false
    private var heartbeat: Timer?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// The audio path died under us (jack reconfigured, device unplugged, engine stopped): reconnect, or hang up
    /// honestly if the device does not come back within a few seconds.
    private var lastRecoveryAt = Date.distantPast
    private var recoveriesInWindow = 0

    private func recover(reason: String) {
        guard state != .idle, !recovering else { return }
        if settings.nativeVoiceMode {
            nativeAudioReady = false
            // Drop queued observations from the failed stream and clear stale held feedback now.
            nativeCaptureID = UUID()
            state = .armed
            hud.hide()
            nativeRecoveryAttempts += 1
            lastError = "Waiting for usable audio from \(settings.deviceQuery)"
            if nativeRecoveryAttempts > 3 {
                lastError = "No usable audio from \(settings.deviceQuery). Input recovery stopped after three attempts."
                Log.write(lastError!)
                // Save the failed stream diagnostics before closing it.
                snapshot()
                disarm(reason: lastError)
                hud.flash("No input audio", tint: .red, icon: "mic.slash", seconds: 6)
                return
            }
        }
        recovering = true
        let recoveryCaptureID = nativeCaptureID
        // Backoff: a storm of interruptions (jack reconfiguring) gets a longer pause instead of a tight loop.
        if Date().timeIntervalSince(lastRecoveryAt) < 10 { recoveriesInWindow += 1 } else { recoveriesInWindow = 0 }
        lastRecoveryAt = Date()
        let delay: TimeInterval = recoveriesInWindow >= 3 ? 2.0 : 0.4
        Log.write("capture interrupted: \(reason); recovering in \(delay) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.nativeCaptureID == recoveryCaptureID else { return }
            guard self.state != .idle else { self.recovering = false; return }
            // Device gone (adapter or mic unplugged): hang up at once. The half-second delay above filters blips.
            guard let cap = self.capture, AudioDevices.exists(cap.device.id) else {
                self.recovering = false
                self.disarm(reason: "input device disconnected (\(self.settings.deviceQuery))")
                return
            }
            // Device still there: rebuild the capture on it. (Restarting the stopped engine is not enough: it can come
            // back bound to the default input, the built-in mic, and never hear the marker tones again.)
            self.capture?.stop()
            self.capture = nil
            if let device = AudioDevices.find(self.settings.deviceQuery) {
                do {
                    try self.startCapture(device: device)
                    self.recovering = false
                    Log.write("reconnected to \(device.name) at \(Int(self.sampleRate)) Hz")
                    self.snapshot()
                    return
                } catch {
                    Log.write("rebuild failed: \(error)")
                }
            }
            self.recovering = false
            self.disarm(reason: "input device unusable (\(self.settings.deviceQuery))")
        }
    }

    /// Every second: a capture that delivers no buffers, is not running, or is bound to another device is dead.
    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.state != .idle, !self.recovering, let cap = self.capture else { return }
            let diagnostics = cap.diagnostics
            if self.settings.nativeVoiceMode, diagnostics.usableHopCount > 0,
               Date().timeIntervalSince(cap.lastHopAt) <= 3 {
                if !self.nativeAudioReady {
                    self.nativeAudioReady = true
                    self.lastError = nil
                    Log.write("native feedback received usable audio: \(diagnostics.lastBufferFormat ?? "unknown format")")
                    self.onStateChange?()
                    self.snapshot()
                }
                if Date().timeIntervalSince(cap.startedAt) > 10 { self.nativeRecoveryAttempts = 0 }
            }
            if !cap.isRunning { self.recover(reason: "engine not running") }
            else if Date().timeIntervalSince(cap.lastHopAt) > 3 {
                self.recover(reason: "no usable audio for 3 s; callbacks=\(diagnostics.rawCallbackCount), frames=\(diagnostics.rawFrameCount), format=\(diagnostics.lastBufferFormat ?? "none"), decode=\(diagnostics.lastDecodeError ?? "none")")
            }
            else if let bound = cap.boundDeviceID(), bound != cap.device.id {
                let name = AudioDevices.inputs().first { $0.id == bound }?.name ?? "\(bound)"
                self.recover(reason: "engine drifted to \(name)")
            }
        }
        if deviceListener == nil {
            deviceListener = AudioDevices.onDeviceListChange { [weak self] in
                guard let self, self.state != .idle, !self.recovering, let cap = self.capture else { return }
                if !AudioDevices.exists(cap.device.id) { self.recover(reason: "input device disappeared") }
            }
        }
    }

    func disarm(reason: String? = nil) {
        nativeCaptureID = UUID()
        nativeAudioReady = false
        voiceBridge.cancel()
        guard state != .idle else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        heartbeat?.invalidate()
        heartbeat = nil
        recovering = false
        lastCaptureDiagnostics = capture?.diagnostics
        capture?.stop()
        capture?.sync {
            self.utteranceSerial += 1 // Invalidate a transcript still finishing asynchronously.
            self.canceled = true
        }
        capture = nil
        Log.write("idle" + (reason.map { ": \($0)" } ?? ""))
        state = .idle
        hud.hide()      // hanging up is silent: the menu bar handset shows the state
    }

    /// Keeps speech peaks between -20 and -4 dBFS by nudging the Sabrent's own input gain.
    private func autoTrim(peakDb: Float) {
        guard settings.autoGain, let device = capture?.device, let current = AudioDevices.inputVolume(device.id) else { return }
        var next = current
        if peakDb > -2 { next = current * 0.7 }
        else if peakDb > -4 { next = current * 0.85 }
        else if peakDb < -24 { next = min(1, current * 1.2 + 0.02) }
        guard abs(next - current) > 0.005 else { return }
        if AudioDevices.setInputVolume(device.id, next) {
            Log.write(String(format: "auto gain: peak %.1f dBFS, input gain %.0f%% -> %.0f%%", peakDb, current * 100, next * 100))
        }
    }

    private func startIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.state != .idle else { return }
            let limit = self.settings.idleMinutes * 60
            if limit > 0, self.state != .listening, !self.handleMode, Date().timeIntervalSince(self.lastActivity) > limit {   // never mid-message
                self.disarm(reason: "Idle after \(Int(self.settings.idleMinutes)) min")
            }
        }
    }

    private func ensureTranscriber() {
        transcriberLock.lock()
        let needed = _transcriber == nil && !transcriberStarting
        if needed { transcriberStarting = true }
        transcriberLock.unlock()
        guard needed else { return }
        let locales = settings.locales
        Task.detached { [self] in
            do {
                let t = try await LiveTranscriber(locales: locales) { [weak self] update in self?.handle(update) }
                setTranscriber(t, starting: false)
                Log.write("transcriber ready: \(locales.joined(separator: ","))")
                DispatchQueue.main.async {
                    guard !self.settings.nativeVoiceMode else { return }
                    self.onStateChange?(); self.snapshot()
                }
            } catch {
                setTranscriber(nil, starting: false)
                Log.write("transcriber failed: \(error)")
                DispatchQueue.main.async {
                    guard !self.settings.nativeVoiceMode else { return }
                    self.lastError = "Transcriber: \(error)"
                    self.hud.flash("Transcriber failed", detail: "\(error)", tint: .red, icon: "exclamationmark.triangle", seconds: 3)
                    self.onStateChange?()
                }
            }
        }
    }

    // MARK: audio pipeline (capture queue)

    private func process(_ frame: [Float]) {
        preroll.append(frame)
        if preroll.count > 20 { preroll.removeFirst() }

        let chirpEvents = chirps?.process(frame) ?? []
        let toneActive = chirps?.toneActive ?? false
        let rms = Levels.rmsDb(frame)

        // Handle markers from the mic's script: press opens the message, release sends it.
        for event in chirpEvents {
            guard case .onset(let target, _, _) = event else { continue }
            if target == "press" {
                lastActivity = Date()
                if !gate.isOpen { beginUtterance() }
                let voiceSerial = utteranceSerial
                DispatchQueue.main.async { self.voiceBridge.press(serial: voiceSerial) }
                handleMode = true
                gate.forceOpenSilently()
                Log.write("handle pressed")
            } else if target == "cancel", handleMode, settings.shakeToCancel {
                DispatchQueue.main.async { self.voiceBridge.cancel() }
                Log.write("shake: cancel")
                DispatchQueue.main.async { self.canceled = true; self.hud.canceled() }
            } else if target == "release", handleMode {
                DispatchQueue.main.async { self.voiceBridge.release() }
                Log.write("handle released")
                handleMode = false
                endUtterance(frames: openFrames)
                gate.forceClose()
            }
        }

        // The gate only tracks speech energy inside a squeeze. Speech without a press marker is ignored:
        // the handle is the only thing that starts or ends a message.
        for event in gate.process(rmsDb: toneActive ? -100 : rms) {
            if case .closed = event, handleMode { gate.forceOpenSilently() }
        }
        if !handleMode, gate.isOpen { gate.forceClose() }

        if handleMode, gate.isOpen {
            openFrames += 1
            if !toneActive, rms > gate.config.openDb {
                speechFrames += 1
                utterancePeak = max(utterancePeak, Levels.peakDb(frame))
            }
            transcriber?.feed(frame, sampleRate: sampleRate)
            // No time cap: a message ends only on the release marker or a shake.
            // Meter ballistics: instant attack, about 150 dB/s release, pushed to the HUD on every 10 ms hop.
            meterLevel = max(rms, meterLevel - 1.5)
            if !canceled, Date().timeIntervalSince(lastLevelPush) > 0.009 {   // a canceled squeeze shows no level
                lastLevelPush = Date()
                let shown = meterLevel
                DispatchQueue.main.async { self.hud.model.level = shown }
            }
        }

        for event in chirpEvents {
            switch event {
            case .onset(let target, _, _):
                // A tap while the handle is squeezed is always a cancel, spoken or not; never an app switch.
                if target == "tap", handleMode || gate.isOpen {
                    chirpDuringUtterance = true
                    lastSpeechChirp = Date()
                }
            case .hold:
                Log.write("long tone (ignored)")
            case .tap(let target, let count):
                guard target == "tap" else { break }
                // A tap resolves up to 450 ms after its chirp; only a chirp that landed inside speech within the last second counts.
                let duringSpeech = Date().timeIntervalSince(lastSpeechChirp) < 1.0
                DispatchQueue.main.async { self.tapAction(count: count, duringSpeech: duringSpeech) }
            case .release:
                break
            }
        }
    }

    private func beginUtterance() {
        utteranceSerial += 1
        speechFrames = 0
        openFrames = 0
        utterancePeak = -160
        chirpDuringUtterance = false
        canceled = false
        partials = [:]
        lastActivity = Date()
        transcriber?.startUtterance()
        for f in preroll.dropLast() { transcriber?.feed(f, sampleRate: sampleRate) }
        state = .listening
        activity.cancel()
        DispatchQueue.main.async { self.onActivity?(.none) }
        DispatchQueue.main.async { self.showListeningIfNeeded() }
    }

    private var hudShownForSerial = -1
    private func showListeningIfNeeded() {
        guard state == .listening, hudShownForSerial != utteranceSerial else { return }
        hudShownForSerial = utteranceSerial
        hud.listening(target: dispatcher.currentTarget?.title ?? "No session armed, will copy to clipboard")
    }

    private func endUtterance(frames: Int) {
        handleMode = false
        let speechSeconds = Double(speechFrames) * hopSeconds
        let serial = utteranceSerial
        let hadChirp = chirpDuringUtterance
        if speechSeconds >= 0.5 { autoTrim(peakDb: utterancePeak) }
        state = .armed
        guard let t = transcriber else {
            DispatchQueue.main.async { self.hud.flash("Transcriber not ready yet", tint: .yellow, icon: "hourglass") }
            return
        }
        let hadSpeech = speechSeconds >= 0.3
        DispatchQueue.main.async {
            self.pendingDeliveries += 1
            if self.canceled { return }
            if hadSpeech { self.hud.sending() } else { self.hud.hide(after: 0.15) }
        }
        Task.detached { [self] in
            let result = await t.finishUtterance()
            // A tap during speech resolves up to 450 ms after the release; give it time to cancel.
            let delay: TimeInterval = hadChirp ? 0.6 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.pendingDeliveries -= 1
                self.deliver(result, speechSeconds: speechSeconds, serial: serial)
            }
        }
    }

    private func handle(_ update: TranscriptUpdate) {
        // Live text is not shown in the HUD; only recognizer diagnostics are logged.
        if update.text.hasPrefix("[") { Log.write("recognizer \(update.locale): \(update.text)") }
    }

    // MARK: delivery (main)

    private func deliver(_ result: UtteranceResult, speechSeconds: Double, serial: Int) {
        guard !settings.nativeVoiceMode else { return }
        guard serial == -1 || (state != .idle && serial == utteranceSerial) else { return }
        if canceled {
            Log.write("canceled: \(result.text)")
            canceled = false
            hud.hide(after: 0.3)   // the tap already flashed "Canceled"
            return
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 2, speechSeconds >= 0.4, result.confidence >= 0.35 else {
            Log.write(String(format: "dropped: %@ (%.1fs speech, conf %.2f)", text.isEmpty ? "empty" : text, speechSeconds, result.confidence))
            hud.hide(after: 0.2)
            return
        }
        let outcome: String
        if voiceBridge.enabled {
            guard voiceBridge.submit(text, serial: serial) else {
                Log.write("ignored transcript from an interrupted turn")
                return
            }
            outcome = "Sent to active voice conversation"
        } else if settings.composerDelivery, ComposerDelivery.isTrusted {
            do {
                let target = settings.targetSessionTitle ?? SessionStore.lastUsed()?.title
                try ComposerDelivery.send(text, toSessionTitled: target)
                outcome = target.map { "Sent to \($0)" } ?? "Sent to Claude"
                if settings.targetSessionTitle != nil { settings.targetSessionTitle = nil }   // it is the last used now
                if let target {
                    activity.watch(sessionTitle: target, onThinking: { [weak self] in
                        Log.write("activity: \(target) is thinking")
                        self?.onActivity?(.thinking)
                    }, onDone: { [weak self] in
                        Log.write("activity: \(target) done")
                        self?.onActivity?(.done)
                    })
                }
            } catch {
                Log.write("composer delivery failed (\(error)), using the inbox")
                outcome = inboxOutcome(text: text, result: result, speechSeconds: speechSeconds)
            }
        } else {
            outcome = inboxOutcome(text: text, result: result, speechSeconds: speechSeconds)
        }
        Log.write(String(format: "%@: %@  [%@ %.2f, %.1fs]", outcome, text, result.locale, result.confidence, speechSeconds))
        recent.insert((Date(), text, outcome), at: 0)
        if recent.count > 12 { recent.removeLast() }
        lastActivity = Date()
        hud.sent(text, outcome: outcome)
        onRecentChange?()
    }

    private func inboxOutcome(text: String, result: UtteranceResult, speechSeconds: Double) -> String {
        switch dispatcher.dispatch(text: text, locale: result.locale, confidence: result.confidence, seconds: speechSeconds) {
        case .sent(let target): return "Sent to \(target.title)"
        case .copied: return "Copied, no session armed"
        }
    }

    /// Sends text exactly as if it had been spoken. Used by the send.txt test hook and the menu.
    func deliverText(_ text: String) {
        deliver(UtteranceResult(text: text, locale: "manual", confidence: 1, alternatives: []), speechSeconds: 1, serial: -1)
    }

    /// ~/.fxmic/send.txt: drop a file there and its content is delivered like an utterance (debug and scripting hook).
    private func startSendFileWatcher() {
        let url = dispatcher.root.appendingPathComponent("send.txt")
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, !self.settings.nativeVoiceMode,
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: url)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { self.deliverText(trimmed) }
        }
    }

    // MARK: button gestures (main)

    private func tapAction(count: Int, duringSpeech: Bool) {
        guard !settings.nativeVoiceMode else { return }
        Log.write("tap x\(count)\(duringSpeech ? " while squeezed (ignored)" : "")")
        if duringSpeech { return }          // cancel is a shake now; the button does nothing while the handle is in
        lastActivity = Date()
        if count == 1 { ClaudeApp.toggle() } else { disarm(reason: "double tap") }
    }


    func newSession() {
        let folder = dispatcher.currentTarget?.cwd
        ClaudeApp.newCodeSession(folder: folder, prompt: "/fxmic")
        hud.flash("New Claude Code session", detail: folder ?? "Pick a folder in Claude", tint: .blue, icon: "plus.bubble", seconds: 2.5)
    }

    func setNativeVoiceMode(_ enabled: Bool) {
        guard enabled != settings.nativeVoiceMode else { return }
        cancelNativeRequest()
        let wasArmed = state != .idle
        disarm(reason: "voice mode changed")
        settings.nativeVoiceMode = enabled
        voiceBridge.setSuspended(enabled)
        activity.cancel()
        onActivity?(.none)
        if wasArmed { arm() }
        onStateChange?()
        snapshot()
    }

    func selectNativeProvider(_ provider: NativeVoiceProvider) {
        cancelNativeRequest()
        settings.nativeVoiceProvider = provider.rawValue
        setNativeVoiceMode(true)
        nativeVoiceStatus = "Selected \(provider.displayName). End the previous app's voice call before switching."
        onStateChange?()
        snapshot()
    }

    func openNativeVoiceApp() {
        cancelNativeRequest()
        let requestID = nativeRequestID
        let provider = nativeProvider
        nativeRequest = NativeVoiceApps.open(provider: provider) { [weak self] result in
            guard let self, self.nativeRequestID == requestID, self.settings.nativeVoiceMode else { return }
            self.handleNativeAppResult(result, success: "\(provider.displayName) opened. Select Sonos and start voice mode there.")
        }
    }

    func startNativeVoice() {
        cancelNativeRequest()
        let requestID = nativeRequestID
        let provider = nativeProvider
        nativeRequest = NativeVoiceApps.startVoice(provider: provider) { [weak self] result in
            guard let self, self.nativeRequestID == requestID, self.settings.nativeVoiceMode else { return }
            self.handleNativeAppResult(result, success: "Voice start requested in \(provider.displayName). Check its call screen.")
        }
    }

    func cancelNativeRequest() {
        nativeRequest?.cancel()
        nativeRequest = nil
        nativeRequestID = UUID()
    }

    private func handleNativeAppResult(_ result: Result<Void, NativeVoiceAppError>, success: String) {
        switch result {
        case .success: nativeVoiceStatus = success
        case .failure(let error):
            nativeVoiceStatus = error.localizedDescription
            let alert = NSAlert()
            alert.messageText = "Native voice"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        onStateChange?()
        snapshot()
    }

    func showNativeVoiceHelp() {
        let alert = NSAlert()
        alert.messageText = "Voice through your subscriptions"
        alert.informativeText = "Choose Claude or Grok Bot, open that app, select the Sonos USB-C Line-in Adapter as its microphone, then start its built-in voice mode. Your existing sign-in and plan are used; EP2350 Voice has no API keys or model billing.\n\nStart voice (experimental) can press the verified voice button when Accessibility access is already enabled and the button is available. You can always start voice in the app yourself.\n\nStart handle feedback shows held/released markers on this Mac only. It does not mute, submit, cancel, or interrupt the native assistant. End a call in its own app before switching assistants. Microphone LEDs are not changed.\n\nStatus: \(nativeVoiceStatus)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
