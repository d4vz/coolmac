import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var model: FanViewModel!
    private var timer: Timer?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = FanViewModel()
        model.refresh()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        updateStatusTitle()

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ContentView(model: model))

        // `coolmac --window`: same UI in a regular window (easier to
        // keep open, and handy for screenshots/testing).
        if CommandLine.arguments.contains("--window") {
            NSApplication.shared.setActivationPolicy(.regular)
            let hosting = NSHostingController(rootView: ContentView(model: model))
            let win = NSWindow(contentViewController: hosting)
            win.title = "CoolMac"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.setContentSize(NSSize(width: 384, height: 560))
            win.center()
            win.makeKeyAndOrderFront(nil)
            window = win
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.model.refresh()
            self?.updateStatusTitle()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if model.mode != .auto { model.controller.restoreAuto() }
    }

    private func updateStatusTitle() {
        let fan0 = model.fans.first?.actual ?? 0
        statusItem.button?.title = String(format: "%.0f\u{00B0}C  %.0f rpm", model.cpuTemp, fan0)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.refresh()
            updateStatusTitle()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
