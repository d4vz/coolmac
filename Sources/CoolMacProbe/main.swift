import Foundation
import SMC

// Read-only probe: enumerates SMC keys and prints fan (F*) and
// temperature (T*) values so we can see what this machine exposes.
// It never writes to the SMC.

guard let smc = SMCConnection() else {
    print("ERROR: could not open AppleSMC service")
    exit(1)
}

let keys = smc.allKeys()
print("Total SMC keys: \(keys.count)")
print("Fan keys:  \(keys.filter { $0.hasPrefix("F") }.sorted())")
print("Temp keys: \(keys.filter { $0.hasPrefix("T") }.sorted())")
print("")

func dump(_ key: String) {
    guard let v = smc.read(key) else { print("  \(key): <unreadable>"); return }
    if let d = v.double {
        print("  \(key) [\(v.dataType)] = \(String(format: "%.2f", d))  bytes=\(v.bytes)")
    } else {
        print("  \(key) [\(v.dataType)] bytes=\(v.bytes)")
    }
}

print("== Fans ==")
if let n = smc.read("FNum")?.double { print("  Fan count: \(Int(n))") }
for key in keys.filter({ $0.hasPrefix("F") }).sorted() { dump(key) }

print("\n== Temperatures (non-zero only) ==")
for key in keys.filter({ $0.hasPrefix("T") }).sorted() {
    guard let v = smc.read(key), let d = v.double, d > 1, d < 130 else { continue }
    print("  \(key) [\(v.dataType)] = \(String(format: "%.1f", d)) C")
}
