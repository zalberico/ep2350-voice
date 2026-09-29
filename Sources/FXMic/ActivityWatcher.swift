import AppKit
import ApplicationServices
import Foundation

/// Watches a Claude session's sidebar label after a message was sent: "Running <title>" means Claude picked it up,
/// back to "Idle <title>" means the turn finished. Drives the "Thinking" and "Done" toasts.
final class ActivityWatcher {
    enum SessionState { case running, idle, unknown }

    private var thread: Thread?
    private var generation = 0

    func watch(sessionTitle: String, onThinking: @escaping () -> Void, onDone: @escaping () -> Void) {
        generation += 1
        let gen = generation
        thread?.cancel()
        let t = Thread { [weak self] in
            let start = Date()
            var sawRunning = false
            while let self, self.generation == gen, !Thread.current.isCancelled {
                let state = ActivityWatcher.state(of: sessionTitle)
                if !sawRunning {
                    if state == .running {
                        sawRunning = true
                        DispatchQueue.main.async { onThinking() }
                    } else if Date().timeIntervalSince(start) > 20 {
                        Log.write("activity: \(sessionTitle) never showed Running, giving up")
                        return
                    }
                } else if state == .idle {
                    DispatchQueue.main.async { onDone() }
                    return
                } else if Date().timeIntervalSince(start) > 3600 {
                    return
                }
                Thread.sleep(forTimeInterval: sawRunning ? 0.7 : 0.35)
            }
        }
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    func cancel() { generation += 1; thread?.cancel(); thread = nil }

    static func state(of title: String) -> SessionState {
        guard AXIsProcessTrusted(), let app = ClaudeApp.running else { return .unknown }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], let win = windows.first else { return .unknown }
        var result = SessionState.unknown
        func walk(_ el: AXUIElement, _ depth: Int) {
            if result != .unknown || depth > 80 { return }
            var roleRef: AnyObject?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            if roleRef as? String == "AXButton" {
                var titleRef: AnyObject?; AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
                if let t = titleRef as? String, t.hasSuffix(title) {
                    if t.hasPrefix("Running ") { result = .running; return }
                    if t.hasPrefix("Idle ") { result = .idle; return }
                }
            }
            var kidsRef: AnyObject?; AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef)
            for k in (kidsRef as? [AXUIElement]) ?? [] { walk(k, depth + 1); if result != .unknown { return } }
        }
        walk(win, 0)
        return result
    }
}
