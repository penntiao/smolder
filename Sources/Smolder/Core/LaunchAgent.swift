import Foundation

/// Start at login and restart after a crash, via a per-user LaunchAgent.
/// A plain login item would not come back after a crash — and on a headless Mac nobody would notice.
enum LaunchAgent {
    static let label = "io.github.penntiao.smolder"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func install() throws {
        guard let executable = Bundle.main.executableURL?.path else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],   // quitting from the menu stays quit; a crash restarts
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "ThrottleInterval": 30,
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        // launchd starts a supervised copy right away; it asks this copy to step aside (see `SingleInstance`).
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    /// True when this process was started by our LaunchAgent.
    static var isSupervised: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

    /// Opened some other way (Finder, `open`, Homebrew reopening it after an upgrade) while the agent is
    /// installed: ask launchd to run the supervised copy instead. Returns false if launchd would not, in
    /// which case this copy keeps running unsupervised rather than leaving nothing running.
    static func handOverToLaunchd() -> Bool {
        guard isInstalled, !isSupervised else { return false }
        let target = "gui/\(getuid())/\(label)"
        if launchctl(["kickstart", target]) == 0 { return true }
        return launchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) == 0
    }

    static func uninstall() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
