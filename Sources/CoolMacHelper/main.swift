import Foundation
import Darwin
import SMC
import CoolMacShared

// coolmac-helper: privileged (root) daemon. The ONLY component allowed
// to write fan keys. Listens on a Unix socket, accepts one line-based
// command per connection, and reverts fans to system Auto if the app
// stops talking (watchdog) so a crash can never strand fans in manual.

func log(_ message: String) {
    FileHandle.standardError.write(Data("[coolmac-helper] \(message)\n".utf8))
}

signal(SIGPIPE, SIG_IGN)

guard let smc = SMCConnection() else {
    log("FATAL: could not open AppleSMC")
    exit(1)
}

let smcLock = NSLock()
var manual = false
var lastPercent: Double = -1
/// Per-fan percents last successfully applied (normalized to fan count).
var lastPercents: [Double] = []
var lastSeen = Date()
let stateLock = NSLock()

func fanCount() -> Int { Int(smc.read("FNum")?.double ?? 0) }

@discardableResult
func setAuto() -> Bool {
    smcLock.lock(); defer { smcLock.unlock() }
    let ok = (0..<fanCount()).allSatisfy { smc.write("F\($0)md", value: .uint8("F\($0)md", 0)) }
    if ok {
        stateLock.lock(); manual = false; lastPercent = -1; lastPercents = []; stateLock.unlock()
    }
    return ok
}

/// Per-fan set: extra percents are ignored; fans beyond the supplied
/// list repeat the last supplied value (so `SET2 40` == `SET 40`).
@discardableResult
func setPercents(_ percents: [Double]) -> Bool {
    guard !percents.isEmpty else { return false }
    let count = fanCount()
    guard count > 0 else { return false }
    let normalized = (0..<count).map { fan in
        min(100, max(0, percents[min(fan, percents.count - 1)]))
    }
    stateLock.lock()
    let unchanged = manual && normalized.count == lastPercents.count
        && zip(normalized, lastPercents).allSatisfy { abs($0 - $1) < 1 }
    stateLock.unlock()
    if unchanged { return true }

    smcLock.lock(); defer { smcLock.unlock() }
    var ok = true
    for fan in 0..<count {
        guard let lo = smc.read("F\(fan)Mn")?.double,
              let hi = smc.read("F\(fan)Mx")?.double else { ok = false; continue }
        let rpm = lo + (hi - lo) * normalized[fan] / 100.0
        ok = smc.write("F\(fan)md", value: .uint8("F\(fan)md", 1)) && ok
        ok = smc.write("F\(fan)Tg", value: .float("F\(fan)Tg", rpm)) && ok
    }
    if ok {
        stateLock.lock(); manual = true; lastPercents = normalized
        lastPercent = normalized.first ?? -1; stateLock.unlock()
    }
    return ok
}

@discardableResult
func setPercent(_ percent: Double) -> Bool { setPercents([percent]) }

func status() -> String {
    smcLock.lock(); defer { smcLock.unlock() }
    var parts: [String] = []
    for fan in 0..<fanCount() {
        let ac = smc.read("F\(fan)Ac")?.double ?? -1
        let tg = smc.read("F\(fan)Tg")?.double ?? -1
        let md = smc.read("F\(fan)md")?.double ?? -1
        parts.append(String(format: "fan%d=%.0f/%.0f mode=%.0f", fan, ac, tg, md))
    }
    return parts.joined(separator: " ")
}

/// Only root and the logged-in console user may command the fans.
func peerAllowed(_ fd: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0 else { return false }
    if uid == 0 { return true }
    var st = stat()
    guard stat("/dev/console", &st) == 0 else { return false }
    return uid == st.st_uid
}

func handle(_ command: String) -> String {
    stateLock.lock(); lastSeen = Date(); stateLock.unlock()
    let parts = command.split(separator: " ")
    guard let verb = parts.first else { return "ERR empty" }
    switch String(verb) {
    case "PING":
        return "OK pong"
    case "AUTO":
        return setAuto() ? "OK auto" : "ERR smc-write-failed"
    case "SET":
        guard parts.count == 2, let pct = Double(parts[1]) else { return "ERR usage: SET <0-100>" }
        return setPercent(pct) ? "OK set \(Int(min(100, max(0, pct))))%" : "ERR smc-write-failed"
    case "SET2":
        let pcts = parts.dropFirst().compactMap { Double($0) }
        guard !pcts.isEmpty, pcts.count == parts.count - 1 else { return "ERR usage: SET2 <0-100> [<0-100> ...]" }
        let clamped = pcts.map { min(100, max(0, $0)) }
        return setPercents(clamped)
            ? "OK set2 " + clamped.map { "\(Int($0))%" }.joined(separator: " ")
            : "ERR smc-write-failed"
    case "STATUS":
        return "OK " + status()
    default:
        return "ERR unknown-command"
    }
}

// Watchdog: manual control with no command for 15s -> back to Auto.
DispatchQueue.global().async {
    while true {
        Thread.sleep(forTimeInterval: 5)
        stateLock.lock()
        let stale = manual && Date().timeIntervalSince(lastSeen) > 15
        stateLock.unlock()
        if stale {
            log("watchdog: no command for >15s, reverting to Auto")
            setAuto()
        }
    }
}

// MARK: - Socket server

let path = HelperProtocol.socketPath
unlink(path)
let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard serverFD >= 0, var addr = HelperProtocol.sockaddrUN(path: path) else {
    log("FATAL: could not create socket at \(path)")
    exit(1)
}
let bindResult = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0, listen(serverFD, 16) == 0 else {
    log("FATAL: bind/listen failed at \(path): \(String(cString: strerror(errno)))")
    exit(1)
}
chmod(path, 0o660)
if getuid() == 0, let admin = getgrnam("admin") {
    chown(path, 0, admin.pointee.gr_gid)
}
log("listening on \(path)")

while true {
    let client = accept(serverFD, nil, nil)
    if client < 0 { continue }
    if !peerAllowed(client) {
        _ = "ERR forbidden\n".withCString { write(client, $0, strlen($0)) }
        close(client)
        continue
    }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 512)
    while true {
        let n = read(client, &buffer, buffer.count)
        if n <= 0 { break }
        data.append(contentsOf: buffer.prefix(n))
        if data.contains(UInt8(ascii: "\n")) { break }
    }
    let command = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let reply = handle(command) + "\n"
    _ = reply.withCString { write(client, $0, strlen($0)) }
    close(client)
}
