import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var model: FanViewModel!
    private var timer: Timer?

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
