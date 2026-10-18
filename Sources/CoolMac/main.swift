import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var model: FanViewModel!
    private var timer: Timer?
    private var window: NSWindow?
    private var sizeCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = FanViewModel()
        model.onRefreshPublished = { [weak self] in self?.updateStatusTitle() }
        model.refresh()

        // Length is set per-reading in updateStatusTitle (text width
        // + 4pt): monospaced digits keep the width stable between
        // digit-count changes, without worst-case dead padding.
        statusItem = NSStatusBar.system.statusItem(withLength: 27)
        if let button = statusItem.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            button.alignment = .center
        }
        updateStatusTitle()

        // Explicit content size + no SwiftUI auto-sizing: the height
        // changes only when the user switches mode (Auto hides the
        // slider), never with live data, and we resize it ourselves.
        let hosting = NSHostingController(rootView: ContentView(model: model))
        hosting.preferredContentSize = ContentView.popoverSize(mode: model.mode)
        hosting.sizingOptions = []
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = ContentView.popoverSize(mode: model.mode)
        popover.contentViewController = hosting
        sizeCancellable = model.$mode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyContentSize() }

        // `coolmac --window`: same UI in a regular window (easier to
        // keep open, and handy for screenshots/testing).
        if CommandLine.arguments.contains("--window") {
            NSApplication.shared.setActivationPolicy(.regular)
            let hosting = NSHostingController(rootView: ContentView(model: model))
            let win = NSWindow(contentViewController: hosting)
            win.title = "CoolMac"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.setContentSize(ContentView.popoverSize(mode: model.mode))
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

    private func applyContentSize() {
        let size = ContentView.popoverSize(mode: model.mode)
        popover?.contentViewController?.preferredContentSize = size
        popover?.contentSize = size
        window?.setContentSize(size)
    }

    private func updateStatusTitle() {
        let title = String(format: "%.0f\u{00B0}", model.cpuTemp)
        statusItem.button?.title = title
        if let font = statusItem.button?.font {
            let textWidth = (title as NSString).size(withAttributes: [.font: font]).width
            statusItem.length = ceil(textWidth) + 4
        }
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Show first with last-known values, refresh after: a sensor
            // scan (even cached) must never delay the popover appearing.
            updateStatusTitle()
            applyContentSize()
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
