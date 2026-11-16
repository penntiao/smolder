import Foundation
import IOKit

/// Whether the lid is closed. A closed lid covers the keyboard deck, part of what a laptop sheds heat through,
/// so the same watts run the die hotter than with the lid open: the drift check only compares minutes of one kind.
enum LidState {
    /// nil on a Mac without a lid, or when the registry cannot be read. No root needed.
    static func isClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
