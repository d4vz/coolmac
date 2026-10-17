import Foundation
import IOKit

// Clean-room SMC client built from the publicly documented AppleSMC
// user-client interface (as used by long-standing open-source projects
// such as smcFanControl / Stats). No proprietary app code is used.

public func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for b in s.utf8.prefix(4) { v = (v << 8) | UInt32(b) }
    return v
}

public func fourCCString(_ v: UInt32) -> String {
    String(bytes: [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                   UInt8((v >> 8) & 0xff), UInt8(v & 0xff)], encoding: .ascii) ?? "????"
}

private struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimitData { var version: UInt16 = 0, length: UInt16 = 0; var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
private struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0, p1: UInt8 = 0, p2: UInt8 = 0, p3: UInt8 = 0 }

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0, status: UInt8 = 0, data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private enum SMCCmd: UInt8 {
    case readBytes = 5, writeBytes = 6, readIndex = 8, readKeyInfo = 9
}

public struct SMCValue {
    public let key: String
    public let dataType: String
    public let bytes: [UInt8]

    public init(key: String, dataType: String, bytes: [UInt8]) {
        self.key = key
        self.dataType = dataType
        self.bytes = bytes
    }

    public static func float(_ key: String, _ value: Double) -> SMCValue {
        let bits = Float(value).bitPattern
        return SMCValue(key: key, dataType: "flt ", bytes: [
            UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
            UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff),
        ])
    }

    public static func uint8(_ key: String, _ value: UInt8) -> SMCValue {
        SMCValue(key: key, dataType: "ui8 ", bytes: [value])
    }

    public var double: Double? {
        switch dataType {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "si8 ":
            return bytes.first.map { Double(Int8(bitPattern: $0)) }
        default:
            return nil
        }
    }
}

public final class SMCConnection {
    private var conn: io_connect_t = 0

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ input: SMCKeyData) -> SMCKeyData? {
        var input = input
        var output = SMCKeyData()
        var outSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize)
        guard kr == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    public func keyInfo(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        var input = SMCKeyData()
        input.key = key
        input.data8 = SMCCmd.readKeyInfo.rawValue
        guard let out = call(input) else { return nil }
        return (out.keyInfo.dataSize, out.keyInfo.dataType)
    }

    public func read(_ keyName: String) -> SMCValue? {
        let key = fourCC(keyName)
        guard let info = keyInfo(key) else { return nil }
        var input = SMCKeyData()
        input.key = key
        input.keyInfo.dataSize = info.size
        input.data8 = SMCCmd.readBytes.rawValue
        guard let out = call(input) else { return nil }
        var bytes = withUnsafeBytes(of: out.bytes) { Array($0) }
        bytes = Array(bytes.prefix(Int(info.size)))
        return SMCValue(key: keyName, dataType: fourCCString(info.type), bytes: bytes)
    }

    /// Write raw bytes. Fan writes normally require root; callers must opt in.
    @discardableResult
    public func write(_ keyName: String, value: SMCValue) -> Bool {
        let key = fourCC(keyName)
        guard let info = keyInfo(key) else { return false }
        var input = SMCKeyData()
        input.key = key
        input.keyInfo.dataSize = info.size
        input.data8 = SMCCmd.writeBytes.rawValue
        var raw = value.bytes
        while raw.count < 32 { raw.append(0) }
        withUnsafeMutableBytes(of: &input.bytes) { dst in
            for i in 0..<32 { dst[i] = raw[i] }
        }
        return call(input) != nil
    }

    public func allKeys() -> [String] {
        guard let countVal = read("#KEY"), let count = countVal.double else { return [] }
        var keys: [String] = []
        for i in 0..<Int(count) {
            var input = SMCKeyData()
            input.data8 = SMCCmd.readIndex.rawValue
            input.data32 = UInt32(i)
            guard let out = call(input) else { continue }
            keys.append(fourCCString(out.key))
        }
        return keys
    }
}
