import Foundation
import Darwin

/// Line-based Unix-socket protocol shared by the app and the root helper.
/// Commands: `PING`, `AUTO`, `SET <percent 0-100>`, `STATUS`
/// Replies:  `OK ...` or `ERR ...` (single line, connection then closes)
public enum HelperProtocol {
    public static var socketPath: String {
        ProcessInfo.processInfo.environment["COOLMAC_SOCKET"] ?? "/var/run/coolmac.sock"
    }

    public static func sockaddrUN(path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            for i in bytes.indices { dst[i] = bytes[i] }
        }
        return addr
    }

    /// Send one command; returns the reply line, or nil if the helper
    /// is not reachable (not installed / not running).
    public static func send(_ command: String, path: String = socketPath) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard var addr = sockaddrUN(path: path) else { return nil }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else { return nil }

        let line = command + "\n"
        _ = line.withCString { write(fd, $0, strlen($0)) }
        shutdown(fd, SHUT_WR)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer.prefix(n))
        }
        guard let reply = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { return nil }
        return reply
    }

    public static var isAvailable: Bool {
        send("PING")?.hasPrefix("OK") == true
    }
}
