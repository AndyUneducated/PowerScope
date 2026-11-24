import SwiftUI

/// The app's color rules. There are three, and nothing else gets a color:
///
/// - **Level** (`ColorScale.level`): how full the battery is, red at empty through orange
///   and yellow to green at full. Used by the outer ring and the charge bar.
/// - **Speed** (`ColorScale.speed`): how much power goes into the battery, from a pale
///   chartreuse for a trickle to a bright sky blue at 100 W. Used by the inner ring, the
///   status badge and the battery figure while charging.
/// - **Attention** (`Tone`): neutral when all is well, amber when something needs attention
///   soon, red when it needs action now.
///
/// Data series in charts keep fixed colors (`Palette`) so a quantity looks the same everywhere.
enum Tone {
    case neutral, attention, critical

    var color: Color {
        switch self {
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

/// An sRGB color with components in 0...1, so scales can be interpolated and tested.
nonisolated struct RGB: Equatable, Sendable {
    var r: Double, g: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    func mixed(with other: RGB, by t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

/// A continuous color scale: stops at given values, linear in between, clamped at both ends.
nonisolated struct ColorScale: Sendable {
    let stops: [(value: Double, rgb: RGB)]

    func rgb(at value: Double) -> RGB {
        guard let first = stops.first, let last = stops.last else { return RGB(0.5, 0.5, 0.5) }
        if value <= first.value { return first.rgb }
        if value >= last.value { return last.rgb }
        for (lo, hi) in zip(stops, stops.dropFirst()) where value <= hi.value {
            let t = hi.value > lo.value ? (value - lo.value) / (hi.value - lo.value) : 1
            return lo.rgb.mixed(with: hi.rgb, by: t)
        }
        return last.rgb
    }

    func color(at value: Double) -> Color { rgb(at: value).color }

    static let red = RGB(0.92, 0.22, 0.20)
    static let orange = RGB(1.00, 0.58, 0.00)
    static let yellow = RGB(1.00, 0.80, 0.00)
    static let yellowGreen = RGB(0.62, 0.80, 0.16)
    static let green = RGB(0.20, 0.78, 0.35)

    /// Battery level in percent.
    static let level = ColorScale(stops: [
        (0, red), (10, red), (20, orange), (40, yellow), (60, yellowGreen), (100, green),
    ])

    static let paleChartreuse = RGB(0.74, 0.82, 0.50)
    static let mint = RGB(0.00, 0.78, 0.62)
    static let teal = RGB(0.00, 0.68, 0.74)
    static let cyan = RGB(0.12, 0.72, 0.92)
    /// Kept greener than the system blue that charts use for input power.
    static let electricSky = RGB(0.10, 0.66, 1.00)

    /// Watts going into the battery; the ring's full scale is `speedFullScaleWatts`.
    static let speed = ColorScale(stops: [
        (0, paleChartreuse), (20, green), (40, mint), (60, teal), (80, cyan), (100, electricSky),
    ])
    static let speedFullScaleWatts = 100.0
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
        case .supplementing: .attention
        default: .neutral
        }
    }
}

extension BatterySnapshot {
    /// Battery level thresholds while discharging, matching macOS.
    static let lowBatteryPercent = 20
    static let criticalBatteryPercent = 10

    /// Whether anything needs attention: a low battery on battery power, or the battery
    /// having to help the charger.
    var tone: Tone {
        if mode == .onBattery || mode == .supplementing {
            if percent <= Self.criticalBatteryPercent || atCritical { return .critical }
            if percent <= Self.lowBatteryPercent { return .attention }
        }
        return mode.tone
    }

    /// Watts going into the battery while charging, else nil.
    var chargingWatts: Double? { mode.isCharging ? max(0, batteryPowerW ?? 0) : nil }

    /// The level color for the current charge.
    var levelColor: Color { ColorScale.level.color(at: Double(percent)) }

    /// The color of the current state, or nil when it is calm and neutral: the speed color
    /// while charging, green when full, else the attention tone.
    var stateColor: Color? {
        if let watts = chargingWatts { return ColorScale.speed.color(at: watts) }
        if mode == .full { return ColorScale.green.color }
        return tone.isNeutral ? nil : tone.color
    }

    /// Symbol for the status badge.
    var statusSymbol: String {
        switch mode {
        case .veryFastCharging, .fastCharging: "bolt.fill"
        case .charging: "bolt"
        case .slowCharging: "bolt.badge.clock"
        case .supplementing: "exclamationmark.triangle.fill"
        case .pluggedNotCharging: "powerplug"
        case .full: "checkmark.circle.fill"
        case .onBattery: batterySymbol
        case .noBattery: "powerplug"
        }
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
