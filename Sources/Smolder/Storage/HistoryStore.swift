import Foundation
import SQLite3

/// One row per minute: feeds the charts, the learned baselines and later forensics.
struct MinuteSample: Codable, Equatable {
    var timestamp: Date
    var dieMax: Double?
    var dieAvg: Double?
    var ssd: Double?
    var battery: Double?
    var power: Double?        // whole-system power, watts
    var cpuCores: Double?     // whole-system CPU usage, cores
    var thermalState: Int     // PressureLevel raw value
    var expectedDie: Double?  // die temperature the thermal model expected
}

final class HistoryStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "smolder.history")
    let retentionDays: Int

    init(url: URL, retentionDays: Int = 90) throws {
        self.retentionDays = retentionDays
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw NSError(domain: "Smolder.History", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot open \(url.path)"])
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS minutes (
                ts INTEGER PRIMARY KEY,
                die_max REAL, die_avg REAL, ssd REAL, battery REAL,
                power REAL, cpu REAL, thermal INTEGER NOT NULL DEFAULT 0,
                expected_die REAL
            )
            """)
        // Average cores per program per 10-minute bucket (only >= 0.01), used to learn each program's own normal
        try exec("""
            CREATE TABLE IF NOT EXISTS process_usage (
                ts INTEGER NOT NULL,
                path TEXT NOT NULL,
                cores REAL NOT NULL,
                anomalous INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (ts, path)
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS process_usage_path ON process_usage(path, ts)")
    }

    func appendProcessUsage(bucket: Date, usage: [String: Double], anomalous: Set<String>) {
        queue.sync {
            let sql = "INSERT OR REPLACE INTO process_usage (ts, path, cores, anomalous) VALUES (?,?,?,?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            _ = try? exec("BEGIN")
            for (path, cores) in usage where cores >= 0.01 {
                sqlite3_reset(stmt)
                sqlite3_bind_int64(stmt, 1, Int64(bucket.timeIntervalSince1970))
                sqlite3_bind_text(stmt, 2, path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 3, cores)
                sqlite3_bind_int(stmt, 4, anomalous.contains(path) ? 1 : 0)
                sqlite3_step(stmt)
            }
            _ = try? exec("COMMIT")
        }
    }

    /// High quantile of each program's 10-minute averages in the window, excluding anomalous buckets:
    /// "the busiest this program usually gets".
    func usualPeaks(since: Date, quantile: Double = 0.99) -> [String: Double] {
        queue.sync {
            var series: [String: [Double]] = [:]
            let sql = "SELECT path, cores FROM process_usage WHERE ts >= ? AND anomalous = 0"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = String(cString: sqlite3_column_text(stmt, 0))
                series[path, default: []].append(sqlite3_column_double(stmt, 1))
            }
            return series.mapValues { Stats.quantile($0, quantile) ?? 0 }
        }
    }

    /// "Accept as new normal": let a program's flagged usage count toward its baseline again.
    func markNormal(path: String, since: Date) {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE process_usage SET anomalous = 0 WHERE path = ? AND ts >= ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(since.timeIntervalSince1970) - 600)
            sqlite3_step(stmt)
        }
    }

    /// Timestamp of the oldest minute row, used to tell whether we are still learning.
    func firstSampleDate() -> Date? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MIN(ts) FROM minutes", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
        }
    }

    deinit { sqlite3_close(db) }

    func append(_ s: MinuteSample) {
        queue.sync {
            let sql = "INSERT OR REPLACE INTO minutes (ts, die_max, die_avg, ssd, battery, power, cpu, thermal, expected_die) VALUES (?,?,?,?,?,?,?,?,?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(s.timestamp.timeIntervalSince1970))
            bind(stmt, 2, s.dieMax); bind(stmt, 3, s.dieAvg); bind(stmt, 4, s.ssd); bind(stmt, 5, s.battery)
            bind(stmt, 6, s.power); bind(stmt, 7, s.cpuCores)
            sqlite3_bind_int(stmt, 8, Int32(s.thermalState))
            bind(stmt, 9, s.expectedDie)
            sqlite3_step(stmt)
        }
    }

    func samples(since: Date) -> [MinuteSample] {
        queue.sync {
            var result: [MinuteSample] = []
            let sql = "SELECT ts, die_max, die_avg, ssd, battery, power, cpu, thermal, expected_die FROM minutes WHERE ts >= ? ORDER BY ts"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970))
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(MinuteSample(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0))),
                    dieMax: column(stmt, 1), dieAvg: column(stmt, 2), ssd: column(stmt, 3), battery: column(stmt, 4),
                    power: column(stmt, 5), cpuCores: column(stmt, 6),
                    thermalState: Int(sqlite3_column_int(stmt, 7)), expectedDie: column(stmt, 8)))
            }
            return result
        }
    }

    func prune(now: Date = Date()) {
        let cutoff = Int64(now.addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970)
        queue.sync {
            _ = try? exec("DELETE FROM minutes WHERE ts < \(cutoff)")
            _ = try? exec("DELETE FROM process_usage WHERE ts < \(cutoff)")
        }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "Smolder.History", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) } else { sqlite3_bind_null(stmt, index) }
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }
}
