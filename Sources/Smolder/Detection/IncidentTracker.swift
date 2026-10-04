import Foundation

struct Incident: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var key: String
    var kind: SmolderEvent.Kind
    var severity: Severity
    var title: String
    var lines: [String]
    var programs: Set<String>
    var openedAt: Date
    var lastAbnormalAt: Date
    var closedAt: Date?
    var normalStreak = 0

    var span: ClosedRange<Date> { openedAt...(closedAt ?? .distantFuture) }
}

/// Turns per-minute findings into incidents: one notification when something starts, one if it gets
/// worse, one when it has been normal for `clearMinutes`. Nothing in between — no repeats.
final class IncidentTracker {
    private(set) var open: [String: Incident] = [:]
    private(set) var history: [Incident] = []      // closed incidents, kept for baseline exclusion and the UI

    init(open: [Incident], history: [Incident]) {
        self.open = Dictionary(uniqueKeysWithValues: open.map { ($0.key, $0) })
        self.history = history
    }

    /// Time ranges that must not be learned as normal.
    var excludedRanges: [ClosedRange<Date>] { (history + Array(open.values)).map(\.span) }

    /// Programs currently under an incident; their usage is stored as anomalous.
    var anomalousPrograms: Set<String> { open.values.reduce(into: Set<String>()) { $0.formUnion($1.programs) } }

    func update(findings: [Finding], now: Date, clearMinutes: Int, notifyRecoveries: Bool) -> [SmolderEvent] {
        var events: [SmolderEvent] = []
        var seen = Set<String>()
        for f in findings {
            seen.insert(f.key)
            if var incident = open[f.key] {
                let escalated = f.severity > incident.severity
                incident.severity = max(incident.severity, f.severity)
                incident.title = f.title
                incident.lines = f.lines
                incident.programs.formUnion(f.programs)
                incident.lastAbnormalAt = now
                incident.normalStreak = 0
                open[f.key] = incident
                if escalated {
                    events.append(SmolderEvent(kind: f.kind, severity: f.severity, title: f.title, lines: f.lines,
                                               incidentID: incident.id, startedAt: incident.openedAt))
                }
            } else {
                let incident = Incident(key: f.key, kind: f.kind, severity: f.severity, title: f.title, lines: f.lines,
                                        programs: f.programs, openedAt: now, lastAbnormalAt: now)
                open[f.key] = incident
                events.append(SmolderEvent(kind: f.kind, severity: f.severity, title: f.title, lines: f.lines,
                                           incidentID: incident.id, startedAt: now))
            }
        }
        for (key, var incident) in open where !seen.contains(key) {
            incident.normalStreak += 1
            if incident.normalStreak >= clearMinutes {
                incident.closedAt = now
                open[key] = nil
                history.append(incident)
                if notifyRecoveries {
                    let lasted = Format.duration(incident.lastAbnormalAt.timeIntervalSince(incident.openedAt) + 60)
                    events.append(SmolderEvent(kind: .recovered, severity: .info,
                                               title: L("Resolved: %@", incident.title),
                                               lines: [L("Lasted %@ (%@–%@)", lasted, Format.clock(incident.openedAt), Format.clock(incident.lastAbnormalAt))],
                                               incidentID: incident.id, startedAt: incident.openedAt))
                }
            } else {
                open[key] = incident
            }
        }
        history.removeAll { now.timeIntervalSince($0.closedAt ?? now) > 45 * 86400 }
        return events
    }

    /// "This is my new normal": close without a recovery message and let it be learned from now on.
    func accept(key: String, now: Date) {
        guard var incident = open.removeValue(forKey: key) else { return }
        incident.closedAt = incident.openedAt   // zero-length span: its data is no longer excluded
        history.append(incident)
    }
}
