import SwiftUI

/// Where the charger's power goes, against what the contract allows.
///
/// One bar the width of the charger's budget (the contract power, else the adapter rating),
/// split into system load and battery charging, with the unused headroom left empty. The
/// measured input equals system load plus battery charging; the reported conversion loss is
/// outside that measurement, so it is not part of the bar. When the system needs more than the charger gives, the battery makes up the
/// difference and the bar turns amber.
struct PowerBudget: Equatable {
    var budget: Double        // W the charger can deliver
    var system: Double        // W the Mac uses, supplied by the charger
    var battery: Double       // W going into the battery (0 when not charging)
    var assist: Double        // W the battery adds because the charger is not enough

    var used: Double { system + battery }
    var headroom: Double { max(0, budget - used) }
    var usedFraction: Double { budget > 0 ? min(1, used / budget) : 0 }

    init(budget: Double, system: Double, battery: Double, assist: Double) {
        self.budget = budget
        self.system = system
        self.battery = battery
        self.assist = assist
    }

    /// Nil when the Mac is not on external power or nothing is known about the charger.
    init?(_ s: BatterySnapshot) {
        guard s.externalConnected, let input = s.inputPowerW else { return nil }
        let batteryW = s.batteryPowerW ?? 0
        let charging = max(0, batteryW)
        let assist = max(0, -batteryW)
        // The charger supplies the input; whatever does not go into the battery runs the system.
        let system = max(0, input - charging)
        let budget = s.pd.contract?.powerW ?? s.adapter?.watts.map(Double.init) ?? input
        self.init(budget: max(budget, input), system: system, battery: charging, assist: assist > 0.5 ? assist : 0)
    }
}

struct PowerBudgetBar: View {
    let budget: PowerBudget
    var compact = false

    var body: some View {
        let b = budget
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(compact ? "Charger \(Self.w(b.used)) of \(Self.w(b.budget))"
                             : "Power budget · \(Self.w(b.used)) of \(Self.w(b.budget)) used (\(Int((b.usedFraction * 100).rounded())) %)")
                Spacer()
                if b.assist > 0 {
                    Label("Battery adds \(Self.w(b.assist))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.attention.color)
                } else if !compact {
                    Text("Headroom \(Self.w(b.headroom))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            GeometryReader { geo in
                let scale = geo.size.width / max(b.budget, b.used, 1)
                HStack(spacing: 1) {
                    segment(b.system * scale, Palette.system)
                    segment(b.battery * scale, Palette.battery)
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width, alignment: .leading)
                .background(Color.primary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(b.assist > 0 ? Tone.attention.color : .clear, lineWidth: 1.5)
                )
            }
            .frame(height: compact ? 10 : 16)

            if !compact {
                HStack(spacing: 14) {
                    legend(Palette.system, "System \(Self.w(b.system))")
                    legend(Palette.battery, "Battery \(Self.w(b.battery))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func segment(_ width: CGFloat, _ color: Color) -> some View {
        Rectangle().fill(color.gradient).frame(width: max(0, width))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).monospacedDigit()
        }
    }

    static func w(_ watts: Double) -> String { Format.number(watts, digits: watts >= 100 ? 0 : 1, unit: "W") }
}
