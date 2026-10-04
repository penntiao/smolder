import Foundation

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum Stats {
    static func quantile(_ values: [Double], _ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    static func median(_ values: [Double]) -> Double? { quantile(values, 0.5) }

    /// Median absolute deviation (unscaled, i.e. not multiplied by 1.4826).
    static func mad(_ values: [Double]) -> Double? {
        guard let m = median(values) else { return nil }
        return median(values.map { abs($0 - m) })
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Ordinary least squares for y = a + b·x.
    static func linearFit(x: [Double], y: [Double]) -> (a: Double, b: Double)? {
        guard x.count == y.count, x.count >= 2, let mx = mean(x), let my = mean(y) else { return nil }
        var sxx = 0.0, sxy = 0.0
        for (xi, yi) in zip(x, y) { sxx += (xi - mx) * (xi - mx); sxy += (xi - mx) * (yi - my) }
        guard sxx > 1e-9 else { return (my, 0) }
        let b = sxy / sxx
        return (my - b * mx, b)
    }
}

import SQLite3
