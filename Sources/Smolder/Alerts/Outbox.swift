import Foundation

/// Persistent outbox. Delivery is tracked per destination, failures retry with exponential backoff, and
/// nothing is lost across restarts.
actor Outbox {
    struct Pending: Codable {
        var event: SmolderEvent
        var delivered: Set<String> = []
        var attempts: [String: Int] = [:]
        var nextTry: [String: Date] = [:]
        var lastError: [String: String] = [:]
    }

    private let url: URL
    private var items: [Pending] = []
    private let maxAge: TimeInterval = 7 * 86400

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.smolder.decode([Pending].self, from: data) {
            items = decoded
        }
    }

    func enqueue(_ event: SmolderEvent) {
        items.append(Pending(event: event))
        persist()
    }

    /// Latest failure reason per destination, for the UI.
    func failures() -> [String: String] {
        var result: [String: String] = [:]
        for item in items { for (k, v) in item.lastError where !item.delivered.contains(k) { result[k] = v } }
        return result
    }

    func pendingCount() -> Int { items.count }

    func flush(using notifiers: [Notifier], now: Date = Date()) async {
        for index in items.indices {
            for notifier in notifiers where !items[index].delivered.contains(notifier.id) {
                if let next = items[index].nextTry[notifier.id], next > now { continue }
                do {
                    try await notifier.deliver(items[index].event)
                    items[index].delivered.insert(notifier.id)
                    items[index].lastError[notifier.id] = nil
                } catch {
                    let attempt = (items[index].attempts[notifier.id] ?? 0) + 1
                    items[index].attempts[notifier.id] = attempt
                    items[index].nextTry[notifier.id] = now.addingTimeInterval(min(3600, 15 * pow(2, Double(attempt - 1))))
                    items[index].lastError[notifier.id] = error.localizedDescription
                }
            }
        }
        let ids = Set(notifiers.map(\.id))
        // Drop an item once every current destination has it, or after 7 days (the failure was shown in the UI)
        items.removeAll { ids.isSubset(of: $0.delivered) || now.timeIntervalSince($0.event.createdAt) > maxAge }
        persist()
    }

    private func persist() {
        guard let data = try? smolderJSONEncoder.encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static let smolder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
