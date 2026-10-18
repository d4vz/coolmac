import Foundation

/// Launch at login via a per-user LaunchAgent (no admin needed).
/// Only meaningful from a real .app bundle; the bare SwiftPM binary
/// disables the toggle in the UI.
enum LaunchAtLogin {
    static let label = "com.github.d4vz.coolmac"

    static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Direct executable inside the bundle (Contents/MacOS/CoolMac).
    static var executablePath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/CoolMac").path
    }

    private static func launchctl(_ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }

    private static var guiDomain: String { "gui/\(getuid())" }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        let fm = FileManager.default
        if on {
            guard isAppBundle else { return false }
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executablePath],
                "RunAtLoad": true,
            ]
            do {
                try fm.createDirectory(
                    at: plistURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(
                    fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: plistURL, options: .atomic)
            } catch {
                return false
            }
            launchctl(["bootout", "\(guiDomain)/\(label)"])
            launchctl(["bootstrap", guiDomain, plistURL.path])
            return isEnabled
        }
        launchctl(["bootout", "\(guiDomain)/\(label)"])
        try? fm.removeItem(at: plistURL)
        return !isEnabled
    }
}
