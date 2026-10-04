import Foundation
import notify

/// Fine-grained thermal pressure. `ProcessInfo.thermalState` folds Moderate and Heavy into `fair`,
/// but Heavy is where throttling starts, so read the notify key directly.
enum PressureLevel: Int, Codable, Comparable {
    case nominal = 0, moderate = 1, heavy = 2, trapping = 3, sleeping = 4

    static func < (a: PressureLevel, b: PressureLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .nominal: return L("Nominal")
        case .moderate: return L("Moderate")
        case .heavy: return L("Heavy (throttling)")
        case .trapping: return L("Trapping")
        case .sleeping: return L("Sleeping")
        }
    }
}

final class ThermalPressure {
    private var token: Int32 = 0
    private let registered: Bool

    init() {
        registered = notify_register_check("com.apple.system.thermalpressurelevel", &token) == NOTIFY_STATUS_OK
    }

    deinit { if registered { notify_cancel(token) } }

    func read() -> PressureLevel {
        if registered {
            var state: UInt64 = 0
            if notify_get_state(token, &state) == NOTIFY_STATUS_OK, let level = PressureLevel(rawValue: Int(state)) {
                return level
            }
        }
        // Fall back to the public API: nominal / fair / serious / critical
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .moderate
        case .serious: return .heavy
        case .critical: return .trapping
        @unknown default: return .nominal
        }
    }
}
