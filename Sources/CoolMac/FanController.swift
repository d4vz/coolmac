import Foundation
import SMC
import CoolMacShared

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

enum ControlMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case curve = "Curve"
    case manual = "Manual"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic (system)"
        case .curve: return "Dynamic curve"
        case .manual: return "Manual"
        }
    }
}

// MARK: - Sensors & fan control

/// Not thread-safe by design: a single IOKit connection plus mutable
/// state (`mode`, `manualPercent`, caches below, dedupe state).
/// Every call into this class — SMC reads/writes and helper sends —
/// is confined to `FanViewModel`'s dedicated serial queue (the quit
/// path reaches it through that same queue synchronously), so no
/// locking is needed in here as long as callers keep that rule.
final class FanController {
    private let smc = SMCConnection()
    var mode: ControlMode = .curve
    var manualPercent: Double = 50
    var curve = FanCurve()
    private(set) var lastWriteOK = true
    private(set) var helperAvailable = false
    private var lastAppliedPercent: Double = -1

    /// Enumerating every SMC key costs ~3,700 IOKit calls (~0.7–0.9 s),
    /// so do it once and reuse the Tp* subset. Only a successful,
    /// non-empty enumeration is cached, so a transient failure retries
    /// on the next refresh instead of disabling temperature reads.
    private var cachedTempKeys: [String]?
    private var cachedFanCount: Int?

    var isAvailable: Bool { smc != nil }

    /// Hottest P-core temperature key (Tp*) — the most responsive
    /// proxy for CPU load on Apple Silicon.
    func cpuTemperature() -> Double? {
        guard let smc else { return nil }
        let tempKeys: [String]
        if let cachedTempKeys {
            tempKeys = cachedTempKeys
        } else {
            tempKeys = smc.allKeys().filter { $0.hasPrefix("Tp") }
            if !tempKeys.isEmpty { cachedTempKeys = tempKeys }
        }
        let temps = tempKeys
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

    func fanCount() -> Int {
        if let cachedFanCount { return cachedFanCount }
        let count = Int(smc?.read("FNum")?.double ?? 0)
        if count > 0 { cachedFanCount = count }
        return count
    }

    func targetPercent(cpuTemp: Double) -> Double {
        switch mode {
        case .auto: return -1
        case .curve: return curve.percent(for: cpuTemp)
        case .manual: return manualPercent
        }
    }

    /// Preferred path: the root helper over its Unix socket (called on
    /// every tick — it dedupes, and its watchdog reverts to Auto if we
    /// go silent). Fallback: a direct SMC write, which normally fails
    /// without root; we report that, never fake it.
    func apply(cpuTemp: Double) {
        let command: String
        switch mode {
        case .auto:
            command = "AUTO"
        case .curve:
            command = String(format: "SET %.0f", curve.percent(for: cpuTemp))
        case .manual:
            command = String(format: "SET %.0f", manualPercent)
        }

        if let reply = HelperProtocol.send(command) {
            helperAvailable = true
            lastWriteOK = reply.hasPrefix("OK")
            lastAppliedPercent = -1 // helper owns dedupe state
            return
        }
        helperAvailable = false
        applyDirect(cpuTemp: cpuTemp)
    }

    private func applyDirect(cpuTemp: Double) {
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
        if HelperProtocol.send("AUTO") != nil { return }
        guard let smc else { return }
        for fan in 0..<fanCount() { smc.write("F\(fan)md", value: .uint8("F\(fan)md", 0)) }
    }
}
