import AppKit
import ApplicationServices
import Foundation

/// Types a message into the Claude desktop app's composer and sends it, through the Accessibility API,
/// without changing which app is in front. Needs Accessibility permission for FXMic.
enum ComposerDelivery {
    enum Failure: Error, CustomStringConvertible {
        case notTrusted, claudeNotRunning, noWindow, noComposer, valueNotSet, noSendButton, notSent, hasDraft, sessionNotFound, switchFailed
        var description: String {
            switch self {
            case .notTrusted: return "Accessibility not granted"
            case .claudeNotRunning: return "Claude is not running"
            case .noWindow: return "no Claude window"
            case .noComposer: return "composer not found"
            case .valueNotSet: return "could not set the composer text"
            case .noSendButton: return "no Send button"
            case .notSent: return "composer still holds the text"
            case .hasDraft: return "composer already holds a draft, left untouched"
            case .sessionNotFound: return "target session not in the sidebar"
            case .switchFailed: return "could not switch to the target session"
            }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Ask Electron to publish its accessibility tree ahead of time; the first request takes a couple of seconds to take effect.
    static func warmUp() {
        guard isTrusted, let app = ClaudeApp.running else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Title of the session shown in the window, read from its "…, rename session" header button.
    static func activeSessionTitle(in window: AXUIElement) -> String? {
        let suffix = ", rename session"
        return find(window, depth: 0) { role($0) == "AXButton" && string($0, kAXDescriptionAttribute).hasSuffix(suffix) }
            .first.map { String(string($0, kAXDescriptionAttribute).dropLast(suffix.count)) }
    }

    /// Presses the sidebar row with this title so the window shows that session. No focus change.
    static func switchToSession(titled target: String, in window: AXUIElement) throws {
        if activeSessionTitle(in: window) == target { return }
        let rows = find(window, depth: 0) { el in
            guard role(el) == "AXButton" else { return false }
            let t = string(el, kAXTitleAttribute)
            return t.hasSuffix(target) && (t.hasPrefix("Idle ") || t.hasPrefix("Running ") || t == target || t.hasPrefix("#"))
        }
        guard let row = rows.first else { throw Failure.sessionNotFound }
        guard AXUIElementPerformAction(row, kAXPressAction as CFString) == .success else { throw Failure.switchFailed }
        for _ in 0..<20 {                 // up to 2 s for the view to change
            Thread.sleep(forTimeInterval: 0.1)
            if activeSessionTitle(in: window) == target { return }
        }
        throw Failure.switchFailed
    }

    static func send(_ text: String, toSessionTitled target: String? = nil) throws {
        guard isTrusted else { throw Failure.notTrusted }
        guard let app = ClaudeApp.running else { throw Failure.claudeNotRunning }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if let target {
            let windows = (attribute(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            guard let main = (attribute(axApp, kAXMainWindowAttribute) as! AXUIElement?) ?? windows.first else { throw Failure.noWindow }
            try switchToSession(titled: target, in: main)
            Thread.sleep(forTimeInterval: 0.3)     // let the new view's composer settle
        }

        var composer: AXUIElement?
        var window: AXUIElement?
        for attempt in 0..<12 {          // the tree can take ~2 s to appear the first time
            let windows = (attribute(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            let main = (attribute(axApp, kAXMainWindowAttribute) as! AXUIElement?) ?? windows.first
            if let main {
                window = main
                composer = find(main, depth: 0) { role($0) == "AXTextArea" && string($0, kAXDescriptionAttribute) == "Prompt" }.first
                if composer != nil { break }
            }
            if attempt == 11 { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let window else { throw Failure.noWindow }
        guard let composer else { throw Failure.noComposer }

        // A draft Miguel typed is set aside, the spoken message is sent on its own, and the draft is put back.
        let before = string(composer, kAXValueAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
        let draft: String? = (!before.isEmpty && !before.lowercased().hasPrefix("type /")) ? before : nil
        if let draft { Log.write("composer holds a draft, will restore it: \(draft.prefix(60))") }
        defer {
            if let draft {
                Thread.sleep(forTimeInterval: 0.2)
                let r = AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, draft as CFString)
                Log.write(r == .success ? "draft restored" : "draft could not be restored: \(draft)")
            }
        }
        var value = ""
        for attempt in 0..<3 {
            let r = AXUIElementSetAttributeValue(composer, kAXValueAttribute as CFString, text as CFString)
            Thread.sleep(forTimeInterval: 0.15 + 0.15 * Double(attempt))
            value = string(composer, kAXValueAttribute)
            if value.hasPrefix(text.prefix(40)) { break }
            Log.write("composer set attempt \(attempt + 1) -> \(r.rawValue), readback: \(value.prefix(60))")
        }
        guard value.hasPrefix(text.prefix(40)) else { throw Failure.valueNotSet }

        let cf = frame(composer)
        var sendButton: AXUIElement?
        for _ in 0..<8 {
            sendButton = find(window, depth: 0) { el in
                guard role(el) == "AXButton", string(el, kAXDescriptionAttribute) == "Send" else { return false }
                let f = frame(el)
                return f.minY >= cf.minY - 10 && f.minY <= cf.maxY + 80
            }.first
            if sendButton != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let sendButton else { throw Failure.noSendButton }
        guard AXUIElementPerformAction(sendButton, kAXPressAction as CFString) == .success else { throw Failure.notSent }
        Thread.sleep(forTimeInterval: 0.3)
        if string(composer, kAXValueAttribute).hasPrefix(text.prefix(40)) { throw Failure.notSent }
    }

    // MARK: helpers

    private static func attribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    private static func string(_ el: AXUIElement, _ name: String) -> String { attribute(el, name) as? String ?? "" }
    private static func role(_ el: AXUIElement) -> String { string(el, kAXRoleAttribute) }
    private static func children(_ el: AXUIElement) -> [AXUIElement] { (attribute(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    private static func frame(_ el: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = attribute(el, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = attribute(el, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }
    private static func find(_ el: AXUIElement, depth: Int, _ pred: (AXUIElement) -> Bool) -> [AXUIElement] {
        var out: [AXUIElement] = []
        if pred(el) { out.append(el) }
        if depth < 80 { for c in children(el) { out += find(c, depth: depth + 1, pred) } }
        return out
    }
}
