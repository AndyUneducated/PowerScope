import SwiftUI

struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: symbol ?? "circle")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var symbol: String
    var tint: Color = .accentColor
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .imageScale(.medium)
                .tint(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit).font(.callout).foregroundStyle(.secondary)
                }
            }
            // Always reserve the footnote line so tiles in a row line up.
            Text(footnote ?? " ").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.vertical, 3)
    }
}

/// Two columns of InfoRows separated by thin dividers.
struct InfoGrid: View {
    let rows: [(String, String)]
    var columns = 2

    var body: some View {
        let perColumn = Int((Double(rows.count) / Double(columns)).rounded(.up))
        HStack(alignment: .top, spacing: 28) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: 0) {
                    let slice = rows.dropFirst(column * perColumn).prefix(perColumn)
                    ForEach(Array(slice.enumerated()), id: \.offset) { index, row in
                        InfoRow(label: row.0, value: row.1)
                        if index < slice.count - 1 { Divider().opacity(0.5) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

struct RingGauge: View {
    let percent: Int
    let tint: Color
    var lineWidth: CGFloat = 12
    var fontSize: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(percent, 0), 100)) / 100)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: percent)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(percent)")
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%").font(.system(size: fontSize * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBadge: View {
    let mode: ChargeMode

    var body: some View {
        Label(mode.title, systemImage: mode.symbol)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(mode.color)
            .background(Capsule().fill(mode.color.opacity(0.14)))
    }
}

struct PageScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(20)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension BatterySnapshot {
    var healthStatusText: String {
        switch healthText?.lowercased() {
        case "good": "Good"
        case "fair": "Fair"
        case "poor": "Poor"
        case "check battery", "service": "Service recommended"
        case nil:
            // macOS no longer publishes BatteryHealth; use Apple's 80% service threshold.
            healthPercent.map { $0 >= 80 ? "Normal" : "Service recommended" } ?? "—"
        default: healthText ?? "—"
        }
    }

    var adapterSummary: String? {
        guard let a = adapter else { return externalConnected ? "Connected to power" : nil }
        var parts: [String] = []
        if let w = a.watts { parts.append("\(w)W") }
        parts.append(a.typeText)
        var line = parts.joined(separator: " ")
        // Prefer the negotiated PD contract over the adapter's rated maximum.
        if let contract = pd.contract {
            let current = contract.displayCurrent.map { (contract.current == nil ? "≤ " : "") + Format.number(Double($0) / 1000, digits: 2, unit: "A") } ?? ""
            line += " · negotiated \(Format.number(Double(contract.voltage) / 1000, digits: 2, unit: "V")) \(current)"
        } else if let v = a.voltage, let c = a.current {
            line += " · rated \(Format.number(Double(v) / 1000, digits: 0))V \(Format.number(Double(c) / 1000, digits: 2))A"
        }
        return line
    }
}
