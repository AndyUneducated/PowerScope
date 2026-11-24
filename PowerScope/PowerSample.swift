import Foundation
import SwiftData

/// One persisted 5-second window. Readings are taken every second; each window stores
/// the average plus the min/max so short dips and spikes are not averaged away.
@Model
final class PowerSample {
    #Index<PowerSample>([\.timestamp])

    var timestamp: Date
    var percent: Double
    var voltage: Double          // V, battery pack (average)
    var current: Double          // A, positive = charging
    var batteryPower: Double     // W, positive = charging
    var inputPower: Double       // W from the adapter
    var systemLoad: Double       // W consumed by the system
    var temperature: Double?     // °C
    var isCharging: Bool
    var onExternalPower: Bool

    // Added for precision tracking; optional so existing stores migrate automatically.
    var voltageMin: Double?
    var voltageMax: Double?
    var inputVoltage: Double?    // V, system power input (average)
    var inputVoltageMin: Double?
    var inputVoltageMax: Double?
    var contractVoltage: Double? // V, negotiated PD voltage at the end of the window
    var contractCurrent: Double? // A, negotiated PD current

    init(point: HistoryPoint) {
        timestamp = point.date
        percent = point.percent
        voltage = point.voltage
        current = point.current
        batteryPower = point.batteryPower
        inputPower = point.inputPower
        systemLoad = point.systemLoad
        temperature = point.temperature
        isCharging = point.isCharging
        onExternalPower = point.onExternalPower
        voltageMin = point.voltageMin
        voltageMax = point.voltageMax
        inputVoltage = point.inputVoltage
        inputVoltageMin = point.inputVoltageMin
        inputVoltageMax = point.inputVoltageMax
        contractVoltage = point.contractVoltage
        contractCurrent = point.contractCurrent
    }

    var point: HistoryPoint {
        HistoryPoint(date: timestamp, percent: percent, voltage: voltage, current: current,
                     batteryPower: batteryPower, inputPower: inputPower, systemLoad: systemLoad,
                     temperature: temperature, isCharging: isCharging, onExternalPower: onExternalPower,
                     voltageMin: voltageMin, voltageMax: voltageMax,
                     inputVoltage: inputVoltage, inputVoltageMin: inputVoltageMin, inputVoltageMax: inputVoltageMax,
                     contractVoltage: contractVoltage, contractCurrent: contractCurrent)
    }
}

/// In-memory copy of a sample, used by the charts.
nonisolated struct HistoryPoint: Hashable, Sendable {
    var date: Date
    var percent: Double
    var voltage: Double
    var current: Double
    var batteryPower: Double
    var inputPower: Double
    var systemLoad: Double
    var temperature: Double?
    var isCharging: Bool
    var onExternalPower: Bool
    var voltageMin: Double?
    var voltageMax: Double?
    var inputVoltage: Double?
    var inputVoltageMin: Double?
    var inputVoltageMax: Double?
    var contractVoltage: Double?
    var contractCurrent: Double?
}

/// A change in the USB-C PD link. Repeats of the same kind on the same port within
/// a minute are folded into one event with a count, so a flapping link stays readable.
@Model
final class PDEvent {
    #Index<PDEvent>([\.lastDate])

    var firstDate: Date
    var lastDate: Date
    var kind: String
    var port: Int
    var count: Int
    var detail: String
    var voltage: Int?   // mV, contract voltage after the event
    var current: Int?   // mA

    init(date: Date, kind: PDEventKind, port: Int, count: Int, detail: String, voltage: Int?, current: Int?) {
        firstDate = date
        lastDate = date
        self.kind = kind.rawValue
        self.port = port
        self.count = count
        self.detail = detail
        self.voltage = voltage
        self.current = current
    }

    var eventKind: PDEventKind { PDEventKind(rawValue: kind) ?? .renegotiated }
}

nonisolated enum PDEventKind: String, CaseIterable, Sendable {
    case started, established, lost, changed, reconnected, renegotiated, hardReset, rejected, sourceSwitched

    var title: String {
        switch self {
        case .started: "Monitoring started"
        case .established: "Contract established"
        case .lost: "Contract lost"
        case .changed: "Contract changed"
        case .reconnected: "Reconnected"
        case .renegotiated: "Renegotiated"
        case .hardReset: "Hard reset"
        case .rejected: "Request rejected"
        case .sourceSwitched: "macOS switched source"
        }
    }

    var symbol: String {
        switch self {
        case .started: "play.circle"
        case .established: "link"
        case .lost: "link.badge.plus"
        case .changed: "arrow.triangle.swap"
        case .reconnected: "cable.connector"
        case .renegotiated: "arrow.clockwise"
        case .hardReset: "exclamationmark.octagon"
        case .rejected: "xmark.octagon"
        case .sourceSwitched: "arrow.left.arrow.right.circle"
        }
    }

    /// Events that indicate an unstable link.
    var isProblem: Bool {
        switch self {
        case .lost, .reconnected, .hardReset, .rejected, .sourceSwitched: true
        default: false
        }
    }
}
