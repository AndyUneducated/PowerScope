import SwiftUI

// The Charging page, ordered by how often each part is looked at: what is happening now,
// live voltages and link health first; charger details, checks and raw codes collapsed.

struct ChargingPage: View {
    var body: some View {
        PageScroll {
            NowCard()
            LiveVoltageChart()
            PDLinkCard()
            ChargerCard()
            CrossCheckCard()
            ConsistencyChecksCard()
            PortsCard()
            VoltageSourcesCard()
            ChargeDetailsCard()
        }
    }
}

// MARK: - Now

/// A large number with its label and one line of context; the Now card's main readings.
struct HeroValue: View {
    let title: String
    let value: String
    var unit: String = ""
    var caption: String?
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                if !unit.isEmpty {
                    Text(unit).font(.title3).foregroundStyle(.secondary)
                }
            }
            Text(caption ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NowCard: View {
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                StatusBadge(snapshot: s)
                Text("\(s.percent) % · \(s.externalConnected ? "on adapter" : "on battery")")
                    .foregroundStyle(.secondary)
                Spacer()
                linkStatus(s)
            }

            HStack(alignment: .top, spacing: 16) {
                if s.externalConnected {
                    HeroValue(title: "Charger delivers", value: Format.number(s.inputPowerW, digits: 1), unit: "W",
                              caption: s.inputVoltageV.map { "\(Format.number($0, digits: 2)) V · \(Format.number(s.inputCurrentA, digits: 2)) A" },
                              color: Palette.input)
                    contractHero(s)
                } else {
                    HeroValue(title: "Time remaining", value: s.timeToEmpty.map(Format.minutes) ?? "—",
                              caption: "at the current load")
                    HeroValue(title: "System load", value: Format.number(s.systemLoadW, digits: 1), unit: "W",
                              caption: "drawn from the battery", color: Palette.system)
                }
                batteryHero(s)
            }

            if let budget = PowerBudget(s) {
                PowerBudgetBar(budget: budget)
            }

            detailLine(s)

            if s.pd.contract?.rdo?.capabilityMismatch == true {
                Label("Capability mismatch: the Mac wants more power than this charger offers.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Tone.attention.color)
            }
        }
    }

    private func contractHero(_ s: BatterySnapshot) -> some View {
        guard let c = s.pd.contract else {
            return HeroValue(title: "Negotiated", value: "—", caption: "No USB PD contract")
        }
        let current = c.displayCurrent.map { (c.current == nil ? "≤ " : "") + Format.number(Double($0) / 1000, digits: 2) + " A" }
        return HeroValue(title: "Negotiated",
                         value: Format.number(Double(c.voltage) / 1000, digits: c.voltage % 1000 == 0 ? 0 : 2), unit: "V",
                         caption: [current, c.powerW.map { "contract up to " + PowerBudgetBar.w($0) }]
                            .compactMap { $0 }.joined(separator: " · "))
    }

    private func batteryHero(_ s: BatterySnapshot) -> some View {
        let watts = s.batteryPowerW ?? 0
        let caption: String
        switch s.mode {
        case .veryFastCharging, .fastCharging, .charging, .slowCharging:
            caption = s.timeToFull.map { "\(Format.minutes($0)) until full" } ?? "charging"
        case .full: caption = "idle · full"
        case .pluggedNotCharging: caption = "idle · charging paused"
        case .supplementing: caption = "helping the charger"
        case .onBattery: caption = "discharging"
        case .noBattery: caption = "no battery"
        }
        return HeroValue(title: "Battery", value: Format.signed(watts, digits: 1), unit: "W", caption: caption,
                         color: s.stateColor ?? .primary)
    }

    private func detailLine(_ s: BatterySnapshot) -> some View {
        var items = ["Battery \(Format.number(s.voltageV, digits: 2, unit: "V")) · \(Format.signed(s.currentA, digits: 2, unit: "A"))"]
        // System load is already in the budget bar's legend when on external power.
        if !s.externalConnected || PowerBudget(s) == nil {
            items.append("System load \(Format.number(s.systemLoadW, digits: 1, unit: "W"))")
        }
        if let loss = s.adapterLossW, loss > 0.05 { items.append("Conversion loss \(Format.number(loss, digits: 1, unit: "W"))") }
        if let t = s.temperature { items.append("Temperature \(Format.number(t, digits: 1, unit: "°C"))") }
        return HStack(spacing: 18) {
            ForEach(items, id: \.self) { Text($0) }
            Spacer(minLength: 0)
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func linkStatus(_ s: BatterySnapshot) -> some View {
        let issues = monitor.problemCount(within: 600)
        if !s.externalConnected {
            EmptyView()
        } else if issues > 0 {
            Label("\(issues) PD link issues in 10 min", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(Tone.attention.color)
        } else if s.pd.contract != nil {
            Label("PD link stable", systemImage: "checkmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - PD link

struct PDLinkCard: View {
    @Environment(BatteryMonitor.self) private var monitor
    @State private var showsAll = false
    @State private var confirmingClear = false
    @AppStorage("section.pdCounters.expanded") private var countersExpanded = false

    var body: some View {
        let recent = monitor.problemCount(within: 600)
        CollapsibleCard(id: "pdLink", title: "PD Link", symbol: "cable.connector",
                        summary: recent > 0 ? "\(recent) issues in 10 min" : "No issues in 10 min",
                        summaryTone: recent > 0 ? .attention : .neutral, expandedByDefault: true) {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        let s = monitor.snapshot
        let recent = monitor.problemCount(within: 600)
        let hour = monitor.problemCount(within: 3600)
        let total = monitor.events.filter(\.eventKind.isProblem).reduce(0) { $0 + $1.count }

        HStack(spacing: 12) {
            MetricTile(title: "Issues, 10 min", value: "\(recent)", symbol: "exclamationmark.triangle",
                       level: recent > 0 ? .attention : .normal)
            MetricTile(title: "Issues, 1 h", value: "\(hour)", symbol: "clock",
                       level: hour > 0 ? .attention : .normal)
            MetricTile(title: monitor.issuesClearedAt == nil ? "Issues, 7 days" : "Issues since clear",
                       value: "\(total)", symbol: "sum",
                       footnote: monitor.issuesClearedAt.map { "Cleared \($0.formatted(date: .abbreviated, time: .shortened))" })
        }

        if monitor.events.isEmpty {
            Text("No PD events yet.").foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                // The short list skips "Monitoring started" markers; Show all includes them.
                ForEach(Array((showsAll ? monitor.events : monitor.events.filter { $0.eventKind != .started }).prefix(showsAll ? 200 : 5))) { event in
                    eventRow(event)
                    Divider().opacity(0.5)
                }
            }
        }

        HStack {
            if monitor.events.count > 5 {
                Button(showsAll ? "Show less" : "Show all (\(monitor.events.count))") {
                    withAnimation(.snappy(duration: 0.2)) { showsAll.toggle() }
                }
            }
            Spacer()
            Button("Clear…", role: .destructive) { confirmingClear = true }
                .disabled(monitor.events.isEmpty && s.pd.ports.allSatisfy { monitor.countersSinceClear($0).problems == 0 })
        }
        .confirmationDialog("Clear PD issues?", isPresented: $confirmingClear) {
            Button("Clear issues and timeline", role: .destructive) { monitor.clearIssues() }
        } message: {
            Text("Deletes \(monitor.events.count) timeline events and restarts the issue counts and controller counters from now. History charts and the chip's own totals are kept.")
        }

        DisclosureGroup(isExpanded: $countersExpanded) {
            counters(s)
        } label: {
            Text("Controller counters").font(.subheadline.weight(.semibold))
        }
    }

    private func eventRow(_ event: PDEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.eventKind.symbol)
                .foregroundStyle(event.eventKind.isProblem ? Tone.attention.color : Color.secondary)
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
    }

    @ViewBuilder
    private func counters(_ s: BatterySnapshot) -> some View {
        if s.pd.ports.isEmpty {
            Text("No USB PD port controller data.").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Text("Controller"); Text("Re-attaches"); Text("Hard resets"); Text("Src caps"); Text("Rejects")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(s.pd.ports) { port in
                    let since = monitor.countersSinceClear(port)
                    let total = port.counters
                    GridRow {
                        Text("\(port.index)\(port.index == s.pd.activePort?.index && s.pd.contract != nil ? " (active)" : port.isConnected == false ? " (not connected)" : "")")
                        counterCell(since.attach, total.attach)
                        counterCell(since.hardResets, total.hardResets)
                        counterCell(since.sourceCapabilities, total.sourceCapabilities)
                        counterCell(since.requestRejects + since.psReadyRejects, total.requestRejects + total.psReadyRejects)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            .padding(.top, 6)
            Text("Counts since the last clear; the chip's own totals, which cannot be reset, are in brackets. PowerScope compares them every second, so reconnects between samples are not missed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func counterCell(_ since: Int, _ total: Int) -> some View {
        HStack(spacing: 4) {
            Text("\(since)").foregroundStyle(since > 0 ? Tone.attention.color : Color.primary)
            Text("(\(total))").foregroundStyle(.tertiary)
        }
    }

    private func timeRange(_ e: PDEvent) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .standard)
        if e.lastDate.timeIntervalSince(e.firstDate) < 1 { return e.firstDate.formatted(style) }
        return "\(e.firstDate.formatted(style)) – \(e.lastDate.formatted(style))"
    }
}

// MARK: - Charger

struct ChargerCard: View {
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        CollapsibleCard(id: "charger", title: "Charger", symbol: "powerplug.fill", summary: summary(s)) {
            if let a = s.adapter {
                InfoGrid(rows: adapterRows(a))
            } else {
                Text(s.externalConnected ? "Plugged in, but no charger details available" : "Not connected to power")
                    .foregroundStyle(.secondary)
            }
            if let port = s.pd.activePort, port.isConnected != false, !port.pdos.isEmpty {
                Text("Source capabilities (PDOs)").font(.subheadline.weight(.semibold)).padding(.top, 4)
                pdoList(port, contract: s.pd.contract)
            }
        }
    }

    private func summary(_ s: BatterySnapshot) -> String {
        guard let a = s.adapter else { return s.externalConnected ? "Connected" : "Not connected" }
        var parts = [a.watts.map { "\($0) W" } ?? "", a.typeText].filter { !$0.isEmpty }
        if let c = s.pd.contract { parts.append("PDO \(c.pdo.position) in use") }
        return parts.joined(separator: " · ")
    }

    private func pdoList(_ port: PDPortState, contract: PDContract?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(port.pdos) { pdo in
                let active = pdo.position == contract?.pdo.position
                HStack {
                    Text("PDO \(pdo.position)").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                    Text(pdo.kind.rawValue).frame(width: 70, alignment: .leading)
                    Text(pdo.voltageText).frame(width: 110, alignment: .leading)
                    Text(pdo.maxCurrent.map { amps($0) } ?? "—").frame(width: 70, alignment: .leading)
                    Text(Format.number(pdo.powerW, digits: 0, unit: "W")).frame(width: 60, alignment: .leading)
                    Spacer()
                    if active {
                        Label("Negotiated", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.input)
                    }
                }
                .font(.callout.monospacedDigit())
                .padding(.vertical, 6).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Palette.input.opacity(0.12) : .clear))
            }
            if let flags = port.pdos.first?.flags, !flags.isEmpty {
                Text("Source flags: " + flags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func adapterRows(_ a: AdapterInfo) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Type", a.typeText),
            ("Rated power", Format.int(a.watts, unit: "W")),
            ("Rated voltage", Format.number(a.voltage.map { Double($0) / 1000 }, digits: 2, unit: "V")),
            ("Rated current", Format.number(a.current.map { Double($0) / 1000 }, digits: 2, unit: "A")),
            ("USB Power Delivery", a.isUSBPD ? "Yes" : "No"),
            ("Wireless", a.isWireless.map { $0 ? "Yes" : "No" } ?? "—"),
        ]
        if let n = a.name { rows.append(("Name", n)) }
        if let m = a.manufacturer { rows.append(("Manufacturer", m)) }
        if let m = a.model { rows.append(("Model", m)) }
        if let sn = a.serial { rows.append(("Serial number", sn)) }
        if let fw = a.firmware { rows.append(("Firmware", fw)) }
        if let hw = a.hardware { rows.append(("Hardware", hw)) }
        return rows
    }
}

// MARK: - Cross-check

struct CrossCheckCard: View {
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let checks = s.contractCrossChecks
        let compared = checks.filter { $0.status != .unavailable }
        let mismatches = compared.filter { $0.status == .mismatch }.count
        CollapsibleCard(id: "crossCheck", title: "Contract Cross-check", symbol: "checkmark.seal",
                        summary: s.pd.contract == nil ? "No contract"
                            : mismatches > 0 ? "\(mismatches) of \(compared.count) disagree"
                            : "\(compared.count) of \(compared.count) agree",
                        summaryTone: mismatches > 0 ? .attention : .neutral) {
            Text("Every place macOS reports the contract, compared with the one in use.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(checks) { check in
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
}

// MARK: - Charge control and raw codes

struct ChargeDetailsCard: View {
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        CollapsibleCard(id: "chargeDetails", title: "Charge Control and Raw Codes", symbol: "slider.horizontal.3",
                        summary: s.optimizedCharging == true ? "Optimized charging active" : nil) {
            InfoGrid(rows: [
                ("Optimized charging", s.optimizedCharging.map { $0 ? "Active" : "Inactive" } ?? "—"),
                ("Low Power Mode", s.lowPowerMode.map { $0 ? "On" : "Off" } ?? "—"),
                ("External power", s.externalConnected ? "Yes" : "No"),
                ("Charging flag", s.isCharging ? "Yes" : "No"),
                ("Fully charged", s.fullyCharged ? "Yes" : "No"),
                ("Critical level", s.atCritical ? "Yes" : "No"),
                ("Not-charging reason", Format.hex(s.notChargingReason)),
                ("Slow-charging reason", Format.hex(s.slowChargingReason)),
                ("Thermally limited time", Format.int(s.thermallyLimitedTime, unit: "s")),
                ("Battery current (SMC, live)", Format.signed(s.smc.batteryCurrent, digits: 3, unit: "A")),
                ("Battery current (gauge)", Format.signed(s.gaugeCurrentA, digits: 3, unit: "A")),
                ("Instant current (gauge)", Format.signed(s.instantAmperage.map { Double($0) / 1000 }, digits: 3, unit: "A")),
                ("SMC input power (PDTR)", Format.number(s.smc.dcInPower, digits: 2, unit: "W")),
                ("Estimated wall power", Format.number(s.telemetry.wallEnergyEstimate.map { Double($0) / 1000 }, digits: 2, unit: "W")),
                ("Adapter Family Code", Format.hex(s.adapter?.familyCode)),
                ("Adapter power tier", Format.int(s.adapter?.powerTier)),
            ])
            if let c = s.pd.contract, let port = s.pd.activePort {
                Divider()
                Text(contractBasis(c, port: port))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private func contractBasis(_ c: PDContract, port: PDPortState) -> String {
        let pdo = "Contract: PDO \(c.pdo.position) (\(c.pdo.kind.rawValue), \(Format.hex(Int(c.pdo.raw)))) on port controller \(port.index)"
        switch c.basis {
        case .confirmed:
            return "\(pdo), selected by the power manager and confirmed by the RDO \(Format.hex(Int(port.rawRDO)))."
        case .powerManager:
            return "\(pdo), selected by the power manager. The RDO \(Format.hex(Int(port.rawRDO))) was not refreshed for this contract, so the operating current is unknown and the PDO limit is shown."
        case .pmuSetpoint:
            return "\(pdo), matched to the PMU input setpoint; the power manager published no selection."
        case .rdoOnly:
            return "\(pdo), decoded from the RDO \(Format.hex(Int(port.rawRDO))); nothing else confirms it."
        }
    }
}
