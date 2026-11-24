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
    /// Tiles stay neutral; only a reading that is off gets the attention or critical color.
    var level: ReadingLevel = .normal
    var footnote: String?

    var body: some View {
        let tone = level.tone
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(tone.isNeutral ? Color.secondary : tone.color)
                .imageScale(.medium)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tone.foreground)
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

/// The inner ring of `BatteryRing`: power into the battery on a fixed 0–100 W scale, or,
/// drawn backwards in amber, the power the battery adds when the charger is not enough.
struct RingSpeed: Equatable {
    var fraction: Double
    var rgb: RGB
    var reversed: Bool

    init(fraction: Double, rgb: RGB, reversed: Bool) {
        self.fraction = fraction
        self.rgb = rgb
        self.reversed = reversed
    }

    /// Nil when the battery is neither charging nor assisting.
    init?(_ s: BatterySnapshot) {
        let full = ColorScale.speedFullScaleWatts
        if let watts = s.chargingWatts {
            self.init(fraction: min(1, watts / full), rgb: ColorScale.speed.rgb(at: watts), reversed: false)
        } else if s.mode == .supplementing, let watts = s.batteryPowerW, watts < 0 {
            self.init(fraction: min(1, -watts / full), rgb: ColorScale.orange, reversed: true)
        } else {
            return nil
        }
    }
}

extension BatterySnapshot {
    /// The short line under the percentage in the ring.
    var ringCaption: String? {
        let watts = Format.number(batteryPowerW.map(abs), digits: 0, unit: "W")
        switch mode {
        case .veryFastCharging: return "\(watts) · Very fast"
        case .fastCharging: return "\(watts) · Fast"
        case .charging: return "\(watts) · Charging"
        case .slowCharging: return "\(watts) · Trickle"
        case .supplementing: return "−\(watts) · Assisting"
        case .full: return "Full"
        case .pluggedNotCharging: return "Paused"
        case .onBattery: return "On battery"
        case .noBattery: return nil
        }
    }
}

/// Two rings: the outer one is the charge level, colored by level; the inner one is the
/// charging speed (see `RingSpeed`), hidden when the battery is idle or discharging.
struct BatteryRing: View {
    let percent: Int
    var speed: RingSpeed?
    var caption: String?
    var lineWidth: CGFloat = 12
    var fontSize: CGFloat = 34

    init(snapshot s: BatterySnapshot, showCaption: Bool = true, lineWidth: CGFloat = 12, fontSize: CGFloat = 34) {
        percent = s.percent
        speed = RingSpeed(s)
        caption = showCaption ? s.ringCaption : nil
        self.lineWidth = lineWidth
        self.fontSize = fontSize
    }

    private var level: Double { Double(min(max(percent, 0), 100)) / 100 }

    /// A light band in the middle of the arc and the full color at both ends, so a full
    /// circle has no seam where it closes.
    private static func sheen(_ color: Color, from start: Double, to end: Double) -> AngularGradient {
        AngularGradient(colors: [color, color.mix(with: .white, by: 0.3), color], center: .center,
                        startAngle: .degrees(360 * start), endAngle: .degrees(360 * max(end, start + 0.01)))
    }

    var body: some View {
        let levelColor = ColorScale.level.color(at: Double(percent))
        let innerWidth = lineWidth * 0.5
        let inset = lineWidth * 0.75 + 3
        ZStack {
            Circle().stroke(levelColor.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: level)
                .stroke(Self.sheen(levelColor, from: 0, to: level),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Group {
                Circle().stroke(Color.primary.opacity(0.06), lineWidth: innerWidth)
                if let speed {
                    let color = speed.rgb.color
                    let f = max(speed.fraction, 0.01)
                    Circle()
                        .trim(from: speed.reversed ? 1 - f : 0, to: speed.reversed ? 1 : f)
                        .stroke(Self.sheen(color, from: speed.reversed ? 1 - f : 0, to: speed.reversed ? 1 : f),
                                style: StrokeStyle(lineWidth: innerWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .padding(inset)

            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(percent)")
                        .font(.system(size: fontSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("%").font(.system(size: fontSize * 0.45, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                if let caption {
                    // While charging, a bolt in the speed color leads the caption.
                    let bolt = speed.flatMap { $0.reversed ? nil : $0.rgb.color }
                    ((bolt.map { Text(Image(systemName: "bolt.fill")).foregroundStyle($0) + Text(" ") } ?? Text(""))
                        + Text(caption).foregroundStyle(.secondary))
                        .font(.system(size: max(10, fontSize * 0.3), weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(inset + innerWidth)
        }
        .animation(.easeInOut, value: percent)
        .animation(.easeInOut, value: speed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(percent) percent" + (caption.map { ", \($0)" } ?? ""))
    }
}

struct StatusBadge: View {
    let snapshot: BatterySnapshot

    var body: some View {
        let color = snapshot.stateColor
        Label {
            Text(snapshot.mode.title).foregroundStyle(color ?? .primary)
        } icon: {
            Image(systemName: snapshot.statusSymbol).foregroundStyle(color ?? .primary)
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(color?.opacity(0.16) ?? Color.primary.opacity(0.08)))
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

/// A card whose body can be collapsed. The open/closed state is remembered per `id` across
/// launches. A collapsed card still shows a one-line summary in its header, so a problem
/// stays visible, and it does not build its content at all.
struct CollapsibleCard<Content: View>: View {
    let title: String
    let symbol: String
    var summary: String?
    var summaryTone: Tone = .neutral
    @ViewBuilder var content: () -> Content
    @AppStorage private var expanded: Bool

    init(id: String, title: String, symbol: String, summary: String? = nil, summaryTone: Tone = .neutral,
         expandedByDefault: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.summary = summary
        self.summaryTone = summaryTone
        self.content = content
        _expanded = AppStorage(wrappedValue: expandedByDefault, "section.\(id).expanded")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Label(title, systemImage: symbol)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 12)
                    if let summary {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(summaryTone.isNeutral ? Color.secondary : summaryTone.color)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse" : "Expand")

            if expanded {
                content()
            }
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

/// One grouped reading on the Overview: a large value, a progress bar and a line of context.
struct SummaryCard: View {
    let title: String
    let symbol: String
    let value: String
    var unit: String = ""
    var caption: String
    var progress: Double?
    var tone: Tone = .neutral
    var progressTint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.callout)
                .foregroundStyle(tone.isNeutral ? Color.secondary : tone.color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tone.foreground)
                    .contentTransition(.numericText())
                if !unit.isEmpty { Text(unit).font(.callout).foregroundStyle(.secondary) }
            }
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(progressTint ?? (tone.isNeutral ? Color.gray : tone.color))
            }
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
