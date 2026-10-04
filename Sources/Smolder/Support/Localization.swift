import Foundation

/// Localized text; the key is the English string. Follows the system language unless overridden in Settings.
func L(_ key: String) -> String {
    Localization.shared.bundle.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

final class Localization {
    static let shared = Localization()
    private(set) var bundle: Bundle = .main
    private(set) var code: String?

    /// Locale for dates and numbers that matches the chosen language.
    var locale: Locale { code.map(Locale.init(identifier:)) ?? .current }

    /// nil follows the system language.
    func apply(languageCode code: String?) {
        guard let code, let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) else {
            bundle = .main
            self.code = nil
            return
        }
        bundle = b
        self.code = code
    }
}

enum Format {
    static func celsius(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.0f°", value)
    }

    static func celsiusPrecise(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f °C", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "–" }
        return value < 10 ? String(format: "%.1f W", value) : String(format: "%.0f W", value)
    }

    static func cores(_ value: Double) -> String { String(format: "%.2f", value) }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return L("%d min", minutes) }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? L("%d h", hours) : L("%d h %d min", hours, rest)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
