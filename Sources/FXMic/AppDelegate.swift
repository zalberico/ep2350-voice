import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController!
    private var statusMenu: StatusMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch \(Bundle.main.bundleIdentifier ?? "bare") pid \(ProcessInfo.processInfo.processIdentifier)")
        controller = AppController()
        statusMenu = StatusMenu(controller: controller)
        controller.onActivity = { [weak self] a in self?.statusMenu.setActivity(a) }
        HotKey.register { [weak self] in self?.controller.toggleArmed(source: "hotkey") }
        if Settings.shared.autoArm {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.controller.arm() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.cancelNativeRequest()
        controller.voiceBridge.shutdown()
        controller.disarm(reason: "app quitting")
    }
}
