import Charts
import SwiftUI

// MARK: - Shared helpers

private func volts(_ mV: Int?, digits: Int = 2) -> String {
    Format.number(mV.map { Double($0) / 1000 }, digits: digits, unit: "V")
}

private func amps(_ mA: Int?, digits: Int = 2) -> String {
    Format.number(mA.map { Double($0) / 1000 }, digits: digits, unit: "A")
}

extension CheckStatus {
    var color: Color {
        switch self {
        case .match: .green
        case .mismatch: .orange
        case .unavailable: .secondary
        }
    }
}

// MARK: - PD contract

struct PDContractCard: View {
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        Card(title: "PD Contract", symbol: "bolt.badge.checkmark") {
            if let contract = s.pd.contract, let port = s.pd.activePort {
                HStack(alignment: .firstTextBaseline, spacing: 28) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(volts(contract.voltage))
                            .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("Negotiated voltage").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contract.current != nil ? amps(contract.current) : "≤ " + amps(contract.currentLimit))
                            .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(contract.current != nil ? "Negotiated current" : "Current limit (PDO)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Format.number(contract.powerW, digits: 1, unit: "W"))
                            .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(contract.current != nil ? "Contract power" : "Max power").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text(basisText(contract, port: port))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if contract.rdo?.capabilityMismatch == true {
                    Label("Capability mismatch: the Mac wants more power than this source offers.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            } else {
                Text(s.externalConnected ? "No PD profile in use right now (non-PD source, or the link is re-attaching at 5 V)." : "Not connected to power.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            Text("Cross-check").font(.subheadline.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(s.contractCrossChecks) { check in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: check.status.symbol).foregroundStyle(check.status.color)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.source)
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(volts(check.voltage)) · \(amps(check.current))").monospacedDigit()
                    }
                    .font(.callout)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func basisText(_ c: PDContract, port: PDPortState) -> String {
        let pdo = "PDO \(c.pdo.position) (\(c.pdo.kind.rawValue), \(Format.hex(Int(c.pdo.raw))))"
        switch c.basis {
        case .confirmed:
            return "\(pdo) on port controller \(port.index). Selected by the power manager and confirmed by the port controller's RDO \(Format.hex(Int(port.rawRDO)))."
        case .powerManager:
            return "\(pdo) on port controller \(port.index), selected by the power manager. The port controller's RDO was not refreshed for this contract, so the operating current is unknown and the PDO limit is shown."
        case .rdoOnly:
            return "\(pdo) on port controller \(port.index), decoded from the RDO \(Format.hex(Int(port.rawRDO))). The power manager publishes no selection to confirm it."
        }
    }
}

// MARK: - Live voltage chart

struct LiveVoltageChart: View {
    @Environment(BatteryMonitor.self) private var monitor

    private struct Point: Identifiable {
        let id: Int
        let date: Date
        let value: Double
        let series: String
    }

    private static let series: [(String, Color, KeyPath<LiveReading, Double?>)] = [
        ("Negotiated", .green, \.contract),
        ("System input (telemetry)", .blue, \.systemInput),
        ("System input (SMC)", .cyan, \.smcInput),
        ("Battery pack (SMC)", .indigo, \.smcPack),
    ]

    var body: some View {
        let points = monitor.live.flatMap { reading in
            Self.series.compactMap { name, _, key in reading[keyPath: key].map { (reading.date, $0, name) } }
        }
        .enumerated().map { Point(id: $0.offset, date: $0.element.0, value: $0.element.1, series: $0.element.2) }

        Card(title: "Live Voltages (1 s)", symbol: "waveform.path.ecg") {
            if points.isEmpty {
                Text("Collecting readings…").foregroundStyle(.secondary)
            } else {
                Chart(points) { p in
                    LineMark(x: .value("Time", p.date), y: .value("V", p.value), series: .value("Series", p.series))
                        .foregroundStyle(by: .value("Source", p.series))
                        .interpolationMethod(p.series == "Negotiated" ? .stepEnd : .linear)
                }
                .chartForegroundStyleScale(domain: Self.series.map(\.0), range: Self.series.map(\.1))
                .chartYAxisLabel("V")
                .frame(height: 200)
                Text("Last 3 minutes at 1 s resolution, unaveraged. Drops in system input that line up with link events below point to the charger or cable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Voltage sources

struct VoltageSourcesCard: View {
    @Environment(BatteryMonitor.self) private var monitor

    enum Kind: String {
        case measured = "Measured", setpoint = "Setpoint", derived = "Derived"
        var color: Color {
            switch self {
            case .measured: .blue
            case .setpoint: .purple
            case .derived: .gray
            }
        }
    }

    struct Row: Identifiable {
        let name: String
        let value: String
        let kind: Kind
        let source: String
        var id: String { name + "|" + source }
    }

    var body: some View {
        Card(title: "Voltage Sources", symbol: "list.bullet.indent") {
            Text("Each value with where it comes from. Setpoints are what was agreed or requested; only measured values reflect the actual voltage.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Signal"); Text("Value"); Text("Type"); Text("Source")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name)
                        Text(row.value).monospacedDigit().gridColumnAlignment(.trailing)
                        Text(row.kind.rawValue)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .foregroundStyle(row.kind.color)
                            .background(Capsule().fill(row.kind.color.opacity(0.14)))
                        Text(row.source).font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var rows: [Row] {
        let s = monitor.snapshot
        var rows: [Row] = []
        let contract = s.pd.contract
        rows.append(Row(name: "VBUS, negotiated", value: volts(contract?.voltage), kind: .setpoint,
                        source: contract.map { "PDO \($0.pdo.position), selected by the power manager" } ?? "No PD profile in use"))
        rows.append(Row(name: "VBUS, elected by macOS", value: volts(s.pd.electedPD?.voltage), kind: .setpoint,
                        source: "IOPortFeaturePowerSource"))
        rows.append(Row(name: "VBUS, measured", value: s.chargerVBUS.map { volts($0, digits: 3) } ?? "Not reported",
                        kind: .measured, source: "AppleChargerData ChargerVBUS"))
        rows.append(Row(name: "PMU input setpoint", value: volts(s.ipdInputVoltage), kind: .setpoint,
                        source: "PowerDistribution IPDInputVoltage"))
        rows.append(Row(name: "System input (telemetry)", value: Format.number(s.inputVoltageV, digits: 3, unit: "V"), kind: .measured,
                        source: "PowerTelemetryData SystemVoltageIn (internal rail, not VBUS)"))
        rows.append(Row(name: "System input (SMC)", value: Format.number(s.smc.dcInVoltage, digits: 3, unit: "V"), kind: .measured,
                        source: "SMC VD0R"))
        let age = monitor.gaugeAge.map { "updated \(Int($0)) s ago" } ?? ""
        rows.append(Row(name: "Battery pack (gauge)", value: Format.number(s.voltageV, digits: 3, unit: "V"), kind: .measured,
                        source: "Gauge Voltage \(age)"))
        rows.append(Row(name: "Battery pack (SMC)", value: Format.number(s.smc.batteryVoltage, digits: 3, unit: "V"), kind: .measured,
                        source: "SMC B0AV"))
        rows.append(Row(name: "Sum of cell groups", value: Format.number(s.cellSumV, digits: 3, unit: "V"), kind: .derived,
                        source: "\(s.cells.count) × CellVoltage"))
        if let target = s.chargeTargetCellVoltage {
            let pack = s.cells.isEmpty ? "" : " (pack \(Format.number(Double(target * s.cells.count) / 1000, digits: 3, unit: "V")))"
            rows.append(Row(name: "Charge target per cell", value: volts(target, digits: 3) + pack, kind: .setpoint,
                            source: "AppleChargerData ChargingVoltage"))
        }
        return rows
    }
}

// MARK: - Consistency checks

struct ConsistencyChecksCard: View {
    @Environment(BatteryMonitor.self) private var monitor

    struct Check: Identifiable {
        let title: String
        let detail: String
        let status: CheckStatus
        var id: String { title }
    }

    var body: some View {
        Card(title: "Consistency Checks", symbol: "checklist") {
            VStack(spacing: 0) {
                ForEach(checks) { check in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: check.status.symbol).foregroundStyle(check.status.color)
                        Text(check.title)
                        Spacer()
                        Text(check.detail).foregroundStyle(.secondary).monospacedDigit().multilineTextAlignment(.trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var checks: [Check] {
        let s = monitor.snapshot
        var checks: [Check] = []

        func compare(_ title: String, _ a: Double?, _ b: Double?, tolerance: Double, unit: String, scale: Double = 1000) {
            guard let a, let b else {
                checks.append(Check(title: title, detail: "Not available", status: .unavailable)); return
            }
            let diff = abs(a - b)
            checks.append(Check(title: title,
                                detail: "Δ \(Format.number(diff * scale, digits: 0, unit: unit)) (limit \(Format.number(tolerance * scale, digits: 0, unit: unit)))",
                                status: diff <= tolerance ? .match : .mismatch))
        }

        // Pack terminals sit behind sense resistor, fuse and interconnects, so the pack reads
        // differently from the cell sum by roughly I × R. Allow 30 mV plus 35 mΩ × |I|.
        let packTolerance = 0.030 + abs(s.currentA ?? 0) * 0.035
        compare("Gauge pack vs sum of cells", s.voltageV, s.cellSumV, tolerance: packTolerance, unit: "mV")
        // The gauge publishes every few seconds while SMC is live, so only compare fresh gauge data.
        if let age = monitor.gaugeAge, age > 2 {
            checks.append(Check(title: "Gauge pack vs SMC pack",
                                detail: "Skipped: gauge value is \(Int(age)) s old", status: .unavailable))
        } else {
            compare("Gauge pack vs SMC pack", s.voltageV, s.smc.batteryVoltage, tolerance: 0.050, unit: "mV")
        }
        // The two input sources are sampled at slightly different instants; comparing them
        // only makes sense while the input is steady.
        let recent = monitor.live.filter { $0.date >= s.date.addingTimeInterval(-30) }.compactMap(\.systemInput)
        let inputSpread = (recent.max() ?? 0) - (recent.min() ?? 0)
        if inputSpread > 1.0 {
            checks.append(Check(title: "Telemetry input vs SMC input",
                                detail: "Skipped: input not steady", status: .unavailable))
        } else {
            compare("Telemetry input vs SMC input", s.inputVoltageV, s.smc.dcInVoltage, tolerance: 0.300, unit: "mV")
        }

        let elected = s.contractCrossChecks.first { $0.id == "elected" }
        checks.append(Check(title: "Negotiated vs elected source",
                            detail: elected.map { "\(volts($0.voltage)) vs \(volts(s.pd.contract?.voltage))" } ?? "Not available",
                            status: elected?.status ?? .unavailable))

        if let lo = recent.min(), let hi = recent.max(), s.externalConnected {
            checks.append(Check(title: "Input stability, last 30 s",
                                detail: "\(Format.number(lo, digits: 2))–\(Format.number(hi, digits: 2, unit: "V"))",
                                status: hi - lo <= 1.0 ? .match : .mismatch))
        } else {
            checks.append(Check(title: "Input stability, last 30 s", detail: "Not on external power", status: .unavailable))
        }

        let problems = monitor.problemCount(within: 600)
        checks.append(Check(title: "PD link, last 10 min",
                            detail: problems == 0 ? "No reconnects or resets" : "\(problems) reconnects / resets / switches",
                            status: problems == 0 ? .match : .mismatch))

        if let age = monitor.gaugeAge {
            checks.append(Check(title: "Gauge data freshness", detail: "Updated \(Int(age)) s ago",
                                status: age <= 60 ? .match : .mismatch))
        }
        return checks
    }
}

// MARK: - PD link health and timeline

struct PDLinkCard: View {
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        Card(title: "PD Link Health", symbol: "cable.connector") {
            HStack(spacing: 12) {
                MetricTile(title: "Issues, 10 min", value: "\(monitor.problemCount(within: 600))", symbol: "exclamationmark.triangle", tint: .orange)
                MetricTile(title: "Issues, 1 h", value: "\(monitor.problemCount(within: 3600))", symbol: "clock", tint: .orange)
            }
            if s.pd.ports.isEmpty {
                Text("No USB-C port controller data.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Port"); Text("RDO request"); Text("Budget"); Text("Attach"); Text("Hard resets"); Text("Src caps"); Text("Rejects")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                    ForEach(s.pd.ports) { port in
                        GridRow {
                            Text("\(port.index)\(port.index == s.pd.activePort?.index ? " (active)" : "")")
                            Text(port.rdoContract.map { "\(volts($0.voltage)) \(amps($0.current))" } ?? "—")
                            Text(port.maxPower.map { "\($0 / 1000) W" } ?? "—")
                            Text("\(port.counters.attach)")
                            Text("\(port.counters.hardResets)")
                            Text("\(port.counters.sourceCapabilities)")
                            Text("\(port.counters.requestRejects + port.counters.psReadyRejects)")
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
                Text("Counters are cumulative since the port controller last reset. PowerScope logs their changes every second, so reconnects between samples are not missed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Card(title: "PD Timeline", symbol: "list.bullet.rectangle.portrait") {
            if monitor.events.isEmpty {
                Text("No PD events yet.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.events.prefix(40)) { event in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: event.eventKind.symbol)
                                .foregroundStyle(event.eventKind.isProblem ? .orange : .green)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(event.count > 1 ? "\(event.eventKind.title) ×\(event.count)" : event.eventKind.title)
                                    .font(.callout.weight(.medium))
                                Text(event.port >= 0 ? "Port \(event.port) · \(event.detail)" : event.detail)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(timeRange(event)).font(.caption.monospacedDigit())
                                if let v = event.voltage {
                                    Text("\(volts(v)) \(amps(event.current))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 5)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    private func timeRange(_ e: PDEvent) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .standard)
        if e.lastDate.timeIntervalSince(e.firstDate) < 1 { return e.firstDate.formatted(style) }
        return "\(e.firstDate.formatted(style)) – \(e.lastDate.formatted(style))"
    }
}

// MARK: - Decoded PDOs

struct PDProfilesCard: View {
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        if let port = s.pd.activePort, !port.pdos.isEmpty {
            Card(title: "Source Capabilities (PDOs)", symbol: "list.number") {
                VStack(spacing: 0) {
                    ForEach(port.pdos) { pdo in
                        let active = pdo.position == s.pd.contract?.pdo.position
                        HStack {
                            Text("PDO \(pdo.position)").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                            Text(pdo.kind.rawValue).frame(width: 70, alignment: .leading)
                            Text(pdo.voltageText).frame(width: 110, alignment: .leading)
                            Text(pdo.maxCurrent.map { amps($0) } ?? "—").frame(width: 70, alignment: .leading)
                            Text(Format.number(pdo.powerW, digits: 0, unit: "W")).frame(width: 60, alignment: .leading)
                            Text(Format.hex(Int(pdo.raw))).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            Spacer()
                            if active {
                                Label("Negotiated", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        .font(.callout.monospacedDigit())
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.green.opacity(0.1) : .clear))
                    }
                }
                if let flags = port.pdos.first?.flags, !flags.isEmpty {
                    Text("Source flags: " + flags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
