import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case overview, charging, history, battery, raw
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .charging: "Charging"
        case .history: "History"
        case .battery: "Battery Health"
        case .raw: "Raw Data"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .charging: "bolt.fill"
        case .history: "chart.xyaxis.line"
        case .battery: "heart.text.square"
        case .raw: "list.bullet.rectangle"
        }
    }
}

struct ContentView: View {
    /// `-page charging` on the command line opens a specific page.
    @State private var page: Page? = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .overview
    /// SwiftUI keeps this view alive after the window closes; pages are only built
    /// (and only observe live data) while the window is actually visible.
    @State private var isVisible = true

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            Group {
                if isVisible {
                    switch page ?? .overview {
                    case .overview: OverviewPage()
                    case .charging: ChargingPage()
                    case .history: HistoryPage()
                    case .battery: BatteryPage()
                    case .raw: RawDataPage()
                    }
                } else {
                    Color.clear
                }
            }
            .navigationTitle((page ?? .overview).title)
        }
        .background(WindowVisibilityReader(isVisible: $isVisible))
    }
}

// MARK: - Overview

struct OverviewPage: View {
    @Environment(BatteryMonitor.self) private var monitor
    @State private var metric: HistoryMetric = .power

    private var metricPicker: some View {
        Picker("Metric", selection: $metric) {
            ForEach(HistoryMetric.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
    }

    var body: some View {
        let s = monitor.snapshot
        PageScroll {
            Card {
                HStack(spacing: 24) {
                    RingGauge(percent: s.percent, tint: s.tone.color)
                        .frame(width: 120, height: 120)
                    VStack(alignment: .leading, spacing: 8) {
                        StatusBadge(snapshot: s)
                        Text(s.remainingTimeText)
                            .font(.title3.weight(.medium))
                        if let adapter = s.adapterSummary {
                            Label(adapter, systemImage: "powerplug")
                                .foregroundStyle(.secondary)
                        }
                        Text("Fast charging = battery charge power ≥ \(Int(BatterySnapshot.fastChargeWatts)) W")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(Format.signed(s.batteryPowerW, digits: 1))
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(s.tone.foreground)
                            .contentTransition(.numericText())
                        Text("Battery power, W (+ in / − out)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                MetricTile(title: "Battery voltage", value: Format.number(s.voltageV, digits: 3), unit: "V",
                           symbol: "bolt.horizontal")
                MetricTile(title: "Battery current", value: Format.signed(s.currentA, digits: 3), unit: "A",
                           symbol: "arrow.left.arrow.right")
                MetricTile(title: "Input power", value: Format.number(s.inputPowerW, digits: 1), unit: "W",
                           symbol: "powerplug",
                           footnote: s.inputVoltageV.map { "\(Format.number($0, digits: 2)) V · \(Format.number(s.inputCurrentA, digits: 2)) A" })
                MetricTile(title: "System load", value: Format.number(s.systemLoadW, digits: 1), unit: "W",
                           symbol: "cpu")
                MetricTile(title: "Battery temperature", value: Format.number(s.temperature, digits: 1), unit: "°C",
                           symbol: "thermometer.medium", level: .temperature(s.temperature))
                MetricTile(title: "Health", value: Format.number(s.healthPercent, digits: 1), unit: "%",
                           symbol: "heart", level: .health(s.healthPercent),
                           footnote: "Status: \(s.healthStatusText)")
                MetricTile(title: "Cycle count", value: Format.int(s.cycleCount), unit: "cycles",
                           symbol: "arrow.triangle.2.circlepath", level: .cycles(s.cycleCount, design: s.designCycleCount),
                           footnote: s.designCycleCount.map { "Rated for \($0) cycles" })
                MetricTile(title: "Remaining", value: Format.int(s.remainingCapacity), unit: "mAh",
                           symbol: "battery.75percent",
                           footnote: s.fullChargeCapacity.map { "Full charge \($0) mAh" })
            }

            Card(title: "Last Hour", symbol: "chart.xyaxis.line") {
                // Segmented when there is room; a menu when the window is too narrow.
                ViewThatFits(in: .horizontal) {
                    metricPicker.pickerStyle(.segmented).fixedSize()
                    metricPicker.pickerStyle(.menu).fixedSize()
                }
                HistoryChart(metric: metric, range: .hour)
                    .frame(height: 230)
            }
        }
    }
}

// MARK: - History

struct HistoryPage: View {
    @Environment(BatteryMonitor.self) private var monitor
    @State private var range: HistoryRange = .hour

    var body: some View {
        PageScroll {
            HStack {
                Picker("Time range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
                Text("Read every 1 s · stored per 5 s (avg, min, max) · kept 7 days · \(monitor.history.count) windows")
                    .font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("History…") { monitor.exportHistory() }
                    Button("PD events…") { monitor.exportEvents() }
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
            }
            ForEach(HistoryMetric.allCases) { metric in
                Card(title: metric.title + " (\(metric.unit))", symbol: symbol(metric)) {
                    HistoryChart(metric: metric, range: range)
                        .frame(height: metric == .power || metric == .inputVoltage ? 240 : 170)
                }
            }
            Text("Shaded bars show the minimum–maximum range inside each window; lines are averages.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Database: \(BatteryMonitor.storeURL.path(percentEncoded: false))")
                .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
        }
    }

    private func symbol(_ m: HistoryMetric) -> String {
        switch m {
        case .power: "bolt"
        case .current: "arrow.left.arrow.right"
        case .voltage: "bolt.horizontal"
        case .inputVoltage: "powerplug"
        case .percent: "battery.75percent"
        case .temperature: "thermometer.medium"
        }
    }
}

// MARK: - Battery

struct BatteryPage: View {
    @Environment(BatteryMonitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        PageScroll {
            Card(title: "Health", symbol: "heart.fill") {
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Format.percent(s.healthPercent))
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("Full charge ÷ design capacity").font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min((s.healthPercent ?? 0) / 100, 1))
                            .tint(ReadingLevel.health(s.healthPercent).tone.color)
                        HStack {
                            Text("Status: \(s.healthStatusText)")
                            if let c = s.healthCondition { Text("· \(c)") }
                            Spacer()
                            Text("Nominal health \(Format.percent(s.nominalHealthPercent))")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                InfoGrid(rows: [
                    ("Design capacity", Format.int(s.designCapacity, unit: "mAh")),
                    ("Full charge capacity (FCC)", Format.int(s.fullChargeCapacity, unit: "mAh")),
                    ("Nominal charge capacity (NCC)", Format.int(s.nominalChargeCapacity, unit: "mAh")),
                    ("Remaining capacity", Format.int(s.remainingCapacity, unit: "mAh")),
                    ("Cycle count", Format.int(s.cycleCount)),
                    ("Design cycle count", Format.int(s.designCycleCount)),
                    ("Lowest charge today", Format.int(s.dailyMinSoc, unit: "%")),
                    ("Highest charge today", Format.int(s.dailyMaxSoc, unit: "%")),
                ])
            }

            HStack(alignment: .top, spacing: 16) {
                Card(title: "Temperature", symbol: "thermometer.medium") {
                    VStack(spacing: 0) {
                        InfoRow(label: "Current", value: Format.number(s.temperature, digits: 2, unit: "°C"))
                        InfoRow(label: "Virtual", value: Format.number(s.virtualTemperature, digits: 2, unit: "°C"))
                        InfoRow(label: "Lifetime max", value: Format.int(s.lifetime?.maxTemperature, unit: "°C"))
                        InfoRow(label: "Lifetime min", value: Format.int(s.lifetime?.minTemperature, unit: "°C"))
                        InfoRow(label: "Lifetime average", value: Format.number(s.lifetime?.averageTemperature, digits: 1, unit: "°C"))
                    }
                }
                Card(title: "Cells", symbol: "square.stack.3d.up") {
                    VStack(spacing: 0) {
                        ForEach(s.cells) { cell in
                            InfoRow(label: "Cell group \(cell.id + 1)",
                                    value: "\(Format.number(cell.voltage.map { Double($0) / 1000 }, digits: 3, unit: "V"))"
                                        + (cell.qmax.map { " · Qmax \($0) mAh" } ?? ""))
                        }
                        let volts = s.cells.compactMap(\.voltage)
                        if let lo = volts.min(), let hi = volts.max() {
                            InfoRow(label: "Voltage spread", value: "\(hi - lo) mV",
                                    valueColor: hi - lo > 50 ? Tone.attention.color : .primary)
                        }
                        if s.cells.isEmpty {
                            Text("No cell data available").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Card(title: "Battery Info", symbol: "info.circle") {
                InfoGrid(rows: [
                    ("Serial number", s.serial ?? "—"),
                    ("Gauge chip", s.deviceName ?? "—"),
                    ("Cell vendor", s.mfgStrings.last ?? "—"),
                    ("Manufacturer data", s.mfgStrings.isEmpty ? "—" : s.mfgStrings.joined(separator: " / ")),
                    ("Manufacture date code", s.manufactureCode ?? "—"),
                    ("Chemistry ID", Format.int(s.chemID)),
                    ("Gauge firmware", Format.hex(s.gaugeFirmware)),
                    ("Total operating time", Format.int(s.lifetime?.operatingTime, unit: "h")),
                    ("Lifetime max charge current", Format.number(s.lifetime?.maxChargeCurrent.map { Double($0) / 1000 }, digits: 2, unit: "A")),
                    ("Lifetime max discharge current", Format.number(s.lifetime?.maxDischargeCurrent.map { Double(abs($0)) / 1000 }, digits: 2, unit: "A")),
                    ("Lifetime max pack voltage", Format.number(s.lifetime?.maxPackVoltage.map { Double($0) / 1000 }, digits: 3, unit: "V")),
                    ("Lifetime min pack voltage", Format.number(s.lifetime?.minPackVoltage.map { Double($0) / 1000 }, digits: 3, unit: "V")),
                ])
            }
        }
    }
}

// MARK: - Raw data

struct RawRow: Identifiable {
    let key: String
    let value: String
    var id: String { key }
}

struct RawDataPage: View {
    @Environment(BatteryMonitor.self) private var monitor
    @State private var query = ""

    var body: some View {
        let rows = monitor.snapshot.raw
            .filter { query.isEmpty || $0.key.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) }
            .map { RawRow(key: $0.key, value: $0.value) }
        Table(rows) {
            TableColumn("Key (IOKit AppleSmartBattery)") { Text($0.key).textSelection(.enabled) }
                .width(min: 220, ideal: 340)
            TableColumn("Value") { Text($0.value).monospacedDigit().textSelection(.enabled) }
        }
        .searchable(text: $query, prompt: "Search keys or values")
        .onAppear { monitor.includeRawData = true }
        .onDisappear { monitor.includeRawData = false }
    }
}
