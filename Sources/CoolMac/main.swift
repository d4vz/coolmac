import AppKit
import SMC

// MARK: - Fan curve

/// Dynamic fan curve: CPU temperature (C) -> fan speed (% of each fan's range).
/// Speed is interpolated linearly between points, so fans ramp smoothly
/// with temperature instead of jumping between fixed steps.
struct FanCurve {
    var points: [(temp: Double, percent: Double)] = [
        (40, 0), (55, 25), (70, 50), (85, 75), (95, 100),
    ]

    func percent(for temp: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if temp <= first.temp { return first.percent }
        if temp >= last.temp { return last.percent }
        for i in 1..<points.count where temp <= points[i].temp {
            let (t0, p0) = points[i - 1]
            let (t1, p1) = points[i]
            return p0 + (p1 - p0) * (temp - t0) / (t1 - t0)
        }
        return last.percent
    }
}

enum ControlMode: String {
    case auto = "Automatic (system)"
    case curve = "Dynamic curve"
    case manual = "Manual"
}

// MARK: - Sensors & fan control

final class FanController {
    private let smc = SMCConnection()
    var mode: ControlMode = .curve
    var manualPercent: Double = 50
    var curve = FanCurve()
    private(set) var lastWriteOK = true
    private var lastAppliedPercent: Double = -1

    var isAvailable: Bool { smc != nil }

    /// Mean of the P-core temperature keys (Tp*) -- the hottest, most
    /// responsive proxy for CPU load on Apple Silicon.
    func cpuTemperature() -> Double? {
        guard let smc else { return nil }
        let temps = smc.allKeys()
            .filter { $0.hasPrefix("Tp") }
            .compactMap { smc.read($0)?.double }
            .filter { $0 > 1 && $0 < 130 }
        guard !temps.isEmpty else { return nil }
        return temps.max()
    }

    func fanRPM(_ fan: Int) -> (actual: Double, min: Double, max: Double)? {
        guard let smc,
              let actual = smc.read("F\(fan)Ac")?.double,
              let lo = smc.read("F\(fan)Mn")?.double,
              let hi = smc.read("F\(fan)Mx")?.double else { return nil }
        return (actual, lo, hi)
    }

    func fanCount() -> Int { Int(smc?.read("FNum")?.double ?? 0) }

    /// Apply the current mode. Writes need root (a privileged helper,
    /// planned); as a normal user process they fail and we report that
    /// instead of pretending control worked.
    func apply(cpuTemp: Double) {
        guard let smc else { return }
        switch mode {
        case .auto:
            if lastAppliedPercent != -2 {
                lastWriteOK = (0..<fanCount()).allSatisfy {
                    smc.write("F\($0)md", value: .uint8("F\($0)md", 0))
                }
                lastAppliedPercent = -2
            }
        case .curve, .manual:
            let percent = mode == .curve ? curve.percent(for: cpuTemp) : manualPercent
            guard abs(percent - lastAppliedPercent) >= 1 else { return }
            lastAppliedPercent = percent
            lastWriteOK = (0..<fanCount()).allSatisfy { fan in
                guard let range = fanRPM(fan) else { return false }
                let rpm = range.min + (range.max - range.min) * percent / 100.0
                return smc.write("F\(fan)md", value: .uint8("F\(fan)md", 1))
                    && smc.write("F\(fan)Tg", value: .float("F\(fan)Tg", rpm))
            }
        }
    }

    func restoreAuto() {
        guard let smc else { return }
        for fan in 0..<fanCount() { smc.write("F\(fan)md", value: .uint8("F\(fan)md", 0)) }
    }
}

// MARK: - Menu-bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = FanController()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if controller.mode != .auto { controller.restoreAuto() }
    }

    private func tick() {
        let temp = controller.cpuTemperature() ?? 0
        controller.apply(cpuTemp: temp)
        if let button = statusItem.button {
            let fan0 = controller.fanRPM(0)?.actual ?? 0
            button.title = String(format: "%.0f\u{00B0}C  %.0f rpm", temp, fan0)
        }
        statusItem.menu = buildMenu(cpuTemp: temp)
    }

    private func buildMenu(cpuTemp: Double) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(disabledItem(String(format: "CPU (max P-core): %.1f\u{00B0}C", cpuTemp)))
        for fan in 0..<controller.fanCount() {
            if let f = controller.fanRPM(fan) {
                menu.addItem(disabledItem(String(format: "Fan %d: %.0f rpm  (%.0f\u{2013}%.0f)", fan + 1, f.actual, f.min, f.max)))
            }
        }
        if controller.mode == .curve {
            menu.addItem(disabledItem(String(format: "Curve target: %.0f%%", controller.curve.percent(for: cpuTemp))))
        }
        if !controller.lastWriteOK && controller.mode != .auto {
            menu.addItem(disabledItem("Fan writes denied - privileged helper needed (see README)"))
        }
        if isMacsFanControlRunning() {
            menu.addItem(disabledItem("Warning: Macs Fan Control is running - quit it to avoid conflicts"))
        }

        menu.addItem(.separator())
        for mode in [ControlMode.auto, .curve, .manual] {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = controller.mode == mode ? .on : .off
            menu.addItem(item)
        }
        if controller.mode == .manual {
            for pct in [0.0, 25, 50, 75, 100] {
                let item = NSMenuItem(title: "Manual \(Int(pct))%", action: #selector(setManual(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pct
                item.state = controller.manualPercent == pct ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit coolmac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func isMacsFanControlRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").contains("macsfancontrol") || ($0.localizedName ?? "") == "Macs Fan Control"
        }
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = ControlMode(rawValue: raw) {
            controller.mode = mode
            tick()
        }
    }

    @objc private func setManual(_ sender: NSMenuItem) {
        if let pct = sender.representedObject as? Double {
            controller.manualPercent = pct
            controller.mode = .manual
            tick()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
