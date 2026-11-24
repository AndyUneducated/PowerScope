import Foundation

/// A reference reading taken with an external USB-C PD meter, stored per adapter.
///
/// macOS does not expose a calibrated VBUS measurement, so the meter is the ground truth:
/// - `vbusOffset` = meter VBUS − negotiated voltage. Applied to the negotiated voltage it
///   gives the adapter's real output voltage (a PD source may deviate ±5 % from the PDO).
/// - `powerGain` = meter power ÷ reported input power at the same moment. It corrects the
///   system's input-power telemetry.
nonisolated struct Calibration: Codable, Hashable, Sendable {
    var date: Date
    var meterVoltage: Double       // V
    var meterCurrent: Double       // A
    var negotiatedVoltage: Double  // V at calibration time
    var reportedInputPower: Double // W at calibration time

    var vbusOffset: Double { meterVoltage - negotiatedVoltage }
    var vbusErrorPercent: Double { negotiatedVoltage > 0 ? vbusOffset / negotiatedVoltage * 100 : 0 }
    var meterPower: Double { meterVoltage * meterCurrent }
    var powerGain: Double? { reportedInputPower > 0.5 ? meterPower / reportedInputPower : nil }
}

enum CalibrationStore {
    private static let defaultsKey = "calibrations.v1"

    /// Identifies a physical adapter as well as the system allows.
    static func adapterKey(_ adapter: AdapterInfo?) -> String? {
        guard let adapter, let watts = adapter.watts else { return nil }
        return [String(watts) + "W", Format.hex(adapter.familyCode), adapter.serial ?? adapter.name ?? ""]
            .joined(separator: "|")
    }

    static func all() -> [String: Calibration] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Calibration].self, from: data) else { return [:] }
        return decoded
    }

    static func calibration(for adapter: AdapterInfo?) -> Calibration? {
        adapterKey(adapter).flatMap { all()[$0] }
    }

    static func save(_ calibration: Calibration?, for adapter: AdapterInfo?) {
        guard let key = adapterKey(adapter) else { return }
        var map = all()
        map[key] = calibration
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
