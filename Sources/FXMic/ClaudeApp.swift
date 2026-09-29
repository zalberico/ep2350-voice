import AppKit
import ApplicationServices
import Foundation

/// Talks to the Claude desktop app: bring it forward, go back, open a new Code session.
enum ClaudeApp {
    static let bundleID = "com.anthropic.claudefordesktop"
    private static var previousApp: NSRunningApplication?

    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Brings Claude to the front; if it is already frontmost, returns to the app that was active before.
    /// Uses a launch request rather than NSRunningApplication.activate, which macOS ignores from background apps.
    static func toggle() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == bundleID {
            if let previous = previousApp, !previous.isTerminated, let url = previous.bundleURL {
                bringForward(url)
            } else {
                running?.hide()
            }
            return
        }
        previousApp = front
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            bringForward(url)
        }
    }

    private static func bringForward(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error { NSLog("[fxmic] activate failed: %@", "\(error)") }
        }
    }

    /// Opens a new Claude Code session in `folder` with the composer prefilled. Presses Return for you when
    /// Accessibility access has been granted, otherwise leaves the prefilled composer for you to send.
    static func newCodeSession(folder: String?, prompt: String) {
        var components = URLComponents(string: "claude://code/new")!
        var items = [URLQueryItem(name: "q", value: prompt)]
        if let folder, !folder.isEmpty { items.append(URLQueryItem(name: "folder", value: folder)) }
        components.queryItems = items
        guard let url = components.url else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.open(url)
        guard AXIsProcessTrusted() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            pressReturn()
        }
    }

    static func pressReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
    }
}
