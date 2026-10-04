import Foundation

/// All user-adjustable settings. Stored as JSON in Application Support; secrets live in `SecretStore`.
struct Config: Codable, Equatable {
    var detection = Detection()
    var local = Local()
    var telegram = Telegram()
    var webhook = Webhook()
    var command = Command()
    var ping = Ping()
    var general = General()

    struct Detection: Codable, Equatable {
        /// Learning period in hours. Only conservative fixed rules apply until it ends.
        var learningHours: Double = 72
        /// How many days of history define "normal".
        var baselineDays: Double = 14

        // Cooling anomaly: measured die temperature above what the current power draw explains
        var thermalEnabled = true
        var thermalMinMargin: Double = 3.0       // °C, lower bound of the band
        var thermalMADMultiplier: Double = 4.0   // or this many residual MADs, whichever is larger
        var thermalSustainMinutes = 20

        // Runaway process: far above its own usual peak, sustained
        var runawayEnabled = true
        var runawayFloorCores: Double = 0.5      // never alert below this, whatever the history
        var runawayPeakMultiplier: Double = 1.5  // multiple of the usual peak
        var runawaySustainMinutes = 30
        var runawayLearningFloorCores: Double = 0.9
        var runawayLearningSustainMinutes = 60
        var ignoredProcesses: [String] = []

        // Idle power floor raised for a long time
        var powerFloorEnabled = true
        var powerFloorRiseWatts: Double = 1.5
        var powerFloorSustainMinutes = 120

        // Hard limits: never learned, never adapted
        var pressureHeavyMinutes = 10
        var batteryCeiling: Double = 35.0

        /// Consecutive normal minutes required before an incident is resolved
        var clearMinutes = 15
    }

    struct Local: Codable, Equatable {
        var enabled = true
    }

    struct Telegram: Codable, Equatable {
        var enabled = false
        var chatID = ""
        /// Poll the bot and answer /status. The bot must not be polled by anything else.
        var answerCommands = true
    }

    struct Webhook: Codable, Equatable {
        var enabled = false
        var url = ""
        var sendHeartbeats = true
    }

    struct Command: Codable, Equatable {
        var enabled = false
        /// Absolute path of the executable, e.g. /usr/bin/ssh
        var executable = ""
        var arguments: [String] = []
        var sendHeartbeats = true
    }

    struct Ping: Codable, Equatable {
        var enabled = false
        var url = ""
    }

    struct General: Codable, Equatable {
        var heartbeatSeconds: Double = 60
        var menuBarShowsTemperature = true
        /// nil follows the system; "en" or "zh-Hans"
        var language: String?
        var notifyRecoveries = true
    }
}

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Smolder", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static let config = support.appendingPathComponent("config.json")
    static let history = support.appendingPathComponent("history.sqlite")
    static let state = support.appendingPathComponent("state.json")
    static let outbox = support.appendingPathComponent("outbox.json")
}

final class ConfigStore {
    static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: merge(defaults, stored))
        else { return Config() }
        // Keys added in newer versions are filled from defaults, so upgrades keep the user's settings.
        return (try? JSONDecoder().decode(Config.self, from: merged)) ?? Config()
    }

    private static func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let child = value as? [String: Any], let baseChild = base[key] as? [String: Any] {
                result[key] = merge(baseChild, child)
            } else {
                result[key] = value
            }
        }
        return result
    }

    static func save(_ config: Config) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: Paths.config, options: .atomic)
    }
}

/// Keys used in `SecretStore`.
enum Secrets {
    static let telegramToken = "telegram.botToken"
    static let webhookBearer = "webhook.bearerToken"
}
