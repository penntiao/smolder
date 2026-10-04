import Foundation
import IOKit

// On Apple Silicon the temperature sensors are exposed through IOHIDEventSystem (private API, no root needed).
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ match: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

struct TemperatureReading {
    var dieMax: Double?      // hottest SoC die sensor
    var dieAvg: Double?      // mean of SoC die sensors
    var ssd: Double?
    var battery: Double?
}

final class HIDTemperature {
    private let client: AnyObject
    private let eventTypeTemperature: Int64 = 15

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault).takeRetainedValue()
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
    }

    func read() -> TemperatureReading {
        let services = (IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
        var die: [Double] = []
        var nand: [Double] = []
        var batt: [Double] = []
        for service in services {
            guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = IOHIDServiceClientCopyEvent(service, eventTypeTemperature, 0, 0)?.takeRetainedValue()
            else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(eventTypeTemperature << 16))
            // Drop invalid readings: some tdev sensors report -21 °C placeholders, tcal is a calibration constant
            guard value > 5, value < 130 else { continue }
            if name.contains("tdie") {
                die.append(value)
            } else if name.hasPrefix("NAND") {
                nand.append(value)
            } else if name.hasPrefix("gas gauge battery") {
                batt.append(value)
            }
        }
        return TemperatureReading(
            dieMax: die.max(),
            dieAvg: die.isEmpty ? nil : die.reduce(0, +) / Double(die.count),
            ssd: nand.max(),
            battery: batt.isEmpty ? nil : batt.reduce(0, +) / Double(batt.count)
        )
    }
}
