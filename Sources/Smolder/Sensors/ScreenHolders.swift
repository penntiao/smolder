import Darwin
import Foundation
import IOKit.pwr_mgt

/// Which programs are keeping a screen awake — a video, a presentation, a remote-desktop session. A lit screen
/// keeps minutes out of the idle-power judgement, and on a closed Mac a remote desktop is usually what lit it:
/// these names say whose lit minutes they were. Recorded only; no detector uses them. No root needed.
enum ScreenHolders {
    /// Assertion types that keep a display from idling to sleep (`pmset -g assertions` shows the same list).
    static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// Names of the processes holding a display assertion right now; nil when the list cannot be read.
    static func read() -> Set<String>? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byPID = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        var names = Set<String>()
        for (pid, assertions) in byPID
        where assertions.contains(where: { displayTypes.contains($0["AssertType"] as? String ?? "") }) {
            names.insert(processName(pid.int32Value) ?? "pid \(pid)")
        }
        return names
    }

    /// Seconds of one minute each program held a screen awake, from that minute's readings (one set per reading,
    /// nil where the list could not be read). Readings that failed do not count either way.
    static func seconds(_ readings: [Set<String>?]) -> [String: Int] {
        let read = readings.compactMap { $0 }
        guard !read.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        for names in read { for name in names { counts[name, default: 0] += 1 } }
        return counts.mapValues { Int((60 * Double($0) / Double(read.count)).rounded()) }
    }

    private static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
