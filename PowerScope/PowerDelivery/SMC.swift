import Foundation
import IOKit

/// Minimal read-only client for the System Management Controller (AppleSMC).
/// Reading sensor keys does not need root on Apple Silicon.
final class SMC {
    static let shared = SMC()

    private var connection: io_connect_t = 0
    private var keyInfo: [UInt32: (size: UInt32, type: UInt32)] = [:]

    // Offsets into the 80-byte SMCKeyData_t structure used by the AppleSMC user client.
    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let command = 42
        static let bytes = 48
    }

    private enum Command: UInt8 {
        case readBytes = 5
        case readKeyInfo = 9
    }

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }

    var isAvailable: Bool { connection != 0 }

    /// Reads a numeric key. Returns nil if the key does not exist or has an unsupported type.
    func value(_ key: String) -> Double? {
        guard connection != 0, let code = fourCC(key) else { return nil }
        guard let info = info(for: code) else { return nil }

        var input = [UInt8](repeating: 0, count: 80)
        write(code, into: &input, at: Offset.key)
        write(info.size, into: &input, at: Offset.dataSize)
        input[Offset.command] = Command.readBytes.rawValue
        guard let output = call(input), output[Offset.result] == 0 else { return nil }

        let bytes = Array(output[Offset.bytes ..< Offset.bytes + Int(min(info.size, 32))])
        return decode(bytes, type: typeName(info.type))
    }

    private func info(for code: UInt32) -> (size: UInt32, type: UInt32)? {
        if let cached = keyInfo[code] { return cached }
        var input = [UInt8](repeating: 0, count: 80)
        write(code, into: &input, at: Offset.key)
        input[Offset.command] = Command.readKeyInfo.rawValue
        guard let output = call(input), output[Offset.result] == 0 else { return nil }
        let size = read(output, at: Offset.dataSize)
        let type = read(output, at: Offset.dataType)
        keyInfo[code] = (size, type)
        return (size, type)
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var input = input
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = 80
        let result = IOConnectCallStructMethod(connection, 2, &input, 80, &output, &outputSize)
        return result == KERN_SUCCESS ? output : nil
    }

    /// Apple Silicon SMC values are little-endian.
    private func decode(_ bytes: [UInt8], type: String) -> Double? {
        func le<T: FixedWidthInteger>(_: T.Type) -> T? {
            guard bytes.count >= MemoryLayout<T>.size else { return nil }
            return bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 ": return le(UInt8.self).map(Double.init)
        case "ui16": return le(UInt16.self).map(Double.init)
        case "ui32": return le(UInt32.self).map(Double.init)
        case "si8 ": return le(Int8.self).map(Double.init)
        case "si16": return le(Int16.self).map(Double.init)
        case "si32": return le(Int32.self).map(Double.init)
        default: return nil
        }
    }

    private func fourCC(_ key: String) -> UInt32? {
        let scalars = Array(key.utf8)
        guard scalars.count == 4 else { return nil }
        return scalars.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func typeName(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private func write(_ value: UInt32, into buffer: inout [UInt8], at offset: Int) {
        withUnsafeBytes(of: value) { for i in 0..<4 { buffer[offset + i] = $0[i] } }
    }

    private func read(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        buffer[offset ..< offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
}

/// Power readings taken straight from SMC sensors.
struct SMCReadings {
    var dcInVoltage: Double?      // V   (VD0R) system power input
    var dcInCurrent: Double?      // A   (ID0R)
    var dcInPower: Double?        // W   (PDTR)
    var systemPower: Double?      // W   (PSTR) total system power
    var batteryVoltage: Double?   // V   (B0AV)
    var batteryCurrent: Double?   // A   (B0AC) positive = charging

    static func read() -> SMCReadings {
        let smc = SMC.shared
        return SMCReadings(
            dcInVoltage: smc.value("VD0R"),
            dcInCurrent: smc.value("ID0R"),
            dcInPower: smc.value("PDTR"),
            systemPower: smc.value("PSTR"),
            batteryVoltage: smc.value("B0AV").map { $0 / 1000 },
            batteryCurrent: smc.value("B0AC").map { $0 / 1000 }
        )
    }
}
