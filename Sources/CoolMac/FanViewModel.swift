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

enum FanPreset: String, CaseIterable, Identifiable {
    case silent = "Silent"
    case balanced = "Balanced"
    case fullBlast = "Full blast"
    var id: String { rawValue }
}

/// UI state lives on the main thread; all sensor/helper I/O lives on
/// `ioQueue`. `FanController`/`SMCConnection` are not thread-safe, so
/// every access to `controller` happens inside a block on that one
/// serial queue — background refreshes, slider applies and the quit
/// path can never race the IOKit connection or each other.
///
/// Synchronization rule: `mode`/`manualPercent`/`curvePoints`/
/// `linkFans`/`fanPercents` below are the source of truth and are only
/// mutated on main. Queue work never reads them directly; the
/// main-thread entry points snapshot them as plain values and pass
/// the snapshot in, and the queue work writes the snapshot into
/// `controller` before using it.
/// `@Published` results are only ever assigned inside
/// `DispatchQueue.main.async` blocks (the persisted settings above are
/// main-owned inputs, mutated only from UI actions on main).
final class FanViewModel: ObservableObject {
    private enum Keys {
        static let curvePoints = "curvePoints"       // [[temp, percent]]
        static let activePreset = "activePreset"     // FanPreset rawValue
        static let linkFans = "linkFans"             // Bool
        static let fanPercents = "manualFanPercents" // [Double]
        static let manualPercent = "manualPercent"   // Double
    }

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
    @Published var manualPercent: Double {
        didSet { UserDefaults.standard.set(manualPercent, forKey: Keys.manualPercent) }
    }
    @Published var curvePoints: [(temp: Double, percent: Double)] {
        didSet {
            UserDefaults.standard.set(
                FanCurve.asArrays(curvePoints), forKey: Keys.curvePoints)
        }
    }
    @Published var activePreset: String? {
        didSet {
            if let activePreset {
                UserDefaults.standard.set(activePreset, forKey: Keys.activePreset)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.activePreset)
            }
        }
    }
    @Published var linkFans: Bool {
        didSet {
            UserDefaults.standard.set(linkFans, forKey: Keys.linkFans)
            if linkFans != oldValue { applyNow() }
        }
    }
    @Published var fanPercents: [Double] {
        didSet { UserDefaults.standard.set(fanPercents, forKey: Keys.fanPercents) }
    }
    @Published var launchAtLogin: Bool

    let controller = FanController()

    /// Serial queue owning all SMC + helper-socket access.
    private let ioQueue = DispatchQueue(label: "com.coolmac.sensor-io")
    private var refreshInFlight = false

    var onRefreshPublished: (() -> Void)?

    init() {
        let d = UserDefaults.standard
        // Go through NSNumber: `defaults write` may store integers,
        // which do not always bridge in a direct `[Double]` cast.
        func doubles(_ value: Any?) -> [Double] {
            (value as? [Any])?.compactMap {
                ($0 as? NSNumber)?.doubleValue ?? ($0 as? String).flatMap(Double.init)
            } ?? []
        }
        let savedCurve = (d.array(forKey: Keys.curvePoints) ?? []).map { doubles($0) }
        if !savedCurve.isEmpty {
            curvePoints = FanCurve(persisted: savedCurve).points
        } else {
            curvePoints = FanCurve.defaultPoints
        }
        let savedManual = (d.object(forKey: Keys.manualPercent) as? NSNumber)?.doubleValue ?? 50
        manualPercent = savedManual
        let savedFans = doubles(d.array(forKey: Keys.fanPercents))
        fanPercents = (0..<2).map { i in
            min(100, max(0, i < savedFans.count ? savedFans[i] : savedManual))
        }
        linkFans = d.object(forKey: Keys.linkFans) as? Bool ?? true
        activePreset = d.string(forKey: Keys.activePreset)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private var curve: FanCurve { FanCurve(points: curvePoints) }

    var targetPercent: Double {
        switch mode {
        case .auto: return -1
        case .curve: return curve.percent(for: cpuTemp)
        case .manual: return manualPercent
        }
    }

    // MARK: - Curve editing & presets

    /// Clamps temp between neighbours (min gap, 30–100 °C) and
    /// percent to 0–100, persists, and live-applies via applyNow.
    func updateCurvePoint(index: Int, temp: Double? = nil, percent: Double? = nil) {
        guard curvePoints.indices.contains(index) else { return }
        var pts = curvePoints
        if let temp {
            let lower = index > 0
                ? pts[index - 1].temp + FanCurve.minTempGap : 30
            let upper = index < pts.count - 1
                ? pts[index + 1].temp - FanCurve.minTempGap : 100
            pts[index].temp = min(upper, max(lower, temp))
        }
        if let percent {
            pts[index].percent = min(100, max(0, percent))
        }
        curvePoints = pts
        activePreset = nil
        if mode == .curve { applyNow() }
    }

    func resetCurve() {
        curvePoints = FanCurve.defaultPoints
        activePreset = nil
        if mode == .curve { applyNow() }
    }

    func applyPreset(_ preset: FanPreset) {
        switch preset {
        case .silent:
            curvePoints = FanCurve.silentPoints
            if mode == .curve { applyNow() } else { mode = .curve }
        case .balanced:
            curvePoints = FanCurve.defaultPoints
            if mode == .curve { applyNow() } else { mode = .curve }
        case .fullBlast:
            fanPercents = [100, 100]
            manualPercent = 100
            if mode == .manual { applyNow() } else { mode = .manual }
        }
        // Last, so any onChange-driven apply above can't clear it.
        activePreset = preset.rawValue
    }

    private func clearPresetAfterManualEdit() {
        guard let activePreset else { return }
        if activePreset == FanPreset.fullBlast.rawValue,
           mode == .manual, manualPercent == 100 {
            return // Full blast stays highlighted at manual 100%.
        }
        self.activePreset = nil
    }

    // MARK: - Launch at login

    var canLaunchAtLogin: Bool { LaunchAtLogin.isAppBundle }

    func setLaunchAtLogin(_ on: Bool) {
        guard LaunchAtLogin.isAppBundle else {
            launchAtLogin = false
            return
        }
        LaunchAtLogin.setEnabled(on)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    // MARK: - Refresh / apply (ioQueue snapshots)

    private struct Snapshot {
        let mode: ControlMode
        let manual: Double
        let curvePoints: [(temp: Double, percent: Double)]
        let linkFans: Bool
        let fanPercents: [Double]
    }

    private func snapshot() -> Snapshot {
        Snapshot(mode: mode, manual: manualPercent, curvePoints: curvePoints,
                 linkFans: linkFans, fanPercents: fanPercents)
    }

    private func writeSnapshot(_ s: Snapshot, into c: FanController) {
        c.mode = s.mode
        c.manualPercent = s.manual
        c.curve = FanCurve(points: s.curvePoints)
        c.linkFans = s.linkFans
        c.fanPercents = s.fanPercents
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let snap = snapshot()
        let fallbackTemp = cpuTemp
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.writeSnapshot(snap, into: self.controller)
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
        clearPresetAfterManualEdit()
        if mode != .manual {
            mode = .manual
            return
        }
        applyNow()
    }

    /// Per-fan (unlinked) slider dragged in Manual mode.
    func fanSliderChanged() {
        if !(activePreset == FanPreset.fullBlast.rawValue
             && fanPercents.allSatisfy({ $0 == 100 })) {
            activePreset = nil
        }
        applyNow()
    }

    func applyNow() {
        let snap = snapshot()
        let tempSnapshot = cpuTemp
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.writeSnapshot(snap, into: self.controller)
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
    /// that same queue so it can't race the connection.
    func restoreAutoSync() {
        ioQueue.sync {
            controller.mode = .auto
            controller.restoreAuto()
        }
    }
}
