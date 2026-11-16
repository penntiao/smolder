import Foundation
import IOKit
import IOKit.ps

/// What kind of Mac this is, read once at launch. Smolder runs on any Apple Silicon Mac; what it can measure
/// and what it says depend on the hardware:
/// - a lid (MacBook): the drift check compares minutes of one lid state, since a closed lid runs hotter;
/// - a battery: the room is estimated from it, and it has its own hard limit;
/// - fans (Mac mini, Mac Studio, MacBook Pro): their speed is shown, and an alert about heat says to check them;
/// - a screen of its own (MacBook, iMac): each minute records whether it was lit apart from any other screen.
struct Machine: Codable, Equatable {
    var name: String?        // "MacBook Air (13-inch, M4, 2025)", "Mac mini (2024)"
    var identifier: String?  // "Mac16,12"
    var hasLid: Bool
    var hasBattery: Bool
    var fans: Int
    var hasBuiltinDisplay = false

    static func detect(smc: SMC?) -> Machine {
        let hasLid = LidState.isClosed() != nil
        return Machine(name: productName(), identifier: sysctlString("hw.model"), hasLid: hasLid,
                       hasBattery: hasInternalBattery(), fans: smc?.fanCount() ?? 0,
                       hasBuiltinDisplay: hasLid || ScreenState.hasBuiltinDisplay())
    }

    /// One line for `--probe` and the settings pane.
    var summary: String {
        var parts = [name ?? identifier ?? "Mac"]
        if let identifier, name != nil { parts.append(identifier) }
        parts.append(hasLid ? L("lid") : L("no lid"))
        parts.append(hasBuiltinDisplay ? L("built-in screen") : L("no built-in screen"))
        parts.append(hasBattery ? L("battery") : L("no battery"))
        parts.append(fans == 0 ? L("fanless") : fans == 1 ? L("1 fan") : L("%d fans", fans))
        return parts.joined(separator: " · ")
    }

    /// The marketing name from the device tree; no root needed.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        return name.isEmpty ? nil : name
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}
