import Foundation

/// A slowly drifting model can quietly absorb a real problem: each daily refit learns the last two weeks as normal.
/// So the first window that can serve is frozen as a reference, and every refit is checked against it.
///
/// What is compared has to be alike, or the check reports changes in how the Mac was used as changes in cooling:
/// - The room: on a Mac with a battery, fits of the die's rise over the room (estimated from the battery), so that a
///   room that turned colder while the warm days were the busy ones does not read as worse cooling.
/// - The lid: on a Mac with a lid, only minutes settled in one lid state (whichever most minutes were in when the
///   reference was frozen). A closed lid covers the keyboard deck; the same watts run the die hotter.
/// - The load: busy minutes, set against what the reference predicts for those very minutes. A window without
///   enough of them cannot become the reference. Judging them week by week, and learning what a usual week looks
///   like, is `CoolingBaseline`'s job; this check keeps the reference and judges the idle level.
enum DriftCheck {
    enum Outcome: Equatable {
        case waiting                // no reference yet, and this window cannot become one
        case frozen                 // this window became the reference
        case skipped                // nothing comparable to judge this time; the reference is kept
        case steady(current: ThermalFit)
        case drifted(current: ThermalFit)   // the idle level rose beyond its limit
    }

    /// - Parameters:
    ///   - fallback: the ordinary fit just made, used where no room-referenced fit can exist (a Mac without a battery).
    ///   - hasLid: whether this Mac reports a lid at all.
    ///   - idleAllowance: idle rise over the reference the user has accepted (°C).
    ///   - window: the samples of the baseline window ending at a date.
    /// - Returns: the reference to keep (possibly new or nil) and what the check found.
    static func run(reference: ThermalFit?, fallback: ThermalFit, hasLid: Bool, idleAllowance: Double = 0, excluded: [ClosedRange<Date>],
                    config: Config.Detection, now: Date, window: (Date) -> [MinuteSample]) -> (reference: ThermalFit?, outcome: Outcome) {
        let full = Int(config.baselineDays * 1440 * 0.5)
        let minimum = Int(config.learningHours * 60 * 0.5)
        var reference = reference

        // A reference from before 0.1.9 mixed both lid states and cannot be refitted on one: on a Mac with a lid,
        // start over. Without a lid there was nothing to mix.
        if let r = reference, r.lid == nil {
            if hasLid { reference = nil } else { reference?.lid = .any }
        }

        let samples = window(now)
        let lid: LidFilter
        if let l = reference?.lid {
            lid = l
        } else if hasLid {
            guard let majority = ThermalModel.majorityLid(samples) else { return (reference, .waiting) }
            lid = majority
        } else {
            lid = .any
        }

        var current = ThermalModel.roomFit(samples, excluded: excluded, minimumMinutes: minimum, now: now, lid: lid)
        if current == nil, lid == .any {
            current = fallback          // no battery, so no room estimate; and no lid
            current?.lid = .any
        }
        // Too few quiet or settled minutes this time: skip the check rather than drop the reference.
        guard let current else { return (reference, reference == nil ? .waiting : .skipped) }
        if let r = reference, r.roomReferenced, !current.roomReferenced { return (reference, .skipped) }

        if let r = reference, r.roomReferenced != current.roomReferenced || r.model != current.model {
            // A reference of another kind has a different R. Refit the window it was frozen on, so the comparison
            // keeps its anchor in time; where that is not possible, start over with this one.
            reference = current.roomReferenced
                ? ThermalModel.roomFit(window(r.fittedAt), excluded: excluded, minimumMinutes: minimum, now: r.fittedAt, lid: r.lid)
                : nil
        }

        guard let r = reference, r.minutes >= full, (r.loadedMinutes ?? .max) >= ThermalModel.driftMinLoadedMinutes else {
            let canServe = current.minutes >= full && (current.loadedMinutes ?? 0) >= ThermalModel.driftMinLoadedMinutes
            return canServe ? (current, .frozen) : (nil, .waiting)
        }

        return (r, ThermalModel.idleDrifted(current, from: r, allowance: idleAllowance) ? .drifted(current: current) : .steady(current: current))
    }
}
