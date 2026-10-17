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

/// Updated only from the main run loop (AppDelegate timer + SwiftUI bindings).
final class FanViewModel: ObservableObject {
    @Published private(set) var cpuTemp: Double = 0
    @Published private(set) var fans: [FanInfo] = []
    @Published private(set) var helperConnected = false
    @Published private(set) var lastWriteOK = true
    @Published private(set) var conflictingAppRunning = false
    @Published var mode: ControlMode = .curve {
        didSet {
            guard mode != oldValue else { return }
            controller.mode = mode
            applyNow()
        }
    }
    @Published var manualPercent: Double = 50 {
        didSet {
            controller.manualPercent = manualPercent
        }
    }

    let controller = FanController()
    let curvePoints: [(temp: Double, percent: Double)] = FanCurve().points

    var targetPercent: Double { controller.targetPercent(cpuTemp: cpuTemp) }

    func refresh() {
        let temp = controller.cpuTemperature() ?? cpuTemp
        cpuTemp = temp
        controller.apply(cpuTemp: temp)
        helperConnected = controller.helperAvailable
        lastWriteOK = controller.lastWriteOK
        fans = (0..<controller.fanCount()).compactMap { i in
            guard let f = controller.fanRPM(i) else { return nil }
            return FanInfo(id: i, actual: f.actual, minRPM: f.min, maxRPM: f.max)
        }
        conflictingAppRunning = NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").contains("macsfancontrol")
                || ($0.localizedName ?? "") == "Macs Fan Control"
        }
    }

    /// Slider dragged: switch to Manual and push the new value now,
    /// without re-reading every sensor key.
    func sliderChanged() {
        if mode != .manual { mode = .manual }
        controller.manualPercent = manualPercent
        applyNow()
    }

    func applyNow() {
        controller.apply(cpuTemp: cpuTemp)
        helperConnected = controller.helperAvailable
        lastWriteOK = controller.lastWriteOK
    }

    func restoreAuto() {
        mode = .auto
        controller.restoreAuto()
    }
}
