import CoreGraphics

/// Which screens are lit. A lit screen — and whoever is using the Mac — adds watts to every quiet moment, so the
/// idle power floor is only judged on minutes when every screen was off.
///
/// Two kinds are told apart:
/// - **built-in**: the Mac's own panel (MacBook, iMac). On a MacBook it can only be lit with the lid open.
/// - **other**: everything else macOS drives as a display — a monitor, an HDMI dummy plug, or a virtual display
///   that a remote-desktop app creates when no screen is lit (UU Remote does this on a closed MacBook or a
///   headless Mac mini). Smolder cannot tell these apart; which program kept them awake is recorded separately
///   (`ScreenHolders`).
enum ScreenState {
    struct Reading: Equatable {
        var builtinLit: Bool
        var otherLit: Int
    }

    /// nil when the display list cannot be read.
    static func isOn() -> Bool? {
        read().map { $0.builtinLit || $0.otherLit > 0 }
    }

    /// Lit displays right now; nil when the display list cannot be read.
    static func read() -> Reading? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        let lit = ids.prefix(Int(count)).filter { CGDisplayIsAsleep($0) == 0 }
        let builtin = lit.filter { CGDisplayIsBuiltin($0) != 0 }.count
        return Reading(builtinLit: builtin > 0, otherLit: lit.count - builtin)
    }

    /// Whether this Mac has a screen of its own. A MacBook's panel stays in the online list while the lid is
    /// closed; a Mac mini or Mac Studio has none.
    static func hasBuiltinDisplay() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 }
    }

    /// One minute from its readings (nil where a reading failed): whether the built-in screen was lit at any of
    /// them — nil on a Mac without one — and the most other screens lit at once. Both nil if no reading worked.
    static func minute(_ readings: [Reading?], hasBuiltin: Bool) -> (builtin: Bool?, others: Int?) {
        let read = readings.compactMap { $0 }
        guard !read.isEmpty else { return (nil, nil) }
        return (hasBuiltin ? read.contains(where: \.builtinLit) : nil, read.map(\.otherLit).max())
    }
}
