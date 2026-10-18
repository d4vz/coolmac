import Foundation
import AppKit

struct FanInfo: Identifiable {
    let id: Int
    let actual: Double
    let minRPM: Double
    let maxRPM: Double

    var fraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(1, max(0, (actual - minRPM) / (maxRPM - minRPM)))
    }
    func rpm(atPercent percent: Double) -> Double {
        minRPM + (maxRPM - minRPM) * percent / 100.0
    }
}

/// UI state lives on the main thread; all sensor/helper I/O lives on
/// `ioQueue`. `FanController`/`SMCConnection` are not thread-safe, so
/// every access to `controller` happens inside a block on that one
/// serial queue — background refreshes, slider applies and the quit
/// path can never race the IOKit connection or each other.
///
/// Synchronization rule: `mode`/`manualPercent` below are the source
/// of truth and are only mutated on main. Queue work never reads them
/// directly; the main-thread entry points snapshot them (and
/// `cpuTemp`) as plain values and pass the snapshot in, and the queue
/// work writes the snapshot into `controller` before using it.
/// `@Published` results are only ever assigned inside
/// `DispatchQueue.main.async` blocks.
final class FanViewModel: ObservableObject {
    @Published private(set) var cpuTemp: Double = 0
    @Published private(set) var fans: [FanInfo] = []
    @Published private(set) var helperConnected = false
    @Published private(set) var lastWriteOK = true
    @Published private(set) var conflictingAppRunning = false
    @Published var mode: ControlMode = .curve {
        didSet {
            guard mode != oldValue else { return }
            applyNow()
        }
    }
    @Published var manualPercent: Double = 50

    let controller = FanController()
    let curvePoints: [(temp: Double, percent: Double)] = FanCurve().points
    private let curve = FanCurve()

    /// Serial queue owning all SMC + helper-socket access.
    private let ioQueue = DispatchQueue(label: "com.coolmac.sensor-io")
    /// Main-thread only: a refresh already queued/running makes timer
    /// ticks no-ops instead of piling up behind a slow helper socket.
    private var refreshInFlight = false

    /// Called on main after a refresh publishes fresh values
    /// (AppDelegate uses it to update the menu-bar title immediately
    /// rather than one timer tick late).
    var onRefreshPublished: (() -> Void)?

    /// Computed on main from main-owned state — deliberately does not
    /// touch `controller` (queue-owned) from here.
    var targetPercent: Double {
        switch mode {
        case .auto: return -1
        case .curve: return curve.percent(for: cpuTemp)
        case .manual: return manualPercent
        }
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let modeSnapshot = mode
        let manualSnapshot = manualPercent
        let fallbackTemp = cpuTemp
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.controller.mode = modeSnapshot
            self.controller.manualPercent = manualSnapshot
            let temp = self.controller.cpuTemperature() ?? fallbackTemp
            // Watchdog heartbeat: this apply (SET/AUTO to the helper)
            // runs on every refresh tick, just off the main thread.
            self.controller.apply(cpuTemp: temp)
            let helper = self.controller.helperAvailable
            let writeOK = self.controller.lastWriteOK
            let fans = (0..<self.controller.fanCount()).compactMap { i -> FanInfo? in
                guard let f = self.controller.fanRPM(i) else { return nil }
                return FanInfo(id: i, actual: f.actual, minRPM: f.min, maxRPM: f.max)
            }
            DispatchQueue.main.async {
                self.refreshInFlight = false
                self.cpuTemp = temp
                self.helperConnected = helper
                self.lastWriteOK = writeOK
                self.fans = fans
                self.conflictingAppRunning = NSWorkspace.shared.runningApplications.contains {
                    ($0.bundleIdentifier ?? "").contains("macsfancontrol")
                        || ($0.localizedName ?? "") == "Macs Fan Control"
                }
                self.onRefreshPublished?()
            }
        }
    }

    /// Slider dragged: switch to Manual and push the new value now,
    /// without re-reading every sensor key.
    func sliderChanged() {
        if mode != .manual {
            // Setting `mode` fires didSet -> applyNow(), which already
            // snapshots the latest `manualPercent`.
            mode = .manual
            return
        }
        applyNow()
    }

    func applyNow() {
        let modeSnapshot = mode
        let manualSnapshot = manualPercent
        let tempSnapshot = cpuTemp
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.controller.mode = modeSnapshot
            self.controller.manualPercent = manualSnapshot
            self.controller.apply(cpuTemp: tempSnapshot)
            let helper = self.controller.helperAvailable
            let writeOK = self.controller.lastWriteOK
            DispatchQueue.main.async {
                self.helperConnected = helper
                self.lastWriteOK = writeOK
            }
        }
    }

    func restoreAuto() {
        if mode != .auto { mode = .auto }
        let tempSnapshot = cpuTemp
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.controller.mode = .auto
            self.controller.apply(cpuTemp: tempSnapshot)
            self.controller.restoreAuto()
            let helper = self.controller.helperAvailable
            let writeOK = self.controller.lastWriteOK
            DispatchQueue.main.async {
                self.helperConnected = helper
                self.lastWriteOK = writeOK
            }
        }
    }

    /// Synchronous final AUTO for quit: waits for any in-flight
    /// refresh/apply on the serial queue, then restores Auto through
    /// that same queue so it can't race the connection. Blocking the
    /// main thread briefly here is intentional — the process is
    /// exiting and the fans must not be left in a manual mode.
    func restoreAutoSync() {
        ioQueue.sync {
            controller.mode = .auto
            controller.restoreAuto()
        }
    }
}
