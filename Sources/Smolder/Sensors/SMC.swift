import Foundation
import IOKit

// User-space AppleSMC reader. The parameter struct must match the kernel layout exactly (80 bytes).
private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var mem: UInt32 = 0 }
private struct SMCKeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var attributes: UInt8 = 0; var pad0: UInt8 = 0; var pad1: UInt8 = 0; var pad2: UInt8 = 0 }
private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                              UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
private struct SMCParam {
    var key: UInt32 = 0
    var version = SMCVersion()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMC {
    private var connection: io_connect_t = 0
    private let kernelIndex: UInt32 = 2
    private let cmdReadKeyInfo: UInt8 = 9
    private let cmdReadBytes: UInt8 = 5

    init?() {
        precondition(MemoryLayout<SMCParam>.stride == 80, "SMC parameter struct has the wrong layout")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { IOServiceClose(connection) }

    /// P-core cluster power in watts. Tracks `powermetrics` CPU power within ~5 % on an M4, including when
    /// the chip caps frequency under a full load (which DVFS residency cannot see); needs no root.
    static let cpuPowerKey = "PP0b"

    /// Reads a `flt ` key; nil if the key does not exist on this machine.
    func float(_ key: String) -> Double? {
        guard let (type, bytes) = read(key), type == "flt ", bytes.count == 4 else { return nil }
        let value = bytes.withUnsafeBytes { $0.load(as: Float.self) }
        return value.isFinite ? Double(value) : nil
    }

    private func call(_ input: inout SMCParam) -> Bool {
        var output = SMCParam()
        var size = MemoryLayout<SMCParam>.stride
        let result = IOConnectCallStructMethod(connection, kernelIndex, &input, MemoryLayout<SMCParam>.stride, &output, &size)
        input = output
        return result == KERN_SUCCESS && output.result == 0
    }

    private func read(_ key: String) -> (String, [UInt8])? {
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var info = SMCParam()
        info.key = code
        info.command = cmdReadKeyInfo
        guard call(&info) else { return nil }
        let size = Int(info.keyInfo.dataSize)
        let type = info.keyInfo.dataType
        var data = SMCParam()
        data.key = code
        data.keyInfo.dataSize = UInt32(size)
        data.command = cmdReadBytes
        guard call(&data), size <= 32 else { return nil }
        let bytes = withUnsafeBytes(of: data.bytes) { Array($0.prefix(size)) }
        let typeName = String(bytes: [UInt8(type >> 24), UInt8(type >> 16 & 0xff), UInt8(type >> 8 & 0xff), UInt8(type & 0xff)], encoding: .ascii) ?? ""
        return (typeName, bytes)
    }
}
