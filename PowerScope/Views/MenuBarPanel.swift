import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @Environment(BatteryMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                RingGauge(percent: s.percent, tint: s.mode.color, lineWidth: 7, fontSize: 20)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    StatusBadge(mode: s.mode)
                    Text(s.remainingTimeText).font(.callout)
                    if let adapter = s.adapterSummary {
                        Text(adapter).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    stat("Battery power", Format.signed(s.batteryPowerW, digits: 1, unit: "W"))
                    stat("Input power", Format.number(s.inputPowerW, digits: 1, unit: "W"))
                }
                GridRow {
                    stat("Voltage", Format.number(s.voltageV, digits: 3, unit: "V"))
                    stat("Current", Format.signed(s.currentA, digits: 3, unit: "A"))
                }
                GridRow {
                    stat("System load", Format.number(s.systemLoadW, digits: 1, unit: "W"))
                    stat("Temperature", Format.number(s.temperature, digits: 1, unit: "°C"))
                }
                GridRow {
                    stat("Health", Format.percent(s.healthPercent))
                    stat("Cycles", Format.int(s.cycleCount))
                }
                GridRow {
                    stat("PD contract", s.pd.contract.map {
                        "\(Format.number(Double($0.voltage) / 1000, digits: 2, unit: "V")) \(Format.number($0.current.map { Double($0) / 1000 }, digits: 2, unit: "A"))"
                    } ?? "—")
                    stat("PD link issues, 10 min", "\(monitor.problemCount(within: 600))")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Power, last 30 minutes").font(.caption).foregroundStyle(.secondary)
                HistoryChart(metric: .power, range: .halfHour, compact: true)
                    .frame(height: 110)
            }

            Divider()
            HStack {
                Button("Open PowerScope") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
