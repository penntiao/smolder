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
///
/// A room-referenced fit predicts the die's rise over the room instead of the die itself, with the room estimated from
/// the battery (see `ThermalFilter`); its `base` is then the idle rise over the room. Only the drift check uses it: the
/// room is cooler or warmer for weeks at a time, and a fit on the die alone puts that into `R` whenever the warm days
/// happen to be the busy ones.
///
/// Drift fits also keep to minutes of one lid state (`lid`): a closed lid covers the keyboard deck, so the same watts
/// run the die hotter, and a window that mixes the two reads as a change in cooling whenever the mix changes.
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
    var roomReferenced: Bool    // predicts die minus the estimated room, not the die
    var lid: LidFilter?         // lid state of the minutes fitted; nil for fits from before 0.1.9, which mixed both
    var loadedMinutes: Int?     // minutes at least `ThermalModel.loadMargin` above the window's median power
    var loadedPowerP90: Double? // how hard those minutes worked: the top of the load a drift check may judge against

    init(base: Double, resistance: Double, tau: Double, slowResistance: Double = 0, cpuCoefficient: Double = 0,
         cpuPowerCoefficient: Double = 0,
         residualMAD: Double, residualP95: Double? = nil, powerP95: Double, minutes: Int, fittedAt: Date, model: Int = ThermalFit.currentModel,
         roomReferenced: Bool = false, lid: LidFilter? = nil, loadedMinutes: Int? = nil, loadedPowerP90: Double? = nil) {
        self.residualP95 = residualP95; self.roomReferenced = roomReferenced
        self.lid = lid; self.loadedMinutes = loadedMinutes; self.loadedPowerP90 = loadedPowerP90
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
        roomReferenced = try c.decodeIfPresent(Bool.self, forKey: .roomReferenced) ?? false
        lid = try c.decodeIfPresent(LidFilter.self, forKey: .lid)
        loadedMinutes = try c.decodeIfPresent(Int.self, forKey: .loadedMinutes)
        loadedPowerP90 = try c.decodeIfPresent(Double.self, forKey: .loadedPowerP90)
    }

    /// °C per watt once the chassis has fully soaked: what drift checks and the settings pane compare.
    var steadyResistance: Double { resistance + slowResistance }

    func expected(_ input: ThermalInput) -> Double {
        base + resistance * input.power + slowResistance * input.slowPower + cpuCoefficient * input.cpu
            + cpuPowerCoefficient * (input.cpuPower ?? 0)
    }
}

/// Which lid state a drift fit keeps to. `any`: the Mac has no lid.
enum LidFilter: String, Codable, Equatable {
    case closed, open, any
}

/// Load-driven warming of one window's busy minutes, set against what the reference predicts for the same inputs.
struct LoadDrift: Equatable {
    var minutes: Int        // busy minutes judged
    var measured: Double    // median °C the load added (die over the room, less the reference's idle rise)
    var predicted: Double   // median °C the reference predicts the load adds on the very same minutes
    var ratio: Double { measured / predicted }
}

/// Filtered load for one minute.
struct ThermalInput: Equatable {
    var power: Double
    var slowPower: Double
    var cpu: Double
    var cpuPower: Double? = nil
    var room: Double? = nil     // estimated room temperature (battery at the last quiet minute)
}

enum ThermalModel {
    static let tauCandidates: [Double] = [1, 2, 3, 5, 8, 13]

    /// A P-core power fit must cut the tail error (95th percentile of |residual|) of the fit without it, on the
    /// same minutes, by this factor — the term exists for the few minutes the other inputs get badly wrong,
    /// which a median-based spread never sees — and must not widen the typical error.
    static let cpuPowerTailGain = 0.9

    // MARK: Drift

    /// A busy minute: smoothed power at least this far above the window's median. At about 1 °C per watt that is a
    /// couple of degrees of load-driven warming, well clear of the noise.
    static let loadMargin: Double = 2
    /// Busy minutes needed, in the reference window and in the window judged against it. Without them a fit's watts
    /// term is set by the idle minutes alone, where the small, uneven warming of a nearly idle Mac decides the slope.
    static let driftMinLoadedMinutes = 180
    /// After the lid opens or closes, the chassis takes about an hour to settle (the slow filter's time constant):
    /// minutes inside that hour belong to neither state.
    static let lidSettleMinutes: Double = ThermalFit.slowTau

    /// The idle temperature up more than 8 °C (3 °C over the room for room-referenced fits, whose idle rise is a
    /// fraction of a degree to begin with). A near-idle window fixes the idle level well, so this one is always judged.
    /// `allowance`: an idle rise the user has accepted as the new normal.
    static func idleDrifted(_ fit: ThermalFit, from reference: ThermalFit, allowance: Double = 0) -> Bool {
        fit.base - reference.base - allowance > idleLimit(fit)
    }

    static func idleLimit(_ fit: ThermalFit) -> Double { fit.roomReferenced ? 3 : 8 }

    /// The window's busy minutes, measured with the reference as the yardstick: how much the load warmed the die,
    /// against what the reference predicts for the same inputs. Comparing fitted coefficients instead fails whenever
    /// the windows worked differently — the watts term of a mostly idle window is set by its idle minutes, and busy
    /// cores and watts trade heat between their two terms. Busy minutes beyond the load the reference has seen are left
    /// out. nil when the window has fewer than `driftMinLoadedMinutes` of them. Minutes before `since` only warm up the
    /// filters (pass a few hours of lead-in so the first minutes of a week are judged like the rest).
    static func loadDrift(_ samples: [MinuteSample], excluded: [ClosedRange<Date>], reference: ThermalFit,
                          since: Date? = nil) -> LoadDrift? {
        let points = collect(samples, excluded: excluded, tau: reference.tau, useCPUPower: false,
                             room: reference.roomReferenced, mask: lidMask(samples, reference.lid))
            .filter { since == nil || $0.time >= since! }
        guard let idle = Stats.quantile(points.map(\.input.power), 0.5) else { return nil }
        let ceiling = (reference.loadedPowerP90 ?? reference.powerP95) * 1.1
        var measured: [Double] = [], predicted: [Double] = []
        for p in points where p.input.power >= idle + loadMargin && p.input.power <= ceiling {
            measured.append(p.die - reference.base)
            predicted.append(reference.expected(p.input) - reference.base)
        }
        guard measured.count >= driftMinLoadedMinutes, let m = Stats.quantile(measured, 0.5),
              let e = Stats.quantile(predicted, 0.5), e > 0.5 else { return nil }
        return LoadDrift(minutes: measured.count, measured: m, predicted: e)
    }

    /// The lid state most minutes of the window were in; nil when no minute knows its lid.
    static func majorityLid(_ samples: [MinuteSample]) -> LidFilter? {
        let known = samples.compactMap(\.lidClosed)
        guard !known.isEmpty else { return nil }
        return known.filter { $0 }.count * 2 >= known.count ? .closed : .open
    }

    /// Which minutes a fit for `lid` may use: for a lid state, those that have been in it for `lidSettleMinutes`
    /// without a gap of more than five minutes (what the lid did during a gap is unknown). nil keeps every minute.
    static func lidMask(_ samples: [MinuteSample], _ lid: LidFilter?) -> [Bool]? {
        let want: Bool
        switch lid {
        case .closed?: want = true
        case .open?: want = false
        case .any?, nil: return nil
        }
        var since: Date?
        var previous: Date?
        return samples.map { s in
            if let previous, s.timestamp.timeIntervalSince(previous) > 300 { since = nil }
            previous = s.timestamp
            guard s.lidClosed == want else { since = nil; return false }
            if since == nil { since = s.timestamp }
            return s.timestamp.timeIntervalSince(since!) >= lidSettleMinutes * 60
        }
    }

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

    /// Model 2 on the die's rise over the estimated room, for the drift check. Minutes with no room estimate yet are
    /// left out; nil on a Mac without a battery. Always model 2, so that two of these fits compare like with like.
    /// With `lid` closed or open, only minutes settled in that state are used (see `lidMask`).
    static func roomFit(_ samples: [MinuteSample], excluded: [ClosedRange<Date>], minimumMinutes: Int, now: Date = Date(),
                        lid: LidFilter? = nil) -> ThermalFit? {
        var fit = fit(samples, excluded: excluded, minimumMinutes: minimumMinutes, now: now, useCPUPower: false, room: true,
                      mask: lidMask(samples, lid))
        fit?.lid = lid
        return fit
    }

    private static func fit(_ samples: [MinuteSample], excluded: [ClosedRange<Date>], minimumMinutes: Int, now: Date, useCPUPower: Bool,
                            room: Bool = false, mask: [Bool]? = nil) -> ThermalFit? {
        var best: ThermalFit?
        for tau in tauCandidates {
            let points = collect(samples, excluded: excluded, tau: tau, useCPUPower: useCPUPower, room: room, mask: mask)
            guard points.count >= minimumMinutes,
                  var candidate = robustFit(x: points.map(\.input), y: points.map(\.die), tau: tau, useCPUPower: useCPUPower, now: now)
            else { continue }
            candidate.roomReferenced = room
            if best == nil || candidate.residualMAD < best!.residualMAD { best = candidate }
        }
        return best
    }

    /// The filtered inputs and die temperature (over the room, with `room`) of every usable minute. The filter runs
    /// through every minute, `mask` only decides which are kept, so the inputs stay continuous across a lid change.
    private static func collect(_ samples: [MinuteSample], excluded: [ClosedRange<Date>], tau: Double, useCPUPower: Bool,
                                room: Bool, mask: [Bool]?) -> [(input: ThermalInput, die: Double, time: Date)] {
        var points: [(input: ThermalInput, die: Double, time: Date)] = []
        var filter = ThermalFilter()
        var warmup = 0
        for (i, s) in samples.enumerated() {
            guard let die = s.dieAvg, s.power != nil, !useCPUPower || s.cpuPower != nil else { filter.reset(); continue }
            let restarted = filter.isReset(before: s.timestamp)
            guard let input = filter.update(s, tau: tau) else { continue }
            // A gap (sleep, app not running) resets the filter; skip a few minutes while it settles.
            if restarted { warmup = Int(tau * 3) }
            if warmup > 0 { warmup -= 1; continue }
            if let mask, !mask[i] { continue }
            if excluded.contains(where: { $0.contains(s.timestamp) }) { continue }
            if room, input.room == nil { continue }
            points.append((input, die - (room ? input.room! : 0), s.timestamp))
        }
        return points
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
        let powers = x.map(\.power)
        let busyLine = (Stats.quantile(powers, 0.5) ?? 0) + loadMargin
        let busy = powers.filter { $0 >= busyLine }
        return ThermalFit(
            base: fit[0], resistance: fit[1], tau: tau, slowResistance: fit[2],
            cpuCoefficient: useCPUPower ? fit[4] : fit[3], cpuPowerCoefficient: useCPUPower ? fit[3] : 0,
            residualMAD: Stats.mad(finalResiduals) ?? mad,
            residualP95: Stats.quantile(finalResiduals.map(abs), 0.95),
            powerP95: Stats.quantile(x.map(\.power), 0.95) ?? 0,
            minutes: x.count, fittedAt: now, model: useCPUPower ? 3 : 2,
            loadedMinutes: busy.count, loadedPowerP90: Stats.quantile(busy, 0.9))
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
///
/// It also carries the room estimate. A fanless Mac's battery sits close to the room once the Mac has been near idle for
/// a while, and is warmed by the chassis otherwise; so the estimate is the battery reading of the last quiet minute
/// (both filtered powers at most `quietPower`), held through busy stretches, and dropped after `roomMaxAge` without one.
/// The slow filter (60 min) only falls under the line well after a busy stretch ends, by when the battery has cooled.
/// The room survives a gap: it does not change because the Mac slept.
struct ThermalFilter {
    static let quietPower: Double = 1.0
    static let roomMaxAge: TimeInterval = 86400

    private(set) var value: ThermalInput?
    private var last: Date?
    private var room: (temperature: Double, at: Date)?

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
            return withRoom(sample)
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
        return withRoom(sample)
    }

    private mutating func withRoom(_ sample: MinuteSample) -> ThermalInput? {
        guard var input = value else { return nil }
        if let battery = sample.battery, input.power <= Self.quietPower, input.slowPower <= Self.quietPower {
            room = (battery, sample.timestamp)
        }
        if let room, sample.timestamp.timeIntervalSince(room.at) <= Self.roomMaxAge { input.room = room.temperature }
        value = input
        return input
    }
}
