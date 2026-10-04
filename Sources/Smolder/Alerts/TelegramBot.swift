import Foundation

/// Optional long-polling loop so the bot can answer `/status` from the configured chat.
/// Telegram allows only one `getUpdates` consumer per bot: use a bot dedicated to Smolder.
actor TelegramBot {
    private var task: Task<Void, Never>?
    private(set) var lastError: String?

    func start(token: String, chatID: String, status: @escaping @Sendable () async -> String) {
        stop()
        task = Task {
            var offset: Int?
            // Skip anything sent while the app was not running.
            if let latest = try? await Self.updates(token: token, offset: -1, timeout: 0).last { offset = latest.updateID + 1 }
            while !Task.isCancelled {
                do {
                    let updates = try await Self.updates(token: token, offset: offset, timeout: 50)
                    self.setError(nil)
                    for update in updates {
                        offset = update.updateID + 1
                        guard let message = update.message, String(message.chatID) == chatID else { continue }
                        let command = message.text.split(separator: " ").first.map { String($0).split(separator: "@").first.map(String.init) ?? "" } ?? ""
                        switch command {
                        case "/status", "/start":
                            try? await Self.send(token: token, chatID: chatID, html: await status())
                        case "/help":
                            try? await Self.send(token: token, chatID: chatID, html: L("<b>Smolder</b>\n/status — current temperatures, load and open incidents"))
                        default:
                            break
                        }
                    }
                } catch {
                    self.setError(error.localizedDescription)
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func setError(_ message: String?) { lastError = message }

    struct Update { var updateID: Int; var message: Message? }
    struct Message { var chatID: Int64; var text: String; var chatTitle: String }

    static func updates(token: String, offset: Int?, timeout: Int) async throws -> [Update] {
        var components = URLComponents(string: "https://api.telegram.org/bot\(token)/getUpdates")!
        components.queryItems = [URLQueryItem(name: "timeout", value: String(timeout)), URLQueryItem(name: "allowed_updates", value: "[\"message\"]")]
        if let offset { components.queryItems?.append(URLQueryItem(name: "offset", value: String(offset))) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = TimeInterval(timeout + 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [[String: Any]] else {
            throw NotifierError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return result.compactMap { item in
            guard let id = item["update_id"] as? Int else { return nil }
            var message: Message?
            if let m = item["message"] as? [String: Any], let chat = m["chat"] as? [String: Any], let chatID = (chat["id"] as? NSNumber)?.int64Value {
                let title = (chat["title"] as? String) ?? [chat["first_name"] as? String, chat["last_name"] as? String].compactMap { $0 }.joined(separator: " ")
                message = Message(chatID: chatID, text: (m["text"] as? String) ?? "", chatTitle: title)
            }
            return Update(updateID: id, message: message)
        }
    }

    static func send(token: String, chatID: String, html: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["chat_id": chatID, "text": html, "parse_mode": "HTML", "disable_web_page_preview": true])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw NotifierError.http(code, String(data: data, encoding: .utf8) ?? "") }
    }

    /// Setup helper: the user messages the bot, we read the chat ID from the latest update.
    static func detectChat(token: String) async throws -> (id: String, title: String)? {
        guard let message = try await updates(token: token, offset: nil, timeout: 0).reversed().compactMap(\.message).first else { return nil }
        return (String(message.chatID), message.chatTitle)
    }
}
