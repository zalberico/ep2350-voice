import Foundation

/// User-adjustable values, stored in UserDefaults under the app's bundle id (or the binary name when run bare).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "deviceQuery": "Sonos",
            "locales": ["en-US"],
            "idleMinutes": 20,
            "openDb": -62.0,
            "closeDb": -68.0,
            "chirpFreqs": [15500.0, 16500.0],
            "pressFreqs": [17000.0, 18500.0],
            "releaseFreqs": [14000.0, 15000.0],
            "cancelFreqs": [12000.0, 13000.0],
            "autoArm": true,
            "hudEnabled": true,
            "autoGain": false,
            "composerDelivery": false,
            "nativeVoiceMode": true,
            "nativeVoiceProvider": "claude",
            "shakeToCancel": true,
            "statusBadge": true,
            "iconIdle": "phone.down.fill",
            "iconArmed": "phone.fill",
            "iconListening": "phone.and.waveform.fill",
        ])
    }

    var deviceQuery: String { get { d.string(forKey: "deviceQuery") ?? "Sonos" } set { d.set(newValue, forKey: "deviceQuery") } }
    var locales: [String] { get { d.stringArray(forKey: "locales") ?? ["en-US"] } set { d.set(newValue, forKey: "locales") } }
    var idleMinutes: Double { get { d.double(forKey: "idleMinutes") } set { d.set(newValue, forKey: "idleMinutes") } }
    var openDb: Float { get { Float(d.double(forKey: "openDb")) } set { d.set(Double(newValue), forKey: "openDb") } }
    var closeDb: Float { get { Float(d.double(forKey: "closeDb")) } set { d.set(Double(newValue), forKey: "closeDb") } }
    var chirpFreqs: [Double] { get { (d.array(forKey: "chirpFreqs") as? [Double]) ?? [15500, 16500] } set { d.set(newValue, forKey: "chirpFreqs") } }
    var pressFreqs: [Double] { get { (d.array(forKey: "pressFreqs") as? [Double]) ?? [17000, 18500] } set { d.set(newValue, forKey: "pressFreqs") } }
    var cancelFreqs: [Double] { get { (d.array(forKey: "cancelFreqs") as? [Double]) ?? [12000, 13000] } set { d.set(newValue, forKey: "cancelFreqs") } }
    var releaseFreqs: [Double] { get { (d.array(forKey: "releaseFreqs") as? [Double]) ?? [14000, 15000] } set { d.set(newValue, forKey: "releaseFreqs") } }
    var autoArm: Bool { get { d.bool(forKey: "autoArm") } set { d.set(newValue, forKey: "autoArm") } }
    var hudEnabled: Bool { get { d.bool(forKey: "hudEnabled") } set { d.set(newValue, forKey: "hudEnabled") } }
    var autoGain: Bool { get { d.bool(forKey: "autoGain") } set { d.set(newValue, forKey: "autoGain") } }
    var iconIdle: String { d.string(forKey: "iconIdle") ?? "phone.down.fill" }
    var iconArmed: String { d.string(forKey: "iconArmed") ?? "phone.fill" }
    var iconListening: String { d.string(forKey: "iconListening") ?? "phone.and.waveform.fill" }
    /// Title of the Claude session that receives messages; nil means whatever session was used last.
    var targetSessionTitle: String? { get { d.string(forKey: "targetSessionTitle") } set { d.set(newValue, forKey: "targetSessionTitle") } }
    /// Dots while the session works and a check when it finishes, drawn on the menu bar icon.
    var statusBadge: Bool { get { d.bool(forKey: "statusBadge") } set { d.set(newValue, forKey: "statusBadge") } }
    var shakeToCancel: Bool { get { d.bool(forKey: "shakeToCancel") } set { d.set(newValue, forKey: "shakeToCancel") } }
    var composerDelivery: Bool { get { d.bool(forKey: "composerDelivery") } set { d.set(newValue, forKey: "composerDelivery") } }
    /// Native apps own the conversation, audio and subscription; this app observes handle markers only.
    var nativeVoiceMode: Bool { get { d.bool(forKey: "nativeVoiceMode") } set { d.set(newValue, forKey: "nativeVoiceMode") } }
    var nativeVoiceProvider: String { get { d.string(forKey: "nativeVoiceProvider") ?? "claude" } set { d.set(newValue, forKey: "nativeVoiceProvider") } }
    var selectedTargetID: String? { get { d.string(forKey: "selectedTargetID") } set { d.set(newValue, forKey: "selectedTargetID") } }
}
