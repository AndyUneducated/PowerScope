import Foundation
import SwiftUI

/// One USB-C Power Delivery profile (PDO) the adapter offers.
struct PDProfile: Identifiable, Hashable {
    let index: Int
    let maxVoltage: Int   // mV
    let maxCurrent: Int   // mA
    var id: Int { index }
    var watts: Double { Double(maxVoltage) * Double(maxCurrent) / 1_000_000 }
}

struct CellInfo: Identifiable, Hashable {
    let id: Int
    let voltage: Int?     // mV
    let qmax: Int?        // mAh
}

struct AdapterInfo {
    var watts: Int?
    var voltage: Int?          // mV
    var current: Int?          // mA
    var description: String?
    var name: String?
    var manufacturer: String?
    var model: String?
    var serial: String?
    var firmware: String?
    var hardware: String?
    var isWireless: Bool?
    var familyCode: Int?
    var powerTier: Int?
    var profiles: [PDProfile] = []
    var activeProfileIndex: Int?

    var isUSBPD: Bool {
        !profiles.isEmpty || (description?.lowercased().contains("pd") ?? false)
    }

    var typeText: String {
        if isWireless == true { return "Wireless" }
        if isUSBPD { return "USB-C PD" }
        return description ?? "Unknown"
    }
}

/// Live power telemetry from `PowerTelemetryData` (values in mW / mV / mA).
struct Telemetry {
    var systemPowerIn: Int?
    var systemVoltageIn: Int?
    var systemCurrentIn: Int?
    var systemLoad: Int?
    var batteryPower: Int?
    var adapterEfficiencyLoss: Int?
    var wallEnergyEstimate: Int?
}

struct LifetimeInfo {
    var maxTemperature: Int?          // °C
    var minTemperature: Int?          // °C
    var averageTemperature: Double?   // °C
    var maxChargeCurrent: Int?        // mA
    var maxDischargeCurrent: Int?     // mA
    var maxPackVoltage: Int?          // mV
    var minPackVoltage: Int?          // mV
    var operatingTime: Int?           // hours
}

enum ChargeMode {
    case noBattery, onBattery, supplementing, fastCharging, charging, slowCharging, pluggedNotCharging, full

    var title: String {
        switch self {
        case .noBattery: "No battery"
        case .onBattery: "On battery"
        case .supplementing: "Adapter insufficient · battery assisting"
        case .fastCharging: "Fast charging"
        case .charging: "Charging"
        case .slowCharging: "Slow / trickle charging"
        case .pluggedNotCharging: "Plugged in · not charging"
        case .full: "Fully charged"
        }
    }

    var color: Color {
        switch self {
        case .noBattery: .gray
        case .onBattery: .orange
        case .supplementing: .yellow
        case .fastCharging: .pink
        case .charging: .green
        case .slowCharging: .teal
        case .pluggedNotCharging: .blue
        case .full: .green
        }
    }

    var symbol: String {
        switch self {
        case .noBattery: "powerplug"
        case .onBattery: "battery.75percent"
        case .supplementing: "exclamationmark.triangle"
        case .fastCharging: "bolt.fill"
        case .charging: "bolt"
        case .slowCharging: "tortoise"
        case .pluggedNotCharging: "powerplug.fill"
        case .full: "checkmark.circle.fill"
        }
    }
}

struct BatterySnapshot {
    /// Charging power (W) at or above which charging counts as fast.
    static let fastChargeWatts = 30.0
    /// Charging power (W) below which charging counts as slow / trickle.
    static let slowChargeWatts = 10.0

    var date: Date = .now
    var hasBattery = false
    var percent = 0
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var atCritical = false

    var voltage: Int?            // mV
    var amperage: Int?           // mA, positive = charging
    var instantAmperage: Int?    // mA

    var designCapacity: Int?     // mAh
    var fullChargeCapacity: Int? // mAh (AppleRawMaxCapacity)
    var nominalChargeCapacity: Int?
    var remainingCapacity: Int?
    var cycleCount: Int?
    var designCycleCount: Int?

    var temperature: Double?     // °C
    var virtualTemperature: Double?

    var timeToFull: Int?         // minutes
    var timeToEmpty: Int?        // minutes

    var serial: String?
    var deviceName: String?
    var mfgStrings: [String] = []
    var manufactureCode: String?
    var chemID: Int?
    var gaugeFirmware: Int?
    var healthText: String?
    var healthCondition: String?
    var optimizedCharging: Bool?
    var lowPowerMode: Bool?
    var dailyMinSoc: Int?
    var dailyMaxSoc: Int?

    var cells: [CellInfo] = []
    var lifetime: LifetimeInfo?
    var adapter: AdapterInfo?
    var telemetry = Telemetry()

    var notChargingReason: Int?
    var slowChargingReason: Int?
    var thermallyLimitedTime: Int?

    // Power Delivery and precision sources.
    var pd = PDState()
    var smc = SMCReadings()
    var chargerVBUS: Int?            // mV measured by the charger IC (0 / nil when not reported)
    var chargerIBUS: Int?            // mA
    var chargeTargetCellVoltage: Int? // mV per cell the charger regulates to
    var chargeCurrentLimit: Int?     // mA
    var ipdInputVoltage: Int?        // mV, PMU input setpoint
    var ipdInputCurrent: Int?        // mA
    var ipdInputPower: Int?          // mW
    var gaugeUpdateTime: Int?        // gauge timestamp (s); unchanged means stale gauge values

    /// Sum of the cell-group voltages in V (cell groups are in series).
    var cellSumV: Double? {
        let volts = cells.compactMap(\.voltage)
        guard !volts.isEmpty, volts.count == cells.count else { return nil }
        return Double(volts.reduce(0, +)) / 1000
    }

    var raw: [(key: String, value: String)] = []

    // MARK: Derived values

    var voltageV: Double? { voltage.map { Double($0) / 1000 } }
    var currentA: Double? { amperage.map { Double($0) / 1000 } }

    /// Battery power in W; positive while charging, negative while discharging.
    var batteryPowerW: Double? {
        guard let voltage, let amperage else { return nil }
        return Double(voltage) * Double(amperage) / 1_000_000
    }

    var inputPowerW: Double? { telemetry.systemPowerIn.map { Double($0) / 1000 } }
    var inputVoltageV: Double? { telemetry.systemVoltageIn.map { Double($0) / 1000 } }
    var inputCurrentA: Double? { telemetry.systemCurrentIn.map { Double($0) / 1000 } }
    var systemLoadW: Double? { telemetry.systemLoad.map { Double($0) / 1000 } }
    var adapterLossW: Double? { telemetry.adapterEfficiencyLoss.map { Double($0) / 1000 } }

    /// Full charge capacity ÷ design capacity.
    var healthPercent: Double? {
        guard let fullChargeCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return Double(fullChargeCapacity) / Double(designCapacity) * 100
    }

    /// Nominal charge capacity ÷ design capacity (the figure macOS shows in System Settings).
    var nominalHealthPercent: Double? {
        guard let nominalChargeCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return Double(nominalChargeCapacity) / Double(designCapacity) * 100
    }

    var mode: ChargeMode {
        guard hasBattery else { return .noBattery }
        guard externalConnected else { return .onBattery }
        // Judge by measured power: the IsCharging flag lags and often reads No while
        // current is flowing into the battery.
        let watts = batteryPowerW ?? 0
        if watts > 0.5 {
            if watts >= Self.fastChargeWatts { return .fastCharging }
            if watts >= Self.slowChargeWatts { return .charging }
            return .slowCharging
        }
        // On AC but the battery is discharging: the system draws more than the adapter gives.
        if watts < -1 { return .supplementing }
        if fullyCharged || percent >= 100 { return .full }
        return .pluggedNotCharging
    }

    var batterySymbol: String {
        if mode == .fastCharging || mode == .charging || mode == .slowCharging {
            return "battery.100percent.bolt"
        }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var remainingTimeText: String {
        switch mode {
        case .fastCharging, .charging, .slowCharging:
            if let timeToFull { return "About \(Format.minutes(timeToFull)) until full" }
            return "Calculating time until full…"
        case .onBattery, .supplementing:
            if let timeToEmpty { return "About \(Format.minutes(timeToEmpty)) remaining" }
            return "Calculating time remaining…"
        case .full: return "Battery fully charged"
        case .pluggedNotCharging: return "Running on adapter, battery charging paused"
        case .noBattery: return "No battery detected"
        }
    }
}
