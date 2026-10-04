import Foundation

struct ProcessUsage: Codable, Hashable {
    var pid: Int32
    var name: String      // executable name, for display
    var path: String      // full path, used as the program identity
    var cores: Double     // average cores used between two samples
}

/// Reads cumulative CPU time of every process via /bin/ps (setuid root, so root processes are visible
/// without privileges) and turns two snapshots into a rate.
final class ProcessSampler {
    private struct Entry { var path: String; var cpuSeconds: Double }
    private var previous: [Int32: Entry] = [:]
    private var previousAt: Date?

    func sample() -> [ProcessUsage] {
        let now = Date()
        guard let output = Self.runPS() else { return [] }
        var current: [Int32: Entry] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let seconds = Self.parseCPUTime(String(fields[1])) else { continue }
            current[pid] = Entry(path: String(fields[2]), cpuSeconds: seconds)
        }
        defer { previous = current; previousAt = now }
        guard let previousAt else { return [] }
        let elapsed = now.timeIntervalSince(previousAt)
        guard elapsed > 0.5 else { return [] }

        var result: [ProcessUsage] = []
        for (pid, entry) in current {
            // A reused pid running a different program is a new process
            guard let old = previous[pid], old.path == entry.path else { continue }
            let delta = entry.cpuSeconds - old.cpuSeconds
            guard delta > 0 else { continue }
            let name = (entry.path as NSString).lastPathComponent
            result.append(ProcessUsage(pid: pid, name: name, path: entry.path, cores: delta / elapsed))
        }
        return result.sorted { $0.cores > $1.cores }
    }

    /// Parses ps CPU time: `mm:ss.ss`, `hh:mm:ss` and `d-hh:mm:ss` all occur.
    static func parseCPUTime(_ text: String) -> Double? {
        var days = 0.0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        var seconds = 0.0
        for value in values { seconds = seconds * 60 + value }
        return days * 86400 + seconds
    }

    private static func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Axo", "pid=,time=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
