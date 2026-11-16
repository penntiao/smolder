import Foundation

/// The long-term cooling check, learned week by week.
///
/// The frozen reference fit (see `DriftCheck`) is only the yardstick. Each week Smolder measures how much the load
/// warmed the die against what that yardstick predicts for the very same minutes (`LoadDrift.ratio`) and keeps the
/// number for good — one per week, so the history is not bound by the 90 days of minute data. From those weeks it
/// learns two things: the usual level of the ratio, and how much a usual week strays from it.
///
/// - Better is learned on its own: two judged weeks in a row clearly below the usual level (a stand, a cooler spot)
///   become the new usual level.
/// - Worse is never learned on its own: a week clearly above it is reported, every week it lasts, until the user
///   accepts it (`/accept`, or the button in Settings).
/// - More usual weeks refine the level, but only downward from the level last set (the anchor): a fault that creeps
///   up a little each week cannot carry the level with it.
/// - "Clearly" is the learned spread: a prior worth `priorWeeks` weeks at `priorSpread`, pooled with how much each usual
///   week differs from the usual week before it (half the squared difference estimates the variance of one week). A
///   steady creep moves each week only a little, so it does not widen the line it is about to cross — the spread of
///   the deviations themselves would, and a slow fault would widen its own way through. The alert line starts at
///   +20 % and narrows as the weeks agree, down to +8 %.
struct CoolingBaseline: Codable, Equatable {
    struct Week: Codable, Equatable {
        enum Verdict: String, Codable { case usual, better, worse, accepted, unjudged }
        var start: Date
        var end: Date
        var ratio: Double?       // measured ÷ predicted load-driven warming; nil when unjudged
        var minutes: Int         // busy minutes judged
        var verdict: Verdict
        var deviation: Double?   // ratio ÷ the usual level at the time, minus 1
    }

    enum Change: Equatable {
        case worse(week: Week, level: Double, band: Double, weeks: Int)
        case improved(from: Double, to: Double)
    }

    static let weekLength: TimeInterval = 7 * 86400
    static let priorSpread = 0.08, priorWeeks = 4.0
    static let alertSigmas = 2.5, minAlertBand = 0.08
    static let betterSigmas = 2.0, minBetterBand = 0.05
    static let refineMinWeeks = 3

    var weeks: [Week] = []
    var anchor: Double = 1          // usual level last set: at the freeze, by an improvement, or by acceptance
    var anchorSince: Date           // when it was set; weeks before it do not refine the level
    var level: Double = 1           // the anchor, refined downward by the usual weeks since
    var idleAllowance: Double = 0   // idle rise over the reference the user has accepted (°C)
    var lastIdleRise: Double?       // latest window's idle rise over the reference, for acceptance
    var idleDrifted = false         // whether the latest window's idle level was flagged

    /// `level`: the reference measured against itself on the window it was frozen on, so that the weeks are compared
    /// with a number of the same kind (busy minutes only) rather than an assumed 1.
    init(since: Date, level: Double = 1) {
        anchorSince = since
        anchor = level
        self.level = level
    }

    /// How far one usual week strays, from successive differences between usual weeks, pooled with the prior.
    var spread: Double {
        let deviations = weeks.filter { $0.verdict == .usual }.compactMap(\.deviation)
        let halfSquares = zip(deviations, deviations.dropFirst()).map { ($1 - $0) * ($1 - $0) / 2 }
        let sum = Self.priorWeeks * Self.priorSpread * Self.priorSpread + halfSquares.reduce(0, +)
        return (sum / (Self.priorWeeks + Double(halfSquares.count))).squareRoot()
    }
    var alertBand: Double { max(Self.minAlertBand, Self.alertSigmas * spread) }
    var betterBand: Double { max(Self.minBetterBand, Self.betterSigmas * spread) }
    var judgedWeeks: Int { weeks.filter { $0.verdict != .unjudged }.count }
    var lastJudged: Week? { weeks.last { $0.verdict != .unjudged } }
    /// Something is flagged worse and can be accepted.
    var canAccept: Bool { lastJudged?.verdict == .worse || idleDrifted }

    /// Records one week. Returns what the user should hear about, if anything.
    mutating func record(start: Date, end: Date, load: LoadDrift?) -> Change? {
        guard let load else {
            weeks.append(Week(start: start, end: end, ratio: nil, minutes: 0, verdict: .unjudged, deviation: nil))
            return nil
        }
        let deviation = load.ratio / level - 1
        let previous = lastJudged
        if deviation > alertBand {
            let week = Week(start: start, end: end, ratio: load.ratio, minutes: load.minutes, verdict: .worse, deviation: deviation)
            let change = Change.worse(week: week, level: level, band: alertBand, weeks: weeks.filter { $0.verdict == .usual }.count)
            weeks.append(week)
            return change
        }
        if deviation < -betterBand {
            weeks.append(Week(start: start, end: end, ratio: load.ratio, minutes: load.minutes, verdict: .better, deviation: deviation))
            guard let previous, previous.verdict == .better, previous.start >= anchorSince, let earlier = previous.ratio else { return nil }
            let from = level
            anchor = (earlier + load.ratio) / 2
            level = anchor
            anchorSince = end
            return .improved(from: from, to: anchor)
        }
        weeks.append(Week(start: start, end: end, ratio: load.ratio, minutes: load.minutes, verdict: .usual, deviation: deviation))
        let usual = weeks.filter { $0.verdict == .usual && $0.start >= anchorSince }.compactMap(\.ratio)
        if usual.count >= Self.refineMinWeeks, let median = Stats.median(usual) { level = min(anchor, median) }
        return nil
    }

    /// Records every whole week that has ended since the last one. `samples(from, to)` returns the minutes in that span.
    mutating func catchUp(reference: ThermalFit, excluded: [ClosedRange<Date>], now: Date,
                          samples: (Date, Date) -> [MinuteSample]) -> [Change] {
        var start = weeks.last?.end ?? anchorSince
        var changes: [Change] = []
        while now >= start.addingTimeInterval(Self.weekLength) {
            let end = start.addingTimeInterval(Self.weekLength)
            // Three hours of lead-in settle the filters; the lid needs an hour of its own.
            let minutes = samples(start.addingTimeInterval(-3 * 3600), end)
            let load = ThermalModel.loadDrift(minutes, excluded: excluded, reference: reference, since: start)
            if let change = record(start: start, end: end, load: load) { changes.append(change) }
            start = end
        }
        return changes
    }

    /// The user says what was flagged is the new normal. Returns false when nothing was flagged.
    mutating func accept(now: Date) -> Bool {
        var accepted = false
        if let i = weeks.lastIndex(where: { $0.verdict != .unjudged }), weeks[i].verdict == .worse, let ratio = weeks[i].ratio {
            weeks[i].verdict = .accepted
            anchor = ratio
            level = ratio
            anchorSince = now
            accepted = true
        }
        if idleDrifted, let rise = lastIdleRise {
            idleAllowance = max(idleAllowance, rise)
            idleDrifted = false
            accepted = true
        }
        return accepted
    }
}
