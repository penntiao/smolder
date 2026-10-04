import Foundation

/// A notification destination. Events and heartbeats are delivered separately; destinations that ignore
/// heartbeats simply return.
protocol Notifier {
    var id: String { get }
    func deliver(_ event: SmolderEvent) async throws
    func heartbeat(_ beat: Heartbeat) async throws
}

extension Notifier {
    func heartbeat(_ beat: Heartbeat) async throws {}
}

enum NotifierError: LocalizedError {
    case http(Int, String)
    case command(Int32, String)
    case misconfigured(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .command(let status, let stderr): return "exit \(status): \(stderr.prefix(200))"
        case .misconfigured(let why): return why
        }
    }
}

let smolderJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

// MARK: - Telegram

struct TelegramNotifier: Notifier {
    let id = "telegram"
    var botToken: String
    var chatID: String

    func deliver(_ event: SmolderEvent) async throws {
        guard !botToken.isEmpty, !chatID.isEmpty else { throw NotifierError.misconfigured("Telegram bot token or chat ID is empty") }
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["chat_id": chatID, "text": Self.render(event), "parse_mode": "HTML", "disable_web_page_preview": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await send(request)
    }

    static func render(_ event: SmolderEvent) -> String {
        let icon = event.kind == .recovered ? "✅" : ["info": "ℹ️", "warning": "🟠", "critical": "🔴"][event.severity.rawValue]!
        let lines = event.lines.map(escape).joined(separator: "\n")
        return "\(icon) <b>\(escape(event.title))</b>\n\(lines)\n<i>\(escape(event.host))</i>"
    }
}

// MARK: - Webhook

/// POSTs events and heartbeats as JSON: `{"type":"event"|"heartbeat", "payload":{…}}`.
struct WebhookNotifier: Notifier {
    let id = "webhook"
    var url: URL
    var bearerToken: String?
    var sendEvents: Bool
    var sendHeartbeats: Bool

    func deliver(_ event: SmolderEvent) async throws {
        guard sendEvents else { return }
        try await post(type: "event", payload: event)
    }

    func heartbeat(_ beat: Heartbeat) async throws {
        guard sendHeartbeats else { return }
        try await post(type: "heartbeat", payload: beat)
    }

    private func post<T: Encodable>(type: String, payload: T) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken, !bearerToken.isEmpty { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try smolderJSONEncoder.encode(Envelope(type: type, payload: payload))
        try await send(request)
    }
}

// MARK: - Command

/// Runs a command and writes the same JSON envelope to its stdin. Exit status 0 means delivered.
/// Handy for relaying to your own server over SSH, or for any script.
struct CommandNotifier: Notifier {
    let id = "command"
    var executable: String
    var arguments: [String]
    var sendEvents: Bool
    var sendHeartbeats: Bool
    var timeout: TimeInterval = 30

    func deliver(_ event: SmolderEvent) async throws {
        guard sendEvents else { return }
        try await run(type: "event", payload: event)
    }

    func heartbeat(_ beat: Heartbeat) async throws {
        guard sendHeartbeats else { return }
        try await run(type: "heartbeat", payload: beat)
    }

    private func run<T: Encodable>(type: String, payload: T) async throws {
        let input = try smolderJSONEncoder.encode(Envelope(type: type, payload: payload))
        let (status, stderr) = try await Self.execute(executable, arguments, input: input, timeout: timeout)
        guard status == 0 else { throw NotifierError.command(status, stderr) }
    }

    static func execute(_ executable: String, _ arguments: [String], input: Data, timeout: TimeInterval) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdin = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            process.terminationHandler = { p in
                let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: (p.terminationStatus, errText))
            }
            do { try process.run() } catch { continuation.resume(throwing: error); return }
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }
}

// MARK: - Health check ping

/// GETs a URL on every heartbeat (healthchecks.io, Uptime Kuma push monitors, …); the receiver alerts
/// when pings stop.
struct PingNotifier: Notifier {
    let id = "ping"
    var url: URL

    func deliver(_ event: SmolderEvent) async throws {}

    func heartbeat(_ beat: Heartbeat) async throws {
        try await send(URLRequest(url: url))
    }
}

// MARK: - helpers

private struct Envelope<T: Encodable>: Encodable {
    var type: String
    var payload: T
}

private func send(_ request: URLRequest) async throws {
    var request = request
    request.timeoutInterval = 20
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw NotifierError.http(code, String(data: data, encoding: .utf8) ?? "") }
}

func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

// MARK: - macOS notifications

import UserNotifications

struct LocalNotifier: Notifier {
    let id = "local"

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Best effort: without permission (nobody ever clicked "Allow" on a headless Mac) the banner is
    /// skipped rather than failed, so it never holds an event in the outbox.
    func deliver(_ event: SmolderEvent) async throws {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.lines.joined(separator: "\n")
        if event.severity >= .warning { content.sound = .default }
        let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}
