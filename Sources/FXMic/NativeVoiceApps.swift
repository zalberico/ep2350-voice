import AppKit
import ApplicationServices
import FXMicCore

enum NativeVoiceAppError: Error, LocalizedError {
    case appMissing, launchFailed, needsAccessibility, appTerminated
    case windowMissing, startButtonMissing, ambiguousStartButton
    case inspectionLimit, inspectionFailed, interfaceChanged, pressFailed, canceled

    var errorDescription: String? {
        switch self {
        case .appMissing: return "The selected app is not installed."
        case .launchFailed: return "The selected app could not be opened."
        case .needsAccessibility: return "Start voice needs Accessibility access for EP2350 Voice. Enable it in System Settings, or start voice in the selected app."
        case .appTerminated: return "The selected app closed before voice could start."
        case .windowMissing: return "Open a conversation in the selected app, then try Start voice again."
        case .startButtonMissing: return "The native voice button was not found. Open a conversation with an empty composer, or start voice in the app."
        case .ambiguousStartButton: return "More than one voice button was found. Start voice directly in the app."
        case .inspectionLimit: return "The app's voice control could not be identified within the inspection limit. Start voice directly in the app."
        case .inspectionFailed: return "The app's accessibility controls could not be read. Start voice directly in the app."
        case .interfaceChanged: return "The app's window changed. Try Start voice again."
        case .pressFailed: return "The app did not accept the voice button press. Start voice directly in the app."
        case .canceled: return "The voice-start request was canceled."
        }
    }
}

/// Opens the user's native subscription apps. It never supplies text, API keys or audio.
enum NativeVoiceApps {
    typealias Completion = (Result<Void, NativeVoiceAppError>) -> Void
    private static let inspectionQueue = DispatchQueue(label: "local.ep2350.voice.native-accessibility", qos: .userInitiated)

    static func open(provider: NativeVoiceProvider, completion: @escaping Completion) -> NativeActionToken {
        let token = NativeActionToken()
        launch(provider: provider, token: token) { result in completion(result.map { _ in () }) }
        return token
    }

    /// Experimental UI action, not a voice transport. Completion confirms AXPress only.
    /// No permission prompt, dictation fallback, key simulation or private endpoint is used.
    static func startVoice(provider: NativeVoiceProvider, completion: @escaping Completion) -> NativeActionToken {
        let token = NativeActionToken()
        guard AXIsProcessTrusted() else {
            DispatchQueue.main.async { completion(.failure(.needsAccessibility)) }
            return token
        }
        launch(provider: provider, token: token) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let app):
                let pid = app.processIdentifier
                inspectionQueue.async {
                    let result = pressStartButton(provider: provider, pid: pid, token: token)
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
        return token
    }

    private static func launch(provider: NativeVoiceProvider, token: NativeActionToken,
                               completion: @escaping (Result<NSRunningApplication, NativeVoiceAppError>) -> Void) {
        DispatchQueue.main.async {
            guard token.isActive else { completion(.failure(.canceled)); return }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.bundleID) else {
                completion(.failure(.appMissing))
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.promptsUserIfNeeded = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                DispatchQueue.main.async {
                    guard token.isActive else { completion(.failure(.canceled)); return }
                    guard error == nil, let app, app.bundleIdentifier == provider.bundleID else {
                        completion(.failure(.launchFailed))
                        return
                    }
                    guard !app.isTerminated else { completion(.failure(.appTerminated)); return }
                    completion(.success(app))
                }
            }
        }
    }

    private static func pressStartButton(provider: NativeVoiceProvider,
                                         pid: pid_t, token: NativeActionToken) -> Result<Void, NativeVoiceAppError> {
        guard token.isActive else { return .failure(.canceled) }
        guard AXIsProcessTrusted() else { return .failure(.needsAccessibility) }
        guard isRunning(provider: provider, pid: pid) else { return .failure(.appTerminated) }
        let application = AXUIElementCreateApplication(pid)
        // Bound IPC stalls as well as overall traversal. No global accessibility tree is read.
        AXUIElementSetMessagingTimeout(application, 0.1)
        guard let window = selectedWindow(application) else { return .failure(.windowMissing) }
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var candidate: AXUIElement?
        while let (element, depth) = stack.popLast() {
            guard token.isActive else { return .failure(.canceled) }
            guard visited < 600, depth <= 24, DispatchTime.now().uptimeNanoseconds < deadline else {
                return .failure(.inspectionLimit)
            }
            visited += 1
            guard isRunning(provider: provider, pid: pid) else { return .failure(.appTerminated) }
            AXUIElementSetMessagingTimeout(element, 0.1)
            if isStartButton(element, provider: provider) {
                if candidate != nil { return .failure(.ambiguousStartButton) }
                candidate = element
            }
            var children: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            if status == .cannotComplete || status == .apiDisabled { return .failure(.inspectionFailed) }
            if let children = children as? [AXUIElement] {
                guard children.count <= 600 - visited, stack.count + children.count <= 600 - visited else {
                    return .failure(.inspectionLimit)
                }
                stack.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        guard let candidate else { return .failure(.startButtonMissing) }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { return .failure(.inspectionLimit) }
        guard isRunning(provider: provider, pid: pid) else { return .failure(.appTerminated) }
        guard let currentWindow = selectedWindow(application), CFEqual(currentWindow, window),
              isStartButton(candidate, provider: provider) else { return .failure(.interfaceChanged) }
        guard let pressed = token.performIfActive({ AXUIElementPerformAction(candidate, kAXPressAction as CFString) }) else {
            return .failure(.canceled)
        }
        guard pressed == .success else {
            return .failure(.pressFailed)
        }
        return .success(())
    }

    private static func isRunning(provider: NativeVoiceProvider, pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated && app.bundleIdentifier == provider.bundleID
    }

    private static func selectedWindow(_ application: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = read(application, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    private static func isStartButton(_ element: AXUIElement, provider: NativeVoiceProvider) -> Bool {
        guard read(element, kAXRoleAttribute) as? String == kAXButtonRole,
              (read(element, kAXEnabledAttribute) as? NSNumber)?.boolValue == true else { return false }
        // Never inspect AXValue, transcript text, text areas, inputs, or message contents.
        return provider.matchesStartVoiceButton(title: read(element, kAXTitleAttribute) as? String,
                                               description: read(element, kAXDescriptionAttribute) as? String)
    }

    private static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
