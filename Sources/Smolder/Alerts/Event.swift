import Foundation

enum Severity: String, Codable, Comparable {
    case info, warning, critical

    private var rank: Int { [.info: 0, .warning: 1, .critical: 2][self]! }
    static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
}

/// Something worth notifying about. `id` is globally unique so receivers can de-duplicate.
struct SmolderEvent: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case runawayProcess     // a program far above its own usual peak, sustained
        case thermalAnomaly     // die hotter than the current power draw explains (cooling got worse)
        case thermalPressure    // macOS is throttling because of heat
        case hardLimit          // an absolute safety limit was crossed
        case recovered          // any of the above resolved
        case test               // test notification from Settings
    }

    var id: String = UUID().uuidString
    var kind: Kind
    var severity: Severity
    var title: String
    var lines: [String]
    var incidentID: String      // shared by the open, escalation and recovery events of one incident
    var startedAt: Date
    var createdAt: Date = Date()
    var host: String = Host.current().localizedName ?? "Mac"
}

/// Periodic heartbeat carrying the current status, so a remote receiver can detect silence and show state.
struct Heartbeat: Codable {
    var host: String
    var sentAt: Date
    var bootTime: Date
    var appVersion: String
    var status: StatusSnapshot
}

struct StatusSnapshot: Codable, Equatable {
    var dieMax: Double?
    var expectedDie: Double?
    var ssd: Double?
    var battery: Double?
    var power: Double?
    var cpuCores: Double?
    var thermalState: Int
    var learning: Bool
    var openIncidents: [String]
    var topProcesses: [ProcessUsage]
}
