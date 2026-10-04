import Foundation

/// A condition that is abnormal *right now*, after the detector's own persistence rule.
struct Finding {
    var key: String
    var kind: SmolderEvent.Kind
    var severity: Severity
    var title: String
    var lines: [String]
    /// Programs involved, so their usage is kept out of their own baseline while this lasts.
    var programs: Set<String> = []
}

/// Everything a detector may look at for the minute that just ended.
struct MinuteContext {
    var now: Date
    var minutes: [MinuteSample]                 // oldest first, recent window kept in memory
    var programs: [ProgramMinute]               // oldest first, same window
    var learning: Bool
    var config: Config.Detection

    struct ProgramMinute {
        var timestamp: Date
        var cores: [String: Double]             // path → cores averaged over that minute
        var names: [String: String]             // path → display name
        var pids: [String: Int32]               // path → busiest pid
    }

    /// Programs with the most CPU time over the last `minutes`, for "who is behind this" lines.
    func topPrograms(lastMinutes: Int, limit: Int = 3) -> [(name: String, cores: Double)] {
        let window = programs.suffix(lastMinutes)
        guard !window.isEmpty else { return [] }
        var total: [String: Double] = [:], names: [String: String] = [:]
        for m in window {
            for (path, c) in m.cores { total[path, default: 0] += c }
            names.merge(m.names) { a, _ in a }
        }
        return total.sorted { $0.value > $1.value }.prefix(limit).map { (names[$0.key] ?? $0.key, $0.value / Double(window.count)) }
    }

    func topProgramsLine(lastMinutes: Int) -> String? {
        let top = topPrograms(lastMinutes: lastMinutes).filter { $0.cores >= 0.05 }
        guard !top.isEmpty else { return nil }
        return L("Top CPU: %@", top.map { "\($0.name) \(Format.cores($0.cores))" }.joined(separator: ", "))
    }
}

// MARK: - Runaway process

/// Flags a program using far more CPU than *it* usually does, for a sustained period.
/// A daemon that normally idles and suddenly burns a core stands out immediately; a compiler or an AI
/// agent that is busy every day does not, because its own history already contains busy periods.
final class RunawayDetector {
    private var usualPeaks: [String: Double] = [:]
    private var peaksLoadedAt: Date?

    func refreshBaselines(store: HistoryStore, config: Config.Detection, now: Date) {
        if let loaded = peaksLoadedAt, now.timeIntervalSince(loaded) < 3600 { return }
        usualPeaks = store.usualPeaks(since: now.addingTimeInterval(-config.baselineDays * 86400))
        peaksLoadedAt = now
    }

    func usualPeak(_ path: String) -> Double { usualPeaks[path] ?? 0 }

    func setUsualPeaksForTesting(_ peaks: [String: Double]) { usualPeaks = peaks; peaksLoadedAt = .distantFuture }

    func evaluate(_ ctx: MinuteContext) -> [Finding] {
        let c = ctx.config
        guard c.runawayEnabled else { return [] }
        let sustain = ctx.learning ? c.runawayLearningSustainMinutes : c.runawaySustainMinutes
        let window = ctx.programs.suffix(sustain)
        guard window.count >= sustain else { return [] }

        var sums: [String: Double] = [:], presence: [String: Int] = [:]
        for m in window {
            for (path, cores) in m.cores { sums[path, default: 0] += cores; presence[path, default: 0] += 1 }
        }
        let latest = ctx.programs.last
        var findings: [Finding] = []
        for (path, sum) in sums {
            let average = sum / Double(sustain)
            guard average >= 0.25, presence[path, default: 0] >= Int(Double(sustain) * 0.8) else { continue }
            let name = latest?.names[path] ?? (path as NSString).lastPathComponent
            if c.ignoredProcesses.contains(where: { $0 == name || $0 == path }) { continue }
            let peak = usualPeak(path)
            let threshold = ctx.learning ? c.runawayLearningFloorCores : max(c.runawayFloorCores, c.runawayPeakMultiplier * peak)
            guard average > threshold else { continue }

            var lines = [L("Using %@ cores on average for %@", Format.cores(average), Format.duration(Double(sustain) * 60))]
            if ctx.learning {
                lines.append(L("Still learning what is normal on this Mac"))
            } else if peak < 0.05 {
                lines.append(L("Usually close to idle"))
            } else {
                lines.append(L("Usually peaks at %@ cores", Format.cores(peak)))
            }
            if let pid = latest?.pids[path] { lines.append(L("PID %d · %@", pid, path)) }
            findings.append(Finding(key: "process:" + path, kind: .runawayProcess, severity: .warning,
                                    title: L("%@ is running away", name), lines: lines, programs: [path]))
        }
        return findings
    }
}

// MARK: - Idle power floor

/// Catches long-running background burners regardless of which program: real work raises the power
/// *peaks*, but something that never stops raises the *quiet moments* too.
final class PowerFloorDetector {
    private(set) var baselineFloor: Double?
    private var loadedAt: Date?

    func setBaselineForTesting(_ floor: Double) { baselineFloor = floor; loadedAt = .distantFuture }

    func refreshBaseline(store: HistoryStore, excluded: [ClosedRange<Date>], config: Config.Detection, now: Date) {
        if let loadedAt, now.timeIntervalSince(loadedAt) < 3600 { return }
        loadedAt = now
        let samples = store.samples(since: now.addingTimeInterval(-config.baselineDays * 86400))
        var hourly: [Int: [Double]] = [:]
        for s in samples {
            guard let p = s.power, !excluded.contains(where: { $0.contains(s.timestamp) }) else { continue }
            hourly[Int(s.timestamp.timeIntervalSince1970 / 3600), default: []].append(p)
        }
        let floors = hourly.values.filter { $0.count >= 45 }.compactMap { Stats.quantile($0, 0.1) }
        baselineFloor = floors.count >= 24 ? Stats.median(floors) : nil
    }

    func evaluate(_ ctx: MinuteContext, suppress: Bool) -> [Finding] {
        let c = ctx.config
        guard c.powerFloorEnabled, !ctx.learning, !suppress, let baseline = baselineFloor else { return [] }
        let window = ctx.minutes.suffix(c.powerFloorSustainMinutes).compactMap(\.power)
        guard window.count >= Int(Double(c.powerFloorSustainMinutes) * 0.9) else { return [] }
        let recentHalf = Array(window.suffix(window.count / 2))
        guard let floor = Stats.quantile(window, 0.1), let recentFloor = Stats.quantile(recentHalf, 0.1),
              floor > baseline + c.powerFloorRiseWatts, recentFloor > baseline + c.powerFloorRiseWatts else { return [] }
        var lines = [L("Quietest power for %@ was %@, usually %@", Format.duration(Double(c.powerFloorSustainMinutes) * 60), Format.watts(floor), Format.watts(baseline))]
        if let top = ctx.topProgramsLine(lastMinutes: c.powerFloorSustainMinutes) { lines.append(top) }
        return [Finding(key: "power-floor", kind: .runawayProcess, severity: .warning,
                        title: L("Something keeps the Mac busy in the background"), lines: lines)]
    }
}

// MARK: - Cooling anomaly

/// Die temperature well above what the current power draw explains: blocked vents, a hot room, a Mac
/// buried under something. High temperature under heavy load is expected and never flagged here.
final class ThermalDetector {
    private(set) var fit: ThermalFit?
    private var filter = PowerFilter()
    private(set) var smoothedPower: Double?
    private var residuals: [(Date, Double)] = []
    private var lastFitAttempt: Date?

    init(fit: ThermalFit?) { self.fit = fit }

    /// Refit once a day (or hourly until the first fit succeeds).
    func refitIfDue(store: HistoryStore, excluded: [ClosedRange<Date>], config: Config.Detection, now: Date) -> ThermalFit? {
        let interval: TimeInterval = fit == nil ? 3600 : 86400
        if let last = lastFitAttempt, now.timeIntervalSince(last) < interval { return nil }
        lastFitAttempt = now
        let samples = store.samples(since: now.addingTimeInterval(-config.baselineDays * 86400))
        guard let newFit = ThermalModel.fit(samples, excluded: excluded, minimumMinutes: Int(config.learningHours * 60 * 0.5), now: now) else { return nil }
        fit = newFit
        return newFit
    }

    /// Feeds the minute and returns the expected die temperature, if the model has one.
    func observe(_ sample: MinuteSample) -> Double? {
        guard let fit else { _ = filter.update(power: sample.power, at: sample.timestamp, tau: 3); return nil }
        smoothedPower = filter.update(power: sample.power, at: sample.timestamp, tau: fit.tau)
        guard let p = smoothedPower else { return nil }
        let expected = fit.expected(smoothedPower: p)
        if let die = sample.dieAvg { residuals.append((sample.timestamp, die - expected)) }
        residuals.removeAll { sample.timestamp.timeIntervalSince($0.0) > 3 * 3600 }
        return expected
    }

    func band(_ config: Config.Detection) -> Double? {
        guard let fit else { return nil }
        return max(config.thermalMinMargin, config.thermalMADMultiplier * fit.residualMAD)
    }

    func evaluate(_ ctx: MinuteContext) -> [Finding] {
        let c = ctx.config
        guard c.thermalEnabled, !ctx.learning, let fit, let band = band(c), let power = smoothedPower,
              let latest = ctx.minutes.last, let die = latest.dieAvg else { return [] }
        // Outside the power range the model has really seen, its prediction is a guess: do not judge.
        guard power <= fit.powerP95 * 1.25 + 0.5 else { return [] }
        let recent = residuals.filter { ctx.now.timeIntervalSince($0.0) < Double(c.thermalSustainMinutes) * 60 + 30 }
        guard recent.count >= c.thermalSustainMinutes,
              recent.filter({ $0.1 > band }).count >= Int(Double(c.thermalSustainMinutes) * 0.8) else { return [] }
        let expected = fit.expected(smoothedPower: power)
        var lines = [
            L("Die %@, expected %@ ± %@ at %@", Format.celsius(die), Format.celsius(expected), String(format: "%.0f", band), Format.watts(power)),
            L("%@ hotter than the load explains for %@", String(format: "%.0f°", die - expected), Format.duration(Double(c.thermalSustainMinutes) * 60)),
        ]
        if let top = ctx.topProgramsLine(lastMinutes: c.thermalSustainMinutes) { lines.append(top) }
        lines.append(L("Check airflow around the Mac and the room temperature"))
        return [Finding(key: "thermal", kind: .thermalAnomaly, severity: .warning,
                        title: L("Running hotter than its workload explains"), lines: lines)]
    }
}

// MARK: - Hard limits

/// Fixed limits that never adapt — the backstop for anything the learned baselines might absorb.
enum HardLimitDetector {
    static func evaluate(_ ctx: MinuteContext) -> [Finding] {
        let c = ctx.config
        var findings: [Finding] = []
        let levels = ctx.minutes.suffix(c.pressureHeavyMinutes).map { PressureLevel(rawValue: $0.thermalState) ?? .nominal }
        if let worst = levels.max(), worst >= .trapping {
            findings.append(Finding(key: "pressure", kind: .thermalPressure, severity: .critical,
                                    title: L("macOS reports critical thermal pressure"),
                                    lines: [L("Thermal pressure: %@", worst.label)] + (ctx.topProgramsLine(lastMinutes: 10).map { [$0] } ?? [])))
        } else if levels.count >= c.pressureHeavyMinutes, levels.allSatisfy({ $0 >= .heavy }) {
            findings.append(Finding(key: "pressure", kind: .thermalPressure, severity: .warning,
                                    title: L("macOS is throttling because of heat"),
                                    lines: [L("Thermal pressure Heavy or worse for %@", Format.duration(Double(c.pressureHeavyMinutes) * 60))] + (ctx.topProgramsLine(lastMinutes: c.pressureHeavyMinutes).map { [$0] } ?? [])))
        }
        let battery = ctx.minutes.suffix(5).compactMap(\.battery)
        if battery.count >= 5, let avg = Stats.mean(battery), avg >= c.batteryCeiling {
            findings.append(Finding(key: "battery", kind: .hardLimit, severity: .warning,
                                    title: L("Battery is too warm"),
                                    lines: [L("Battery %@ (limit %@)", Format.celsiusPrecise(avg), Format.celsiusPrecise(c.batteryCeiling)),
                                            L("Sustained heat above 35 °C shortens battery life")]))
        }
        return findings
    }
}
