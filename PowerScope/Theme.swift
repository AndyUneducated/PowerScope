import SwiftUI

/// The one color rule of the app: a color says where energy flows and whether
/// anything needs attention. Nothing else gets a color.
///
/// - Green: energy flowing into the battery, brighter the faster it charges.
/// - Neutral: normal and calm (idle on power, full, discharging with plenty left).
/// - Amber: needs attention soon.
/// - Red: needs action now.
enum Tone {
    case chargingFast, charging, chargingSlow, neutral, attention, critical

    var color: Color {
        switch self {
        case .chargingFast: .green
        case .charging: Color.green.mix(with: .gray, by: 0.25)
        case .chargingSlow: Color.green.mix(with: .gray, by: 0.5)
        case .neutral: .gray
        case .attention: .orange
        case .critical: .red
        }
    }

    /// Color for text and symbols drawn in this tone; neutral uses the primary label color.
    var foreground: Color {
        self == .neutral ? .primary : color
    }

    var isNeutral: Bool { self == .neutral }
}

/// Fixed colors for data series, by where the quantity lives. Used by every chart.
enum Palette {
    /// The supply side: negotiated contract, adapter, system input.
    static let input = Color.blue
    static let inputSecondary = Color.cyan
    /// The battery: its power, voltage, current and charge.
    static let battery = Color.green
    /// What the Mac consumes.
    static let system = Color.purple
    /// Quantities with no energy direction, such as temperature.
    static let other = Color.gray
}

extension ChargeMode {
    var tone: Tone {
        switch self {
        case .fastCharging: .chargingFast
        case .charging: .charging
        case .slowCharging: .chargingSlow
        case .supplementing: .attention
        case .noBattery, .onBattery, .pluggedNotCharging, .full: .neutral
        }
    }
}

extension BatterySnapshot {
    /// Battery level thresholds while discharging, matching macOS.
    static let lowBatteryPercent = 20
    static let criticalBatteryPercent = 10

    /// The tone of the overall state: the charge mode, raised by a low battery on battery power.
    var tone: Tone {
        if mode == .onBattery || mode == .supplementing {
            if percent <= Self.criticalBatteryPercent || atCritical { return .critical }
            if percent <= Self.lowBatteryPercent { return .attention }
        }
        return mode.tone
    }

    /// Symbol for the status badge.
    var statusSymbol: String {
        switch mode {
        case .fastCharging: "bolt.fill"
        case .charging: "bolt"
        case .slowCharging: "bolt.badge.clock"
        case .supplementing: "exclamationmark.triangle.fill"
        case .pluggedNotCharging: "powerplug"
        case .full: "checkmark.circle.fill"
        case .onBattery: batterySymbol
        case .noBattery: "powerplug"
        }
    }

    /// The full state keeps the neutral tone but its check mark is green.
    var statusSymbolColor: Color {
        mode == .full ? Tone.chargingFast.color : tone.foreground
    }
}

/// Severity of a single reading, for metric tiles.
enum ReadingLevel {
    case normal, attention, critical

    var tone: Tone {
        switch self {
        case .normal: .neutral
        case .attention: .attention
        case .critical: .critical
        }
    }

    static func temperature(_ celsius: Double?) -> ReadingLevel {
        guard let celsius else { return .normal }
        if celsius >= 45 { return .critical }
        if celsius >= 40 { return .attention }
        return .normal
    }

    /// Apple considers a battery below 80 % of design capacity due for service.
    static func health(_ percent: Double?) -> ReadingLevel {
        guard let percent else { return .normal }
        return percent < 80 ? .attention : .normal
    }

    static func cycles(_ count: Int?, design: Int?) -> ReadingLevel {
        guard let count, let design, design > 0 else { return .normal }
        return count >= design ? .attention : .normal
    }
}
