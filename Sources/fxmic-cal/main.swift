import AVFoundation
import Foundation
import FXMicCore

struct Options {
    var list = false
    var device = "USB Advanced Audio Device"
    var file: String?
    var recordDir = "recordings"
    var record = true
    var scan = false
    var meter = false
    var duration: Double?
    var openDb: Float = -50
    var closeDb: Float = -58
    var stt = false
    var locales = ["en-US", "es-MX"]
    var realtime = false
    var pilotFreq: Double? = nil
}

func usage() -> Never {
    print("""
    fxmic-cal [--list] [--device <uid or name substring>] [--file <wav>] [--scan] [--meter] [--no-record]
              [--record-dir <dir>] [--open <dB>] [--close <dB>] [--duration <seconds>]
              [--stt] [--locales en-US,es-MX]     live on-device transcription of each utterance
    """)
    exit(2)
}

var opts = Options()
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String { guard !args.isEmpty else { usage() }; return args.removeFirst() }
    switch a {
    case "--list": opts.list = true
    case "--device": opts.device = value()
    case "--file": opts.file = value()
    case "--record-dir": opts.recordDir = value()
    case "--no-record": opts.record = false
    case "--scan": opts.scan = true
    case "--meter": opts.meter = true
    case "--duration": opts.duration = Double(value())
    case "--stt": opts.stt = true
    case "--realtime": opts.realtime = true
    case "--pilot": opts.pilotFreq = Double(value())
    case "--locales": opts.locales = value().split(separator: ",").map(String.init)
    case "--open": opts.openDb = Float(value()) ?? opts.openDb
    case "--close": opts.closeDb = Float(value()) ?? opts.closeDb
    default: usage()
    }
}

// MARK: logging

let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss.SSS"
var fileTime: Double?   // set in --file mode: log the position in the file instead of wall clock
func log(_ s: String) {
    let prefix = fileTime.map { String(format: "%8.3f s", $0) } ?? clock.string(from: Date())
    print("\(prefix)  \(s)")
    fflush(stdout)
}
func db(_ v: Float) -> String { String(format: "%.1f dBFS", v) }

// MARK: live transcription (optional)

var transcriber: LiveTranscriber?
let pendingFinishes = DispatchGroup()
var lastLoggedPartial: [String: String] = [:]
if opts.stt {
    guard #available(macOS 26, *) else { print("--stt needs macOS 26"); exit(1) }
    let ready = DispatchSemaphore(value: 0)
    let locales = opts.locales
    Task.detached {
        do {
            transcriber = try await LiveTranscriber(locales: locales) { update in
                guard !update.isFinal else { return }
                if lastLoggedPartial[update.locale] != update.text, !update.text.isEmpty {
                    lastLoggedPartial[update.locale] = update.text
                    log(String(format: "  partial [%@ %.2f] %@", update.locale, update.confidence, update.text))
                }
            }
        } catch {
            print("transcriber setup failed: \(error)")
        }
        ready.signal()
    }
    ready.wait()
    guard let t = transcriber else { exit(1) }
    log("transcriber ready: \(t.locales.joined(separator: ", "))  analyzer input \(t.inputFormatDescription)")
}

func finishTranscription(utteranceSeconds: Double) {
    guard let t = transcriber else { return }
    pendingFinishes.enter()
    let started = Date()
    Task.detached {
        let r = await t.finishUtterance()
        let latency = Date().timeIntervalSince(started)
        let alts = r.alternatives.filter { $0.locale != r.locale }
            .map { String(format: "[%@ %.2f] %@", $0.locale, $0.confidence, $0.text) }.joined(separator: " | ")
        log(String(format: "STT  [%@ %.2f]  %@   (utterance %.1f s, finalized in %.2f s)%@",
                   r.locale, r.confidence, r.text.isEmpty ? "(empty)" : r.text, utteranceSeconds, latency,
                   alts.isEmpty ? "" : "   other: " + alts))
        pendingFinishes.leave()
    }
}

// MARK: device listing

let devices = AudioDevices.inputs()
let defaultID = AudioDevices.defaultInputID()
if opts.list {
    for d in devices {
        let marker = d.id == defaultID ? "  (macOS default input)" : ""
        let gain = AudioDevices.inputVolume(d.id).map { String(format: "  gain %.0f%%", $0 * 100) } ?? ""
        print("\(d.name)  |  \(d.inputChannels) ch  \(Int(d.sampleRate)) Hz\(gain)\(marker)\n    uid: \(d.uid)")
    }
    exit(0)
}

// MARK: shared pipeline state

let targets = [
    ToneTarget(name: "slot1 12.0+13.0 kHz", freqs: [12000, 13000]),
    ToneTarget(name: "slot2 14.0+15.0 kHz", freqs: [14000, 15000]),
    ToneTarget(name: "slot3 15.5+16.5 kHz", freqs: [15500, 16500]),
    ToneTarget(name: "slot4 17.0+18.5 kHz", freqs: [17000, 18500]),
]

var sampleRate: Double = 48000
var hopSeconds = 0.010
var gateConfig = GateConfig()
gateConfig.openDb = opts.openDb
gateConfig.closeDb = opts.closeDb
let gate = SpeechGate(config: gateConfig)
var chirps: ChirpDetector!
var scanner: BandScanner?
var writer: WavWriter?
var preroll: [[Float]] = []
var utterancePeak: Float = -160
var floorDb: Float = 0
var windowPeak: Float = -160
var frameIndex = 0
var lastScanFrame = -100
var lastStatusFrame = 0
let recordDir = URL(fileURLWithPath: opts.recordDir)
let stamp = DateFormatter()
stamp.dateFormat = "yyyy-MM-dd_HHmmss"

func closeUtterance() {
    guard let w = writer else { return }
    let seconds = w.close()
    writer = nil
    var advice = ""
    if utterancePeak > -3 { advice = "  <- too hot, turn the orange knob down" }
    else if utterancePeak < -30 { advice = "  <- quiet, turn the orange knob up" }
    log(String(format: "saved %@  (%.2f s, peak %@)%@", w.url.lastPathComponent, seconds, db(utterancePeak), advice))
}

var peakHold: Float = -160
func meterLine(_ rms: Float) -> String {
    let width = 40
    let filled = max(0, min(width, Int((rms + 80) / 80 * Float(width))))
    let state = gate.isOpen ? "GATE OPEN " : gate.micLive ? "mic on    " : "silence   "
    return "\r" + state + "[" + String(repeating: "#", count: filled) + String(repeating: " ", count: width - filled) + "] rms " + db(rms) + "  peak hold " + db(peakHold) + "      "
}

func process(_ frame: [Float]) {
    frameIndex += 1
    if fileTime != nil { fileTime = Double(frameIndex) * hopSeconds }
    let rms = Levels.rmsDb(frame)
    let peak = Levels.peakDb(frame)
    floorDb = frameIndex == 1 ? rms : min(floorDb + 0.02, rms)
    windowPeak = max(windowPeak, peak)

    preroll.append(frame)
    if preroll.count > 20 { preroll.removeFirst() }

    for event in gate.process(rmsDb: rms) {
        switch event {
        case .micOn(let level):
            log("MIC ON   floor rose to \(db(level)) (handle squeezed?)")
        case .micOff:
            log("MIC OFF  back to silence")
        case .opened(let level):
            log("GATE OPEN  \(db(level))")
            utterancePeak = -160
            lastLoggedPartial = [:]
            transcriber?.startUtterance()
            for f in preroll.dropLast() { transcriber?.feed(f, sampleRate: sampleRate) }
            if opts.record {
                let url = recordDir.appendingPathComponent("\(stamp.string(from: Date()))_utt.wav")
                writer = try? WavWriter(url: url, sampleRate: Int(sampleRate))
                for f in preroll.dropLast() { writer?.append(f) }
            }
        case .closed(let frames):
            log(String(format: "GATE CLOSE  after %.2f s", Double(frames) * hopSeconds))
            closeUtterance()
            finishTranscription(utteranceSeconds: Double(frames) * hopSeconds)
        }
    }
    if gate.isOpen {
        writer?.append(frame)
        utterancePeak = max(utterancePeak, peak)
        transcriber?.feed(frame, sampleRate: sampleRate)
    }

    for event in chirps.process(frame) {
        switch event {
        case .onset(let target, let level, let snr):
            log(String(format: "CHIRP  %@  level %@  snr %.0f dB%@", target, db(level), snr, gate.isOpen ? "  (while talking)" : ""))
        case .hold(let target):
            log("HOLD   \(target)")
        case .release(let target, let seconds):
            log(String(format: "CHIRP END  %@  %.2f s", target, seconds))
        case .tap(let target, let count):
            log("TAP    \(count == 1 ? "single" : count == 2 ? "DOUBLE" : "x\(count)")  \(target)")
        }
    }

    if let pf = opts.pilotFreq, frameIndex % 25 == 0 {
        let level = Goertzel.powerDb(frame, sampleRate: sampleRate, freq: pf)
        let guardDb = max(Goertzel.powerDb(frame, sampleRate: sampleRate, freq: pf - 600), Goertzel.powerDb(frame, sampleRate: sampleRate, freq: pf + 600))
        log(String(format: "pilot %.1f kHz  %@   guard %@   speech rms %@", pf / 1000, db(level), db(guardDb), db(rms)))
    }

    if let scanner, frameIndex - lastScanFrame >= 10, let top = scanner.scan(frame) {
        lastScanFrame = frameIndex
        log("scan  " + top.map { String(format: "%.1fk:%.0f", $0.freq / 1000, $0.db) }.joined(separator: "  "))
    }

    if opts.meter {
        peakHold = max(peak, peakHold - 0.15)
        if frameIndex % 5 == 0 { print(meterLine(rms), terminator: ""); fflush(stdout) }
    } else if fileTime == nil, frameIndex - lastStatusFrame >= 500 {
        lastStatusFrame = frameIndex
        log("status  floor \(db(floorDb))  peak(5s) \(db(windowPeak))  mic \(gate.micLive ? "on" : "off")  gate \(gate.isOpen ? "open" : "closed")")
        windowPeak = -160
    }
}

func armDetectors() {
    chirps = ChirpDetector(targets: targets, sampleRate: sampleRate, hopSeconds: hopSeconds)
    if opts.scan { scanner = BandScanner(sampleRate: sampleRate) }
}

// MARK: file mode

if let path = opts.file {
    opts.record = false
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = file.processingFormat
    sampleRate = format.sampleRate
    let hop = Int((sampleRate * hopSeconds).rounded())
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { exit(1) }
    try file.read(into: buffer)
    let frames = Int(buffer.frameLength)
    let channels = Int(format.channelCount)
    var mono = [Float](repeating: 0, count: frames)
    if let data = buffer.floatChannelData {
        for c in 0..<channels { for i in 0..<frames { mono[i] += data[c][i] / Float(channels) } }
    }
    fileTime = 0
    armDetectors()
    log("file: \(path)  \(Int(sampleRate)) Hz  \(channels) ch  \(String(format: "%.2f", Double(frames) / sampleRate)) s")
    var i = 0
    let hopNanos = UInt64(hopSeconds * 1_000_000_000)
    var nextDeadline = DispatchTime.now()
    while i + hop <= frames {
        process(Array(mono[i..<i + hop]))
        i += hop
        if opts.realtime {
            nextDeadline = nextDeadline + .nanoseconds(Int(hopNanos))
            let now = DispatchTime.now()
            if nextDeadline > now { usleep(useconds_t((nextDeadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1000)) }
        }
    }
    // flush a pending tap by feeding a little silence
    for _ in 0..<60 { process([Float](repeating: 0, count: hop)) }
    if gate.isOpen { closeUtterance(); finishTranscription(utteranceSeconds: 0) }
    _ = pendingFinishes.wait(timeout: .now() + 10)
    log("end of file")
    exit(0)
}

// MARK: live mode

guard let dev = AudioDevices.find(opts.device) else {
    print("no input device matches \"\(opts.device)\". Available:")
    for d in devices { print("  \(d.name)  uid=\(d.uid)") }
    exit(1)
}
log("device: \(dev.name)  |  \(dev.inputChannels) ch  \(Int(dev.sampleRate)) Hz  |  uid \(dev.uid)")
if let gain = AudioDevices.inputVolume(dev.id) { log(String(format: "device input gain: %.0f%%", gain * 100)) }
log(dev.id == defaultID ? "note: this device is currently also the macOS default input" : "macOS default input is a different device, as intended")
if opts.record { try? FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true) }

let capture = try InputCapture(device: dev) { frame in process(frame) }
sampleRate = capture.sampleRate
hopSeconds = Double(capture.hop) / capture.sampleRate
armDetectors()

let startedAt = Date()
try capture.start()
log(String(format: "listening (engine started in %.2f s). Squeeze and talk, or press grey. Ctrl-C to stop.", Date().timeIntervalSince(startedAt)))
if opts.meter { log("target while talking: peak hold between -20 and -6 dBFS. Silence should read below -80.") }

func shutdown() {
    capture.sync { if gate.isOpen { closeUtterance(); finishTranscription(utteranceSeconds: 0) } }
    _ = pendingFinishes.wait(timeout: .now() + 5)
    capture.stop()
    log("stopped")
}

signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { shutdown(); exit(0) }
sigint.resume()
if let d = opts.duration {
    DispatchQueue.main.asyncAfter(deadline: .now() + d) { shutdown(); exit(0) }
}
dispatchMain()
