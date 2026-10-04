import Foundation

/// Secrets (Telegram token etc.) live in a file readable only by the current user (0600).
///
/// Not the Keychain: the app is ad-hoc signed, so its signature changes with every update and the
/// Keychain would prompt for access again — and nobody is there to click it on a lid-closed Mac.
enum SecretStore {
    private static let url = Paths.support.appendingPathComponent("secrets.json")

    static func get(_ key: String) -> String? { load()[key] }

    static func set(_ key: String, _ value: String?) {
        var all = load()
        if let value, !value.isEmpty { all[key] = value } else { all[key] = nil }
        guard let data = try? JSONEncoder().encode(all) else { return }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
