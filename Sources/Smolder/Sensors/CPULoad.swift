import Foundation
import Darwin

/// Whole-machine CPU usage in cores (0 = idle, 10 = ten cores fully busy).
final class CPULoad {
    private var previous: [(busy: UInt64, total: UInt64)] = []

    func sample() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }

        var current: [(busy: UInt64, total: UInt64)] = []
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            current.append((user + system + nice, user + system + nice + idle))
        }
        defer { previous = current }
        guard previous.count == current.count else { return nil }

        var cores = 0.0
        for (old, new) in zip(previous, current) {
            let total = new.total &- old.total
            guard total > 0 else { continue }
            cores += Double(new.busy &- old.busy) / Double(total)
        }
        return cores
    }

    static var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }
}
