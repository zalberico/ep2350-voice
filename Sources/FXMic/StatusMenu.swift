import AppKit
import FXMicCore
import ServiceManagement

final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    enum Activity { case none, thinking, done }
    private var activity: Activity = .none
    private var dotTimer: Timer?
    private var dotPhase = 0
    private var doneReset: DispatchWorkItem?

    /// Draws the handset with an optional badge in the lower-right corner: dots while the task runs, a check when
    /// it finishes. The badge is knocked out of the handset first so it reads as its own shape (template image).
    private static func compose(base: String, dots: Int = 0, check: Bool = false) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            if let phone = NSImage(systemSymbolName: base, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let pr = NSRect(x: (side - phone.size.width) / 2, y: (side - phone.size.height) / 2, width: phone.size.width, height: phone.size.height)
                phone.draw(in: pr)
            }
            let ctx = NSGraphicsContext.current
            if dots > 0 {
                let d: CGFloat = 2.6, gap: CGFloat = 1.0
                let x0 = side - 0.5 - (d * 3 + gap * 2)
                let y = side - d - 0.5                                   // upper-right corner
                // knock the badge area out of the handset so the dots read as their own shape
                ctx?.compositingOperation = .destinationOut
                NSColor.black.setFill()
                for i in 0..<3 {
                    NSBezierPath(ovalIn: NSRect(x: x0 + CGFloat(i) * (d + gap), y: y, width: d, height: d).insetBy(dx: -1.1, dy: -1.1)).fill()
                }
                ctx?.compositingOperation = .sourceOver
                for i in 0..<dots {
                    NSBezierPath(ovalIn: NSRect(x: x0 + CGFloat(i) * (d + gap), y: y, width: d, height: d)).fill()
                }
            }
            if check, let mark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .heavy)) {
                let r = NSRect(x: side - mark.size.width - 0.5, y: side - mark.size.height - 0.5, width: mark.size.width, height: mark.size.height)
                mark.draw(in: r.insetBy(dx: -1.4, dy: -1.4), from: .zero, operation: .destinationOut, fraction: 1)
                mark.draw(in: r)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Task-progress decoration on the icon: dots while Claude works, a check for two seconds when it finishes.
    func setActivity(_ a: Activity) {
        activity = a
        dotTimer?.invalidate(); dotTimer = nil
        doneReset?.cancel(); doneReset = nil
        switch a {
        case .thinking:
            dotPhase = 0
            dotTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.dotPhase = (self.dotPhase % 3) + 1
                self.refresh()
            }
        case .done:
            let reset = DispatchWorkItem { [weak self] in self?.setActivity(.none) }
            doneReset = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: reset)
        case .none:
            break
        }
        refresh()
    }
    private unowned let controller: AppController
    private let menu = NSMenu()

    init(controller: AppController) {
        self.controller = controller
        super.init()
        menu.delegate = self
        // Left click picks up or hangs up; right click (or control-click) opens the menu.
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()
        controller.onStateChange = { [weak self] in self?.refresh() }
        controller.dispatcher.onTargetsChanged = { [weak self] in self?.refresh() }
    }

    func refresh() {
        let symbol: String
        switch controller.state {
        case .idle: symbol = Settings.shared.iconIdle
        case .armed: symbol = Settings.shared.iconArmed
        case .listening: symbol = Settings.shared.iconListening
        }
        switch Settings.shared.statusBadge ? activity : .none {
        case .thinking: item.button?.image = StatusMenu.compose(base: symbol, dots: max(1, dotPhase))
        case .done: item.button?.image = StatusMenu.compose(base: symbol, check: true)
        case .none: item.button?.image = StatusMenu.compose(base: symbol)
        }
        if Settings.shared.nativeVoiceMode {
            let status = controller.nativeWaitingForInput ? "Waiting for the disconnected input" : (controller.state == .idle ? "Feedback off" : (!controller.nativeAudioReady ? "Waiting for input audio" : (controller.state == .listening ? "Handle held" : "Watching handle")))
            item.button?.toolTip = "EP2350 Voice: \(status). Native apps own voice playback. Right-click for assistants."
        } else {
            item.button?.toolTip = "EP2350 Voice: \(controller.state.rawValue). Click to \(controller.state == .idle ? "pick up" : "hang up"), right-click for the menu."
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 1. listening toggle
        let native = Settings.shared.nativeVoiceMode
        let toggleTitle = native
            ? (controller.state == .idle && !controller.nativeWaitingForInput ? "Start handle feedback" : "Stop handle feedback")
            : (controller.state == .idle ? "Start listening" : "Stop listening")
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleArmed), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // 2. input device
        let deviceMenu = NSMenu()
        let currentDevice = Settings.shared.deviceQuery
        for dev in AudioDevices.inputs() {
            let item = NSMenuItem(title: dev.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = dev.name
            item.state = (dev.name == currentDevice || dev.uid == currentDevice || dev.name.localizedCaseInsensitiveContains(currentDevice)) ? .on : .off
            deviceMenu.addItem(item)
        }
        let deviceItem = NSMenuItem(title: native ? "Handle input device" : "Input device", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)
        menu.addItem(.separator())

        let modeMenu = NSMenu()
        for (title, enabled) in [("Native voice (subscriptions)", true), ("Local transcription / bridge", false)] {
            let option = NSMenuItem(title: title, action: #selector(selectVoiceMode(_:)), keyEquivalent: "")
            option.target = self; option.representedObject = enabled
            option.state = native == enabled ? .on : .off
            modeMenu.addItem(option)
        }
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        modeItem.submenu = modeMenu
        menu.addItem(modeItem)

        if native {
            let providers = NSMenu()
            for provider in NativeVoiceProvider.allCases {
                let option = NSMenuItem(title: provider.displayName, action: #selector(selectNativeProvider(_:)), keyEquivalent: "")
                option.target = self; option.representedObject = provider.rawValue
                option.state = controller.nativeProvider == provider ? .on : .off
                providers.addItem(option)
            }
            let providerItem = NSMenuItem(title: "Voice assistant: \(controller.nativeProvider.displayName)", action: nil, keyEquivalent: "")
            providerItem.submenu = providers
            menu.addItem(providerItem)
            let open = NSMenuItem(title: "Open \(controller.nativeProvider.displayName)", action: #selector(openNativeApp), keyEquivalent: "")
            open.target = self; menu.addItem(open)
            let start = NSMenuItem(title: "Start voice (experimental)", action: #selector(startNativeVoice), keyEquivalent: "")
            start.target = self; menu.addItem(start)
            let help = NSMenuItem(title: "Native voice setup and status…", action: #selector(nativeVoiceHelp), keyEquivalent: "")
            help.target = self; menu.addItem(help)
            let limitation = NSMenuItem(title: "Squeeze does not control native playback yet", action: nil, keyEquivalent: "")
            limitation.isEnabled = false; menu.addItem(limitation)
            menu.addItem(.separator())
        }

        // The inherited Claude text target is unrelated to native voice.
        if !native {
        let targetMenu = NSMenu()
        let recent = SessionStore.recent(limit: 5)
        let effective = Settings.shared.targetSessionTitle ?? recent.first?.title
        for session in recent {
            let item = NSMenuItem(title: session.title, action: #selector(selectTarget(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = session.title
            item.state = session.title == effective ? .on : .off
            targetMenu.addItem(item)
        }
        let shown = effective.map { $0.count > 24 ? String($0.prefix(24)).trimmingCharacters(in: .whitespaces) + "…" : $0 } ?? "current session"
        let targetItem = NSMenuItem(title: "Target: \(shown)", action: nil, keyEquivalent: "")
        targetItem.submenu = targetMenu
        menu.addItem(targetItem)
        menu.addItem(.separator())

        // 4. options
        let shake = NSMenuItem(title: "Shake to cancel", action: #selector(toggleShake), keyEquivalent: "")
        shake.target = self; shake.state = Settings.shared.shakeToCancel ? .on : .off
        menu.addItem(shake)
        }
        let badge = NSMenuItem(title: "Menu bar activity badge", action: #selector(toggleBadge), keyEquivalent: "")
        badge.target = self; badge.state = Settings.shared.statusBadge ? .on : .off
        menu.addItem(badge)
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.isEnabled = Bundle.main.bundleIdentifier != nil
        menu.addItem(login)
        if !ComposerDelivery.isTrusted {
            let grant = NSMenuItem(title: "Grant Accessibility access…", action: #selector(grantAccessibility), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        menu.addItem(.separator())

        // 5. quit
        let quitItem = NSMenuItem(title: "Quit EP2350 Voice", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func toggleArmed() { controller.toggleArmed(source: "menu item") }
    @objc private func selectVoiceMode(_ sender: NSMenuItem) {
        guard let enabled = sender.representedObject as? Bool else { return }
        controller.setNativeVoiceMode(enabled)
    }
    @objc private func selectNativeProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = NativeVoiceProvider(rawValue: raw) else { return }
        controller.selectNativeProvider(provider)
    }
    @objc private func openNativeApp() { controller.openNativeVoiceApp() }
    @objc private func startNativeVoice() { controller.startNativeVoice() }
    @objc private func nativeVoiceHelp() { controller.showNativeVoiceHelp() }
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if wantsMenu {
            item.menu = menu           // attach only for this click so the next left click toggles again
            sender.performClick(nil)
            item.menu = nil
        } else {
            controller.toggleArmed(source: "menu bar click")
        }
    }

    @objc private func selectTarget(_ sender: NSMenuItem) {
        let title = sender.representedObject as? String ?? ""
        Settings.shared.targetSessionTitle = title.isEmpty ? nil : title
        Log.write("target: \(title.isEmpty ? "last used" : title)")
        controller.snapshot()
    }
    @objc private func toggleBadge() { Settings.shared.statusBadge.toggle(); refresh() }
    @objc private func toggleShake() { Settings.shared.shakeToCancel.toggle(); controller.snapshot() }
    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.shared.deviceQuery = name
        Log.write("input device set to \(name)")
        controller.disarm(reason: "Switching input")
        controller.arm()            // picking a device means: listen on it
        refresh()
    }
    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            Log.write("launch at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
        } catch { Log.write("launch at login failed: \(error)") }
    }
    @objc private func grantAccessibility() { ComposerDelivery.requestAccess() }
    @objc private func quit() { NSApp.terminate(nil) }
}
