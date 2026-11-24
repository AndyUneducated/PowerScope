import Foundation
import SwiftData
import Testing
@testable import PowerScope

@Suite("CSV export")
struct CSVExportTests {
    @Test func escaping() {
        #expect(CSVExport.escape("plain") == "plain")
        #expect(CSVExport.escape("a,b") == "\"a,b\"")
        #expect(CSVExport.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVExport.escape("two\nlines") == "\"two\nlines\"")
    }

    @Test func historyRow() throws {
        let point = HistoryPoint(date: Date(timeIntervalSince1970: 1_795_500_000), percent: 44, voltage: 12.0611,
                                 current: 8.007, batteryPower: 96.6, inputPower: 135.3, systemLoad: 39.3,
                                 temperature: 36.7, isCharging: true, onExternalPower: true,
                                 voltageMin: 12.05, voltageMax: 12.07,
                                 inputVoltage: 27.14, inputVoltageMin: 27.1, inputVoltageMax: 27.2,
                                 contractVoltage: 28, contractCurrent: nil)
        let lines = CSVExport.history([point]).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false)
        let row = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(header.count == row.count)
        let column = Dictionary(uniqueKeysWithValues: zip(header.map(String.init), row.map(String.init)))
        #expect(column["battery_voltage_v"] == "12.061")
        #expect(column["input_voltage_min_v"] == "27.100")
        #expect(column["negotiated_voltage_v"] == "28.00")
        #expect(column["negotiated_current_a"] == "")      // unknown stays empty, not 0
        #expect(column["charging"] == "1")
        #expect(try #require(column["timestamp"]).hasPrefix("2026-"))
    }

    @Test func eventsAreChronologicalAndQuoted() {
        let late = PDEvent(date: Date(timeIntervalSince1970: 2000), kind: .hardReset, port: 0, count: 1,
                           detail: "PD hard reset", voltage: 20000, current: 4700)
        let early = PDEvent(date: Date(timeIntervalSince1970: 1000), kind: .changed, port: 1, count: 1,
                            detail: "20.00 V, PDO 4 → 28.00 V", voltage: 28000, current: nil)
        let lines = CSVExport.events([late, early]).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[1].contains("Contract changed"))
        #expect(lines[1].contains("\"20.00 V, PDO 4 → 28.00 V\""))
        #expect(lines[2].contains("Hard reset"))
        #expect(lines[2].hasSuffix("20.00,4.70"))
    }
}

/// The store as the first release wrote it: PowerSample without the precision fields,
/// and no PDEvent entity.
enum StoreSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [PowerSample.self] }

    @Model
    final class PowerSample {
        var timestamp: Date
        var percent: Double
        var voltage: Double
        var current: Double
        var batteryPower: Double
        var inputPower: Double
        var systemLoad: Double
        var temperature: Double?
        var isCharging: Bool
        var onExternalPower: Bool

        init(timestamp: Date, voltage: Double) {
            self.timestamp = timestamp
            percent = 50
            self.voltage = voltage
            current = 1
            batteryPower = 12
            inputPower = 40
            systemLoad = 28
            temperature = 30
            isCharging = true
            onExternalPower = true
        }
    }
}

@Suite("History store")
struct StoreMigrationTests {
    /// Opening a first-release store with the current models must keep the old rows,
    /// leave the new fields empty, and add the PD event table.
    @Test func firstReleaseStoreOpensWithCurrentModels() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "powerscope-migration-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appending(path: url.lastPathComponent)) }
        let date = Date(timeIntervalSince1970: 1_795_000_000)

        do {
            let old = try ModelContainer(for: Schema(versionedSchema: StoreSchemaV1.self),
                                         configurations: ModelConfiguration(url: url))
            let context = ModelContext(old)
            context.insert(StoreSchemaV1.PowerSample(timestamp: date, voltage: 11.5))
            try context.save()
        }

        let current = try ModelContainer(for: PowerScope.PowerSample.self, PDEvent.self,
                                         configurations: ModelConfiguration(url: url))
        let context = ModelContext(current)
        let samples = try context.fetch(FetchDescriptor<PowerScope.PowerSample>())
        #expect(samples.count == 1)
        #expect(samples.first?.timestamp == date)
        #expect(samples.first?.voltage == 11.5)
        #expect(samples.first?.inputVoltage == nil)
        #expect(samples.first?.contractVoltage == nil)

        context.insert(PDEvent(date: date, kind: .started, port: 0, count: 1, detail: "", voltage: nil, current: nil))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<PDEvent>()) == 1)
    }

    @Test func samplePointRoundTrip() {
        let point = HistoryPoint(date: .now, percent: 80, voltage: 12.2, current: -1.5, batteryPower: -18,
                                 inputPower: 0, systemLoad: 18, temperature: nil, isCharging: false, onExternalPower: false,
                                 voltageMin: 12.1, voltageMax: 12.3, inputVoltage: nil, inputVoltageMin: nil,
                                 inputVoltageMax: nil, contractVoltage: nil, contractCurrent: nil)
        #expect(PowerSample(point: point).point == point)
    }
}
