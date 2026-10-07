import Foundation

/// Learned relation between load and die temperature:
///
///     expected = base + resistance × P̃ + slowResistance × P̃slow + cpuCoefficient × C̃ + cpuPowerCoefficient × Q̃
///
/// `P̃` is system power through a first-order low-pass filter with time constant `tau` (the chip's own
/// thermal inertia), `P̃slow` the same power through a slow filter (`slowTau`, heat soaking into the
/// chassis over an hour of sustained work — a fanless Mac keeps warming long after the chip settles), and
/// `C̃` CPU usage in cores through the fast filter. System power includes the display and the rest of the
/// board; at the same total watts, a CPU-heavy load puts more of them into the die, which the CPU term
/// accounts for. `Q̃` is the P-core cluster's own power (SMC), fast-filtered: busy cores say nothing about the
/// clock they run at, and a compile that pins the P-cores at their top frequency heats the die far more than
/// the same core count at a low clock. Where a Mac has no such sensor, or too little history with it, the fit
/// leaves that term out (model 2). Physics does not change when the workload does, so this baseline survives "this month the
/// Mac does different work" — unlike a baseline on temperature itself.
struct ThermalFit: Codable, Equatable {
    static let currentModel = 3
    static let slowTau: Double = 60

    var base: Double            // °C at zero load (roughly ambient + idle offset)
    var resistance: Double      // °C per watt, fast term
    var tau: Double             // minutes
    var slowResistance: Double  // °C per watt, chassis heat-soak term
    var cpuCoefficient: Double  // °C per busy core
    var cpuPowerCoefficient: Double  // °C per watt of P-core cluster power
    var residualMAD: Double     // unscaled MAD of residuals on the fit data
    var residualP95: Double?    // 95th percentile of |residual| on the fit data: the minutes a model gets wrong
    var powerP95: Double        // highest power the fit has really seen (95th percentile of smoothed power)
    var minutes: Int            // minutes of data used
    var fittedAt: Date
    var model: Int              // 1 = power-only (0.1.0–0.1.2), 2 = no P-core power term, 3 = with it

    init(base: Double, resistance: Double, tau: Double, slowResistance: Double = 0, cpuCoefficient: Double = 0,
         cpuPowerCoefficient: Double = 0,
         residualMAD: Double, residualP95: Double? = nil, powerP95: Double, minutes: Int, fittedAt: Date, model: Int = ThermalFit.currentModel) {
        self.residualP95 = residualP95
        self.base = base; self.resistance = resistance; self.tau = tau
        self.slowResistance = slowResistance; self.cpuCoefficient = cpuCoefficient; self.cpuPowerCoefficient = cpuPowerCoefficient
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
        cpuPowerCoefficient = try c.decodeIfPresent(Double.self, forKey: .cpuPowerCoefficient) ?? 0
        residualMAD = try c.decode(Double.self, forKey: .residualMAD)
        residualP95 = try c.decodeIfPresent(Double.self, forKey: .residualP95)
        powerP95 = try c.decode(Double.self, forKey: .powerP95)
        minutes = try c.decode(Int.self, forKey: .minutes)
        fittedAt = try c.decode(Date.self, forKey: .fittedAt)
        model = try c.decodeIfPresent(Int.self, forKey: .model) ?? 1
    }

    /// °C per watt once the chassis has fully soaked: what drift checks and the settings pane compare.
    var steadyResistance: Double { resistance + slowResistance }

    func expected(_ input: ThermalInput) -> Double {
        base + resistance * input.power + slowResistance * input.slowPower + cpuCoefficient * input.cpu
            + cpuPowerCoefficient * (input.cpuPower ?? 0)
    }
}

/// Filtered load for one minute.
struct ThermalInput: Equatable {
    var power: Double
    var slowPower: Double
    var cpu: Double
    var cpuPower: Double? = nil
}

enum ThermalModel {
    static let tauCandidates: [Double] = [1, 2, 3, 5, 8, 13]

    /// A P-core power fit must cut the tail error (95th percentile of |residual|) of the fit without it, on the
    /// same minutes, by this factor — the term exists for the few minutes the other inputs get badly wrong,
    /// which a median-based spread never sees — and must not widen the typical error.
    static let cpuPowerTailGain = 0.9

    /// Robust fit over the given minutes. Minutes inside `excluded` (open or past incidents) are ignored,
    /// so an anomaly is never learned as normal. With enough minutes that carry P-core power, model 3 is fitted
    /// on those and kept only if it explains them clearly better than model 2 does on the very same minutes;
    /// otherwise model 2 is fitted on all minutes.
    /// The P-core power fit may start from a third of the minutes the first fit needs: whether it is used at
    /// all is decided by the comparison, so there is no point waiting longer for it.
    static func fit(_ samples: [MinuteSample], excluded: [ClosedRange<Date>], minimumMinutes: Int, now: Date = Date()) -> ThermalFit? {
        let measured = samples.filter { $0.cpuPower != nil }
        let measuredMinimum = max(minimumMinutes / 3, 1)
        if measured.filter({ $0.dieAvg != nil && $0.power != nil }).count >= measuredMinimum,
           let with = fit(measured, excluded: excluded, minimumMinutes: measuredMinimum, now: now, useCPUPower: true),
           let without = fit(measured, excluded: excluded, minimumMinutes: measuredMinimum, now: now, useCPUPower: false),
           with.cpuPowerCoefficient > 0, let withTail = with.residualP95, let withoutTail = without.residualP95,
           withTail < withoutTail * cpuPowerTailGain, with.residualMAD <= without.residualMAD * 1.03 {
            return with
        }
        return fit(samples, excluded: excluded, minimumMinutes: minimumMinutes, now: now, useCPUPower: false)
    }

    private static func fit(_ samples: [MinuteSample], excluded: [ClosedRange<Date>], minimumMinutes: Int, now: Date, useCPUPower: Bool) -> ThermalFit? {
        var best: ThermalFit?
        for tau in tauCandidates {
            var xs: [ThermalInput] = [], ys: [Double] = []
            var filter = ThermalFilter()
            var warmup = 0
            for s in samples {
                guard let die = s.dieAvg, s.power != nil, !useCPUPower || s.cpuPower != nil else { filter.reset(); continue }
                let restarted = filter.isReset(before: s.timestamp)
                guard let input = filter.update(s, tau: tau) else { continue }
                // A gap (sleep, app not running) resets the filter; skip a few minutes while it settles.
                if restarted { warmup = Int(tau * 3) }
                if warmup > 0 { warmup -= 1; continue }
                if excluded.contains(where: { $0.contains(s.timestamp) }) { continue }
                xs.append(input)
                ys.append(die)
            }
            guard xs.count >= minimumMinutes, let candidate = robustFit(x: xs, y: ys, tau: tau, useCPUPower: useCPUPower, now: now) else { continue }
            if best == nil || candidate.residualMAD < best!.residualMAD { best = candidate }
        }
        return best
    }

    /// Least squares, drop points beyond 3 robust sigmas, refit once.
    private static func robustFit(x: [ThermalInput], y: [Double], tau: Double, useCPUPower: Bool, now: Date) -> ThermalFit? {
        // Inputs that are collinear get dropped from the end first; with P-core power measured, busy cores are
        // the redundant one, so they go last.
        let rows = x.map { useCPUPower ? [$0.power, $0.slowPower, $0.cpuPower ?? 0, $0.cpu] : [$0.power, $0.slowPower, $0.cpu] }
        guard let first = nonNegativeFit(rows: rows, y: y) else { return nil }
        let residuals = zip(rows, y).map { $1 - predict(first, $0) }
        guard let mad = Stats.mad(residuals) else { return nil }
        let cutoff = max(3 * 1.4826 * mad, 0.5)
        var kRows: [[Double]] = [], ky: [Double] = []
        for (i, r) in residuals.enumerated() where abs(r) <= cutoff { kRows.append(rows[i]); ky.append(y[i]) }
        guard let fit = nonNegativeFit(rows: kRows, y: ky) else { return nil }
        let finalResiduals = zip(rows, y).map { $1 - predict(fit, $0) }
        return ThermalFit(
            base: fit[0], resistance: fit[1], tau: tau, slowResistance: fit[2],
            cpuCoefficient: useCPUPower ? fit[4] : fit[3], cpuPowerCoefficient: useCPUPower ? fit[3] : 0,
            residualMAD: Stats.mad(finalResiduals) ?? mad,
            residualP95: Stats.quantile(finalResiduals.map(abs), 0.95),
            powerP95: Stats.quantile(x.map(\.power), 0.95) ?? 0,
            minutes: x.count, fittedAt: now, model: useCPUPower ? 3 : 2)
    }

    private static func predict(_ coefficients: [Double], _ row: [Double]) -> Double {
        coefficients[0] + zip(coefficients.dropFirst(), row).map(*).reduce(0, +)
    }

    /// Intercept plus non-negative coefficients: temperature cannot fall when load rises, so a negative
    /// coefficient means that input had no usable range in the data. Drop it and refit without it.
    /// Returns the intercept followed by one coefficient per input, in the order of `rows`.
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
            value = ThermalInput(power: power, slowPower: power, cpu: sample.cpuCores ?? 0, cpuPower: sample.cpuPower)
            return value
        }
        let fast = 1 - exp(-1 / tau), slow = 1 - exp(-1 / ThermalFit.slowTau)
        let cpu = sample.cpuCores ?? current.cpu
        let cpuPower: Double? = switch (current.cpuPower, sample.cpuPower) {
        case let (old?, new?): old + fast * (new - old)
        case let (nil, new?): new
        case let (old, nil): old
        }
        value = ThermalInput(power: current.power + fast * (power - current.power),
                             slowPower: current.slowPower + slow * (power - current.slowPower),
                             cpu: current.cpu + fast * (cpu - current.cpu), cpuPower: cpuPower)
        return value
    }
}
