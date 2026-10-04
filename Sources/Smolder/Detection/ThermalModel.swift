import Foundation

/// Learned relation between power draw and die temperature:
///
///     expected = base + resistance × smoothedPower
///
/// where `smoothedPower` is the power passed through a first-order low-pass filter with time constant
/// `tau`, mimicking the chip's thermal inertia. Physics does not change when the workload does, so this
/// baseline survives "this month the Mac does different work" — unlike a baseline on temperature itself.
struct ThermalFit: Codable, Equatable {
    var base: Double            // °C at zero power (roughly ambient + idle offset)
    var resistance: Double      // °C per watt
    var tau: Double             // minutes
    var residualMAD: Double     // unscaled MAD of residuals on the fit data
    var powerP95: Double        // highest power the fit has really seen (95th percentile of smoothed power)
    var minutes: Int            // minutes of data used
    var fittedAt: Date

    func expected(smoothedPower: Double) -> Double { base + resistance * smoothedPower }
}

enum ThermalModel {
    static let tauCandidates: [Double] = [1, 2, 3, 5, 8, 13]

    /// Robust fit over the given minutes. Minutes inside `excluded` (open or past incidents) are ignored,
    /// so an anomaly is never learned as normal.
    static func fit(_ samples: [MinuteSample], excluded: [ClosedRange<Date>], minimumMinutes: Int, now: Date = Date()) -> ThermalFit? {
        var best: ThermalFit?
        for tau in tauCandidates {
            var xs: [Double] = [], ys: [Double] = []
            var smoothed: Double?
            var previous: Date?
            var warmup = 0
            for s in samples {
                guard let power = s.power, let die = s.dieAvg else { smoothed = nil; continue }
                // A gap (sleep, app not running) resets the filter; skip a few minutes while it settles.
                if let previous, s.timestamp.timeIntervalSince(previous) > 300 { smoothed = nil }
                previous = s.timestamp
                if smoothed == nil { smoothed = power; warmup = Int(tau * 3) }
                smoothed! += (1 - exp(-1 / tau)) * (power - smoothed!)
                if warmup > 0 { warmup -= 1; continue }
                if excluded.contains(where: { $0.contains(s.timestamp) }) { continue }
                xs.append(smoothed!)
                ys.append(die)
            }
            guard xs.count >= minimumMinutes, let candidate = robustFit(x: xs, y: ys, tau: tau, now: now) else { continue }
            if best == nil || candidate.residualMAD < best!.residualMAD { best = candidate }
        }
        return best
    }

    /// Least squares, drop points beyond 3 robust sigmas, refit once.
    private static func robustFit(x: [Double], y: [Double], tau: Double, now: Date) -> ThermalFit? {
        guard let first = Stats.linearFit(x: x, y: y) else { return nil }
        let residuals = zip(x, y).map { $1 - (first.a + first.b * $0) }
        guard let mad = Stats.mad(residuals) else { return nil }
        let cutoff = max(3 * 1.4826 * mad, 0.5)
        var kx: [Double] = [], ky: [Double] = []
        for (i, r) in residuals.enumerated() where abs(r) <= cutoff { kx.append(x[i]); ky.append(y[i]) }
        guard let fit = Stats.linearFit(x: kx, y: ky) else { return nil }
        // Temperature cannot fall when power rises; a negative slope means the data had no usable range.
        let resistance = max(0, fit.b)
        let base = resistance == fit.b ? fit.a : (Stats.mean(ky) ?? fit.a)
        let finalResiduals = zip(x, y).map { $1 - (base + resistance * $0) }
        return ThermalFit(
            base: base, resistance: resistance, tau: tau,
            residualMAD: Stats.mad(finalResiduals) ?? mad,
            powerP95: Stats.quantile(x, 0.95) ?? 0,
            minutes: x.count, fittedAt: now)
    }
}

/// Keeps the low-pass filtered power current, minute by minute, for the live prediction.
struct PowerFilter {
    private(set) var value: Double?
    private var last: Date?

    mutating func update(power: Double?, at time: Date, tau: Double) -> Double? {
        guard let power else { return value }
        if let last, time.timeIntervalSince(last) > 300 { value = nil }
        last = time
        guard let current = value else { value = power; return power }
        value = current + (1 - exp(-1 / tau)) * (power - current)
        return value
    }
}
