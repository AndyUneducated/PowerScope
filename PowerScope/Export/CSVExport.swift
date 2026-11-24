import AppKit
import Foundation
import UniformTypeIdentifiers

/// Builds CSV files from the stored history and PD event log.
enum CSVExport {
    static func history(_ points: [HistoryPoint]) -> String {
        let header = [
            "timestamp", "charge_percent",
            "battery_voltage_v", "battery_voltage_min_v", "battery_voltage_max_v",
            "battery_current_a", "battery_power_w", "input_power_w", "system_load_w",
            "input_voltage_v", "input_voltage_min_v", "input_voltage_max_v",
            "negotiated_voltage_v", "negotiated_current_a",
            "temperature_c", "charging", "external_power",
        ]
        let rows = points.map { p in
            [
                timestamp(p.date), number(p.percent, 0),
                number(p.voltage, 3), number(p.voltageMin, 3), number(p.voltageMax, 3),
                number(p.current, 3), number(p.batteryPower, 2), number(p.inputPower, 2), number(p.systemLoad, 2),
                number(p.inputVoltage, 3), number(p.inputVoltageMin, 3), number(p.inputVoltageMax, 3),
                number(p.contractVoltage, 2), number(p.contractCurrent, 2),
                number(p.temperature, 2), p.isCharging ? "1" : "0", p.onExternalPower ? "1" : "0",
            ]
        }
        return csv(header: header, rows: rows)
    }

    static func events(_ events: [PDEvent]) -> String {
        let header = ["first_seen", "last_seen", "event", "port", "count", "detail", "voltage_v", "current_a"]
        let rows = events.sorted { $0.firstDate < $1.firstDate }.map { e in
            [
                timestamp(e.firstDate), timestamp(e.lastDate), e.eventKind.title,
                e.port >= 0 ? String(e.port) : "", String(e.count), e.detail,
                number(e.voltage.map { Double($0) / 1000 }, 2), number(e.current.map { Double($0) / 1000 }, 2),
            ]
        }
        return csv(header: header, rows: rows)
    }

    // MARK: Formatting

    static func csv(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// RFC 4180: quote fields containing a comma, quote or line break, doubling inner quotes.
    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func number(_ value: Double?, _ digits: Int) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(digits)f", value)
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted))
    }

    // MARK: Saving

    /// Asks where to save, then writes the CSV. Returns false if cancelled or the write failed.
    @discardableResult
    static func save(_ contents: String, suggestedName: String) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    static func fileName(_ kind: String, at date: Date = .now) -> String {
        "PowerScope-\(kind)-\(date.formatted(.iso8601.year().month().day())).csv"
    }
}

extension BatteryMonitor {
    func exportHistory() {
        CSVExport.save(CSVExport.history(history), suggestedName: CSVExport.fileName("history"))
    }

    func exportEvents() {
        CSVExport.save(CSVExport.events(allEvents()), suggestedName: CSVExport.fileName("pd-events"))
    }
}
