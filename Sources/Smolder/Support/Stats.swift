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

    /// Ordinary least squares for y = c₀ + c₁·x₁ + … via the normal equations (Gaussian elimination with
    /// partial pivoting). Nil when the inputs are collinear or there are too few points.
    static func multipleLinearFit(rows: [[Double]], y: [Double]) -> [Double]? {
        let k = (rows.first?.count ?? 0) + 1
        guard rows.count == y.count, rows.count > k else { return nil }
        var a = Array(repeating: Array(repeating: 0.0, count: k + 1), count: k)
        for (row, yi) in zip(rows, y) {
            let x = [1.0] + row
            for i in 0..<k {
                for j in 0..<k { a[i][j] += x[i] * x[j] }
                a[i][k] += x[i] * yi
            }
        }
        let scale = (0..<k).map { max(1, a[$0][$0]) }
        for col in 0..<k {
            guard let pivot = (col..<k).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }) else { return nil }
            // Relative to the diagonal's scale, so a constant input (zero variance) counts as collinear.
            guard abs(a[pivot][col]) > 1e-9 * scale[col] else { return nil }
            a.swapAt(col, pivot)
            for r in 0..<k where r != col {
                let f = a[r][col] / a[col][col]
                for c in col...k { a[r][c] -= f * a[col][c] }
            }
        }
        return (0..<k).map { a[$0][k] / a[$0][$0] }
    }
}

import SQLite3
