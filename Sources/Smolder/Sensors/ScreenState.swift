import CoreGraphics

/// Whether any display is lit. A lit screen — and whoever is using the Mac — adds watts to every quiet
/// moment, so the idle power floor is only judged on minutes when every screen was off.
enum ScreenState {
    /// nil when the display list cannot be read.
    static func isOn() -> Bool? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
    }
}
