import AVFoundation
import Foundation
import FXMicCore

/// Local transport for an active assistant session. No UI automation or network service.
final class VoiceBridge: NSObject, AVSpeechSynthesizerDelegate {
    private let root: URL?
    private let synth = AVSpeechSynthesizer()
    private var gate = VoiceTurnGate()
    private var timer: Timer?
    private var speaking = false
    private var spokenThrough = 0
    private var activeUtterance: AVSpeechUtterance?
    private var activeReplyID: String?
    var enabled: Bool { root != nil }

    override init() {
        if let path = UserDefaults.standard.string(forKey: "voiceBridgeDirectory"), !path.isEmpty {
            root = URL(fileURLWithPath: path, isDirectory: true)
        } else { root = nil }
        super.init()
        guard let root else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        synth.delegate = self
        event("ready")
        snapshot()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.poll() }
    }

    // All methods execute on the main queue, including speech delegate callbacks.
    func press(serial: Int) {
        guard enabled else { return }
        stop(reason: "handle_pressed")
        gate.press(serial: serial)
        event("press")
        snapshot()
    }
    func release() {
        guard enabled else { return }
        gate.release()
        event("release")
        snapshot()
    }
    func cancel() {
        guard enabled else { return }
        stop(reason: "canceled")
        gate.cancel()
        event("cancel")
        snapshot()
    }
    func submit(_ text: String, serial: Int) -> Bool {
        guard enabled, serial == gate.serial, !gate.held else { return false }
        event("utterance", ["text": text])
        snapshot()
        return true
    }
    func shutdown() {
        stop(reason: "stopped")
        gate.cancel()
        timer?.invalidate()
        event("stopped")
        snapshot()
    }

    private func stop(reason: String) {
        if let utterance = activeUtterance {
            let text = utterance.speechString as NSString
            event("interrupted", ["replyID": activeReplyID ?? "", "reason": reason,
                "spokenPrefixApproximate": text.substring(to: min(spokenThrough, text.length))])
        }
        activeUtterance = nil
        activeReplyID = nil
        synth.stopSpeaking(at: .immediate)
        speaking = false
    }

    private func poll() {
        guard let root else { return }
        let url = root.appendingPathComponent("reply.json")
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
            try FileManager.default.removeItem(at: url)
            guard let obj, let id = obj["id"], let turn = obj["turnID"], let text = obj["text"],
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                event("reply_rejected", ["reason": "invalid_payload"]); return
            }
            guard gate.accept(replyID: id, turnID: turn) else {
                event("reply_rejected", ["replyID": id, "reason": "stale_held_or_duplicate"]); return
            }
            stop(reason: "replaced")
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.5
            activeUtterance = utterance
            activeReplyID = id
            spokenThrough = 0
            speaking = true
            event("reply_accepted", ["replyID": id, "text": text])
            synth.speak(utterance)
            snapshot()
        } catch { event("error", ["message": error.localizedDescription]) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        event("speaking", ["replyID": activeReplyID ?? ""])
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        spokenThrough = characterRange.location
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === activeUtterance else { return }
        event("finished", ["replyID": activeReplyID ?? ""])
        activeUtterance = nil; activeReplyID = nil; speaking = false
        snapshot()
    }

    private func event(_ type: String, _ fields: [String: String] = [:]) {
        guard let root else { return }
        var obj = fields
        obj["type"] = type; obj["turnID"] = gate.turnID
        obj["timestamp"] = ISO8601DateFormatter().string(from: Date())
        obj["unixTime"] = String(Date().timeIntervalSince1970)
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        data.append(10)
        let url = root.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: data) }
            catch { Log.write("voice event write failed: \(error)") }
        }
    }
    private func snapshot() {
        guard let root else { return }
        let obj: [String: Any] = ["turnID": gate.turnID, "held": gate.held, "speaking": speaking,
                                "updatedAt": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: root.appendingPathComponent("state.json"), options: .atomic)
        }
    }
}
