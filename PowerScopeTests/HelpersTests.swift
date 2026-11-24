import Foundation
import Testing
@testable import PowerScope

@Suite("History downsampling")
struct ChartDataTests {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func point(_ t: TimeInterval, input: Double, low: Double, high: Double, contract: Double = 20) -> HistoryPoint {
        HistoryPoint(date: start.addingTimeInterval(t), percent: 50, voltage: 11.5, current: 1, batteryPower: 10,
                     inputPower: 40, systemLoad: 30, temperature: 30, isCharging: true, onExternalPower: true,
                     inputVoltage: input, inputVoltageMin: low, inputVoltageMax: high, contractVoltage: contract)
    }

    @Test func bucketKeepsAverageAndExtremes() throws {
        // One hour over 360 buckets = 10 s buckets; both points land in the first one.
        let raw = [point(1, input: 10, low: 5, high: 12), point(3, input: 20, low: 15, high: 25)]
        let points = ChartData.points(from: raw[...], metric: .inputVoltage, start: start,
                                      end: start.addingTimeInterval(3600))
        let input = try #require(points.first { $0.series == "System input" })
        #expect(input.value == 15)
        #expect(input.low == 5)      // min of window minimums, not of the averages
        #expect(input.high == 25)
        #expect(points.first { $0.series == "Negotiated" }?.value == 20)
    }

    @Test func gapStartsNewSegment() {
        let raw = [point(1, input: 10, low: 10, high: 10), point(200, input: 10, low: 10, high: 10)]
        let points = ChartData.points(from: raw[...], metric: .inputVoltage, start: start,
                                      end: start.addingTimeInterval(3600))
        let segments = Set(points.filter { $0.series == "System input" }.map(\.segment))
        #expect(segments == [0, 1])
    }

    @Test func pointsAfterEndAreIgnored() {
        let raw = [point(1, input: 10, low: 10, high: 10), point(4000, input: 99, low: 99, high: 99)]
        let points = ChartData.points(from: raw[...], metric: .inputVoltage, start: start,
                                      end: start.addingTimeInterval(3600))
        #expect(!points.contains { $0.value == 99 })
    }
}

@Suite("Formatting")
struct FormatTests {
    @Test func hexShowsSignExtendedRegistersAs32Bit() {
        #expect(Format.hex(-536_854_518) == "0xE000400A")   // adapter FamilyCode
        #expect(Format.hex(2816) == "0xB00")
        #expect(Format.hex(nil) == "—")
    }

    @Test func minutes() {
        #expect(Format.minutes(45) == "45 min")
        #expect(Format.minutes(120) == "2 h")
        #expect(Format.minutes(189) == "3 h 9 min")
    }
}

@Suite("Battery registry parsing")
struct BatteryParsingTests {
    @Test func manufacturerStrings() {
        // MfgData from this Mac's battery pack.
        let bytes: [UInt8] = [0, 0, 0, 0, 0x0B, 0, 1, 0, 0x17, 0x1D, 0, 0,
                              4, 0x33, 0x35, 0x31, 0x36, 3, 0x30, 0x30, 0x41, 3, 0x41, 0x54, 0x4C,
                              0, 0x0E, 0, 0, 0, 0, 0]
        #expect(BatteryReader.lengthPrefixedStrings(Data(bytes)) == ["3516", "00A", "ATL"])
    }

    @Test func manufactureDateAppleSilicon() {
        // Packed ASCII "306043".
        #expect(BatteryReader.manufactureDate(NSNumber(value: 56_282_160_575_539)) == "306043")
    }

    @Test func manufactureDateIntelBitfield() {
        let value = 15 | (6 << 5) | ((2020 - 1980) << 9)
        #expect(BatteryReader.manufactureDate(NSNumber(value: value)) == "2020-06-15")
    }
}
