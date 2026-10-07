import Foundation

/// Learned relation between load and die temperature:
///
///     expected = base + resistance × P̃ + slowResistance × P̃slow + cpuCoefficient × C̃
///
/// `P̃` is system power through a first-order low-pass filter with time constant `tau` (the chip's own
/// thermal inertia), `P̃slow` the same power through a slow filter (`slowTau`, heat soaking into the
/// chassis over an hour of sustained work — a fanless Mac keeps warming long after the chip settles), and
/// `C̃` CPU usage in cores through the fast filter. System power includes the display and the rest of the
/// board; at the same total watts, a CPU-heavy load puts more of them into the die, which the CPU term
/// accounts for. Physics does not change when the workload does, so this baseline survives "this month the
/// Mac does different work" — unlike a baseline on temperature itself.
struct ThermalFit: Codable, Equatable {
    static let currentModel = 2
    static let slowTau: Double = 60

    var base: Double            // °C at zero load (roughly ambient + idle offset)
    var resistance: Double      // °C per watt, fast term
    var tau: Double             // minutes
    var slowResistance: Double  // °C per watt, chassis heat-soak term
    var cpuCoefficient: Double  // °C per busy core
    var residualMAD: Double     // unscaled MAD of residuals on the fit data
    var powerP95: Double        // highest power the fit has really seen (95th percentile of smoothed power)
    var minutes: Int            // minutes of data used
    var fittedAt: Date
    var model: Int              // 1 = power-only fits saved by 0.1.x

    init(base: Double, resistance: Double, tau: Double, slowResistance: Double = 0, cpuCoefficient: Double = 0,
         residualMAD: Double, powerP95: Double, minutes: Int, fittedAt: Date, model: Int = ThermalFit.currentModel) {
        self.base = base; self.resistance = resistance; self.tau = tau
        self.slowResistance = slowResistance; self.cpuCoefficient = cpuCoefficient
        self.residualMAD = residualMAD; self.powerP95 = powerP95; self.minutes = minutes
        self.fittedAt = fittedAt; self.model = model
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        base = try c.decode(Double.self, forKey: .base)
        resistance = try c.decode(Double.self, forKey: .resistance)
        tau = try c.decode(Double.self, forKey: .tau)
        slowResistance = try c.decodeIfPresent(Double.self, forKey: .slowResistance) ?? 0
        cpuCoefficient = try c.decodeIfPresent(Double.self, forKey: .cpuCoefficient) ?? 0
        residualMAD = try c.decode(Double.self, forKey: .residualMAD)
        powerP95 = try c.decode(Double.self, forKey: .powerP95)
        minutes = try c.decode(Int.self, forKey: .minutes)
        fittedAt = try c.decode(Date.self, forKey: .fittedAt)
        model = try c.decodeIfPresent(Int.self, forKey: .model) ?? 1
    }

    /// °C per watt once the chassis has fully soaked: what drift checks and the settings pane compare.
    var steadyResistance: Double { resistance + slowResistance }

    func expected(_ input: ThermalInput) -> Double {
        base + resistance * input.power + slowResistance * input.slowPower + cpuCoefficient * input.cpu
    }
}

/// Filtered load for one minute.
struct ThermalInput: Equatable {
    var power: Double
    var slowPower: Double
    var cpu: Double
}

enum ThermalModel {
    static let tauCandidates: [Double] = [1, 2, 3, 5, 8, 13]

    /// Robust fit over the given minutes. Minutes inside `excluded` (open or past incidents) are ignored,
    /// so an anomaly is never learned as normal.
    static func fit(_ samples: [MinuteSample], excluded: [ClosedRange<Date>], minimumMinutes: Int, now: Date = Date()) -> ThermalFit? {
        var best: ThermalFit?
        for tau in tauCandidates {
            var xs: [ThermalInput] = [], ys: [Double] = []
            var filter = ThermalFilter()
            var warmup = 0
            for s in samples {
                guard let die = s.dieAvg, s.power != nil else { filter.reset(); continue }
                let restarted = filter.isReset(before: s.timestamp)
                guard let input = filter.update(s, tau: tau) else { continue }
                // A gap (sleep, app not running) resets the filter; skip a few minutes while it settles.
                if restarted { warmup = Int(tau * 3) }
                if warmup > 0 { warmup -= 1; continue }
                if excluded.contains(where: { $0.contains(s.timestamp) }) { continue }
                xs.append(input)
                ys.append(die)
            }
            guard xs.count >= minimumMinutes, let candidate = robustFit(x: xs, y: ys, tau: tau, now: now) else { continue }
            if best == nil || candidate.residualMAD < best!.residualMAD { best = candidate }
        }
        return best
    }

    /// Least squares, drop points beyond 3 robust sigmas, refit once.
    private static func robustFit(x: [ThermalInput], y: [Double], tau: Double, now: Date) -> ThermalFit? {
        let rows = x.map { [$0.power, $0.slowPower, $0.cpu] }
        guard let first = nonNegativeFit(rows: rows, y: y) else { return nil }
        let residuals = zip(rows, y).map { $1 - predict(first, $0) }
        guard let mad = Stats.mad(residuals) else { return nil }
        let cutoff = max(3 * 1.4826 * mad, 0.5)
        var kRows: [[Double]] = [], ky: [Double] = []
        for (i, r) in residuals.enumerated() where abs(r) <= cutoff { kRows.append(rows[i]); ky.append(y[i]) }
        guard let fit = nonNegativeFit(rows: kRows, y: ky) else { return nil }
        let finalResiduals = zip(rows, y).map { $1 - predict(fit, $0) }
        return ThermalFit(
            base: fit[0], resistance: fit[1], tau: tau, slowResistance: fit[2], cpuCoefficient: fit[3],
            residualMAD: Stats.mad(finalResiduals) ?? mad,
            powerP95: Stats.quantile(x.map(\.power), 0.95) ?? 0,
            minutes: x.count, fittedAt: now)
    }

    private static func predict(_ coefficients: [Double], _ row: [Double]) -> Double {
        coefficients[0] + zip(coefficients.dropFirst(), row).map(*).reduce(0, +)
    }

    /// Intercept plus non-negative coefficients: temperature cannot fall when load rises, so a negative
    /// coefficient means that input had no usable range in the data. Drop it and refit without it.
    /// Returns [intercept, power, slowPower, cpu].
    private static func nonNegativeFit(rows: [[Double]], y: [Double]) -> [Double]? {
        guard !rows.isEmpty, let meanY = Stats.mean(y) else { return nil }
        var active = Array(0..<(rows.first?.count ?? 0))
        while true {
            guard !active.isEmpty else { return [meanY] + Array(repeating: 0, count: rows[0].count) }
            guard let solved = Stats.multipleLinearFit(rows: rows.map { r in active.map { r[$0] } }, y: y) else {
                active.removeLast(); continue          // collinear: drop the least important input
            }
            if let worst = solved.dropFirst().enumerated().min(by: { $0.element < $1.element }), worst.element < 0 {
                active.remove(at: worst.offset); continue
            }
            var full = [solved[0]] + Array(repeating: 0.0, count: rows[0].count)
            for (i, feature) in active.enumerated() { full[feature + 1] = solved[i + 1] }
            return full
        }
    }
}

/// Keeps the filtered load current, minute by minute, for both fitting and the live prediction.
struct ThermalFilter {
    private(set) var value: ThermalInput?
    private var last: Date?

    mutating func reset() { value = nil }

    func isReset(before time: Date) -> Bool {
        guard value != nil, let last else { return true }
        return time.timeIntervalSince(last) > 300
    }

    mutating func update(_ sample: MinuteSample, tau: Double) -> ThermalInput? {
        guard let power = sample.power else { return value }
        if isReset(before: sample.timestamp) { value = nil }
        last = sample.timestamp
        guard let current = value else {
            value = ThermalInput(power: power, slowPower: power, cpu: sample.cpuCores ?? 0)
            return value
        }
        let fast = 1 - exp(-1 / tau), slow = 1 - exp(-1 / ThermalFit.slowTau)
        let cpu = sample.cpuCores ?? current.cpu
        value = ThermalInput(power: current.power + fast * (power - current.power),
                             slowPower: current.slowPower + slow * (power - current.slowPower),
                             cpu: current.cpu + fast * (cpu - current.cpu))
        return value
    }
}
