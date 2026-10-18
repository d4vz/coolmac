import Foundation
import SMC
import CoolMacShared

// MARK: - Fan curve

/// Dynamic fan curve: CPU temperature (C) -> fan speed (% of each fan's range).
/// Speed is interpolated linearly between points, so fans ramp smoothly
/// with temperature instead of jumping between fixed steps.
struct FanCurve {
    static let defaultPoints: [(temp: Double, percent: Double)] = [
        (40, 0), (55, 25), (70, 50), (85, 75), (95, 100),
    ]
    static let silentPoints: [(temp: Double, percent: Double)] = [
        (40, 0), (60, 15), (75, 30), (90, 50), (100, 70),
    ]
    static let minTempGap: Double = 1
    static let pointCount = 5

    var points: [(temp: Double, percent: Double)]

    init() { points = Self.defaultPoints }

    init(points raw: [(temp: Double, percent: Double)]) {
        points = Self.sanitize(raw) ?? Self.defaultPoints
    }

    /// Accepts persisted `[[temp, percent], …]`. Any malformed data
    /// (wrong count, non-finite, non-increasing with < min gap)
    /// sanitizes back to the default curve rather than crashing.
    init(persisted raw: [[Double]]) {
        let tuples = raw.map { pair -> (temp: Double, percent: Double)? in
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        }
        if tuples.contains(where: { $0 == nil }) {
            points = Self.defaultPoints
        } else {
            points = Self.sanitize(tuples.compactMap { $0 }) ?? Self.defaultPoints
        }
    }

    static func sanitize(_ raw: [(temp: Double, percent: Double)])
        -> [(temp: Double, percent: Double)]? {
        guard raw.count == pointCount,
              raw.allSatisfy({ $0.temp.isFinite && $0.percent.isFinite }) else { return nil }
        let clamped = raw.sorted { $0.temp < $1.temp }.map {
            (temp: min(100, max(30, $0.temp)), percent: min(100, max(0, $0.percent)))
        }
        for i in 1..<clamped.count where clamped[i].temp - clamped[i - 1].temp < minTempGap {
            return nil
        }
        return clamped
    }

    static func asArrays(_ pts: [(temp: Double, percent: Double)]) -> [[Double]] {
        pts.map { [$0.temp, $0.percent] }
    }

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
    /// Main-owned state, snapshotted in by FanViewModel on ioQueue.
    var linkFans: Bool = true
    var fanPercents: [Double] = [50, 50]
    private(set) var lastWriteOK = true
    private(set) var helperAvailable = false
    private var lastAppliedPercent: Double = -1
    private var lastAppliedFanPercents: [Double] = []

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
    /// Percent applied to a specific fan (direct-write path / SET2).
    func percent(forFan fan: Int, cpuTemp: Double) -> Double {
        switch mode {
        case .auto: return -1
        case .curve: return curve.percent(for: cpuTemp)
        case .manual:
            if linkFans { return manualPercent }
            guard !fanPercents.isEmpty else { return manualPercent }
            return fanPercents[min(fan, fanPercents.count - 1)]
        }
    }

    func apply(cpuTemp: Double) {
        let command: String
        var fallbackPercent: Double?
        switch mode {
        case .auto:
            command = "AUTO"
        case .curve:
            // Curve is shared by both fans even when unlinked.
            command = String(format: "SET %.0f", curve.percent(for: cpuTemp))
        case .manual:
            if linkFans {
                command = String(format: "SET %.0f", manualPercent)
            } else {
                let p = (0..<max(2, fanPercents.count)).map {
                    min(100, max(0, fanPercents[min($0, fanPercents.count - 1)]))
                }
                command = "SET2 " + p.map { String(format: "%.0f", $0) }.joined(separator: " ")
                fallbackPercent = p.max()
            }
        }

        if let reply = HelperProtocol.send(command) {
            helperAvailable = true
            if reply.hasPrefix("OK") {
                lastWriteOK = true
            } else if let fallbackPercent {
                // Old helper without SET2: degrade to linked SET, never fatal.
                if let fallback = HelperProtocol.send(String(format: "SET %.0f", fallbackPercent)) {
                    lastWriteOK = fallback.hasPrefix("OK")
                } else {
                    lastWriteOK = false
                }
            } else {
                lastWriteOK = false
            }
            lastAppliedPercent = -1 // helper owns dedupe state
            lastAppliedFanPercents = []
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
                lastAppliedFanPercents = []
            }
        case .curve, .manual:
            let count = fanCount()
            let percents = (0..<count).map { percent(forFan: $0, cpuTemp: cpuTemp) }
            let changed = percents.count != lastAppliedFanPercents.count
                || zip(percents, lastAppliedFanPercents).contains { abs($0 - $1) >= 1 }
            guard changed else { return }
            lastAppliedFanPercents = percents
            lastAppliedPercent = percents.first ?? -1
            lastWriteOK = (0..<count).allSatisfy { fan in
                guard let range = fanRPM(fan) else { return false }
                let rpm = range.min + (range.max - range.min) * percents[fan] / 100.0
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
