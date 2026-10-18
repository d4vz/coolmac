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
        model.onRefreshPublished = { [weak self] in self?.updateStatusTitle() }
        model.refresh()

        // Fixed length, monospaced digits: a variable-length item moves
        // in the menu bar every time the temp/RPM text changes width,
        // and the popover anchored to it jumps around (or clips).
        statusItem = NSStatusBar.system.statusItem(withLength: 112)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            button.alignment = .center
        }
        updateStatusTitle()

        // Fixed content size + no SwiftUI auto-sizing: the popover must
        // never resize (chart vs. text differs per mode), otherwise
        // AppKit re-anchors it on every mode switch / data refresh.
        let hosting = NSHostingController(rootView: ContentView(model: model))
        hosting.preferredContentSize = ContentView.popoverSize
        hosting.sizingOptions = []
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = ContentView.popoverSize
        popover.contentViewController = hosting

        // `coolmac --window`: same UI in a regular window (easier to
        // keep open, and handy for screenshots/testing).
        if CommandLine.arguments.contains("--window") {
            NSApplication.shared.setActivationPolicy(.regular)
            let hosting = NSHostingController(rootView: ContentView(model: model))
            let win = NSWindow(contentViewController: hosting)
            win.title = "CoolMac"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.setContentSize(ContentView.popoverSize)
            win.center()
            win.makeKeyAndOrderFront(nil)
            window = win
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.model.refresh()
            self?.updateStatusTitle()
        }

        // `coolmac --show-popover`: open the popover on launch
        // (screenshot / anchor regression check without a mouse click).
        if CommandLine.arguments.contains("--show-popover"),
           let button = statusItem.button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.togglePopover(button)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if model.mode != .auto { model.restoreAutoSync() }
    }

    private func updateStatusTitle() {
        let fan0 = model.fans.first?.actual ?? 0
        statusItem.button?.title = String(format: "%.0f\u{00B0}C  %.0f rpm", model.cpuTemp, fan0)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Show first with last-known values, refresh after: a sensor
            // scan (even cached) must never delay the popover appearing.
            updateStatusTitle()
            popover.contentViewController?.preferredContentSize = ContentView.popoverSize
            popover.contentSize = ContentView.popoverSize
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            model.refresh()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
