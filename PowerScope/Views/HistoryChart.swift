import Charts
import SwiftUI

enum HistoryRange: String, CaseIterable, Identifiable {
    case halfHour, hour, sixHours, day, week
    var id: Self { self }

    var title: String {
        switch self {
        case .halfHour: "30 min"
        case .hour: "1 h"
        case .sixHours: "6 h"
        case .day: "24 h"
        case .week: "7 days"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .halfHour: 1800
        case .hour: 3600
        case .sixHours: 6 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        }
    }
}

struct MetricSeries {
    let name: String
    let color: Color
    let value: (HistoryPoint) -> Double?
    /// Minimum and maximum inside each stored window, drawn as a range bar.
    var range: ((HistoryPoint) -> (Double, Double)?)? = nil
}

enum HistoryMetric: String, CaseIterable, Identifiable {
    case power, current, voltage, inputVoltage, percent, temperature
    var id: Self { self }

    var title: String {
        switch self {
        case .power: "Power"
        case .current: "Current"
        case .voltage: "Battery Voltage"
        case .inputVoltage: "Input Voltage"
        case .percent: "Charge"
        case .temperature: "Temperature"
        }
    }

    var unit: String {
        switch self {
        case .power: "W"
        case .current: "A"
        case .voltage, .inputVoltage: "V"
        case .percent: "%"
        case .temperature: "°C"
        }
    }

    var digits: Int {
        switch self {
        case .percent: 0
        case .voltage, .inputVoltage, .current: 2
        default: 1
        }
    }

    var series: [MetricSeries] {
        switch self {
        case .power:
            [MetricSeries(name: "Battery power", color: .green, value: { $0.batteryPower }),
             MetricSeries(name: "Input power", color: .blue, value: { $0.inputPower }),
             MetricSeries(name: "System load", color: .orange, value: { $0.systemLoad })]
        case .current:
            [MetricSeries(name: "Battery current", color: .purple, value: { $0.current })]
        case .voltage:
            [MetricSeries(name: "Battery voltage", color: .indigo, value: { $0.voltage },
                          range: { p in p.voltageMin.flatMap { lo in p.voltageMax.map { (lo, $0) } } })]
        case .inputVoltage:
            [MetricSeries(name: "Negotiated", color: .green, value: { $0.contractVoltage }),
             MetricSeries(name: "System input", color: .blue, value: { $0.inputVoltage },
                          range: { p in p.inputVoltageMin.flatMap { lo in p.inputVoltageMax.map { (lo, $0) } } })]
        case .percent:
            [MetricSeries(name: "Charge", color: .green, value: { $0.percent })]
        case .temperature:
            [MetricSeries(name: "Battery temperature", color: .red, value: { $0.temperature })]
        }
    }
}

struct ChartPoint: Identifiable {
    let id: Int
    let date: Date
    let value: Double
    let series: String
    let segment: Int
    var low: Double? = nil
    var high: Double? = nil
}

enum ChartData {
    /// Averages raw samples into at most `maxBuckets` buckets per series and starts a new
    /// line segment wherever the app was not running, so gaps are not drawn as lines.
    static func points(from raw: ArraySlice<HistoryPoint>, metric: HistoryMetric,
                       start: Date, end: Date, maxBuckets: Int = 360) -> [ChartPoint] {
        let span = max(end.timeIntervalSince(start), 1)
        let bucketWidth = max(BatteryMonitor.sampleInterval, span / Double(maxBuckets))
        let gapLimit = max(30, bucketWidth * 2.5)
        let series = metric.series

        var result: [ChartPoint] = []
        var segment = 0
        var previous: Date?
        var bucketKey: Int?
        var dateSum = 0.0, dateCount = 0
        var sums = [Double](repeating: 0, count: series.count)
        var counts = [Int](repeating: 0, count: series.count)
        var lows = [Double?](repeating: nil, count: series.count)
        var highs = [Double?](repeating: nil, count: series.count)

        func flush() {
            guard dateCount > 0 else { return }
            let date = Date(timeIntervalSinceReferenceDate: dateSum / Double(dateCount))
            for (i, s) in series.enumerated() where counts[i] > 0 {
                result.append(ChartPoint(id: result.count, date: date, value: sums[i] / Double(counts[i]),
                                         series: s.name, segment: segment, low: lows[i], high: highs[i]))
            }
            dateSum = 0; dateCount = 0
            sums = [Double](repeating: 0, count: series.count)
            counts = [Int](repeating: 0, count: series.count)
            lows = [Double?](repeating: nil, count: series.count)
            highs = [Double?](repeating: nil, count: series.count)
        }

        for point in raw where point.date <= end {
            if let previous, point.date.timeIntervalSince(previous) > gapLimit {
                flush()
                segment += 1
            }
            previous = point.date
            let key = Int(point.date.timeIntervalSince(start) / bucketWidth)
            if key != bucketKey {
                flush()
                bucketKey = key
            }
            dateSum += point.date.timeIntervalSinceReferenceDate
            dateCount += 1
            for (i, s) in series.enumerated() {
                if let v = s.value(point) { sums[i] += v; counts[i] += 1 }
                if let (lo, hi) = s.range?(point) {
                    lows[i] = Swift.min(lows[i] ?? lo, lo)
                    highs[i] = Swift.max(highs[i] ?? hi, hi)
                }
            }
        }
        flush()
        return result
    }
}

struct HistoryChart: View {
    @Environment(BatteryMonitor.self) private var monitor
    let metric: HistoryMetric
    let range: HistoryRange
    var compact = false

    @State private var selection: Date?

    var body: some View {
        let end = monitor.snapshot.date
        let start = end.addingTimeInterval(-range.seconds)
        let points = ChartData.points(from: monitor.points(since: start), metric: metric, start: start, end: end,
                                      maxBuckets: compact ? 180 : 360)

        if points.isEmpty {
            ContentUnavailableView("No history yet", systemImage: "chart.xyaxis.line",
                                   description: Text("PowerScope stores a reading window every 5 seconds while it runs. Check back shortly."))
        } else {
            Chart {
                ForEach(points.filter { $0.low != nil }) { p in
                    if let low = p.low, let high = p.high {
                        RuleMark(x: .value("Time", p.date), yStart: .value("Min", low), yEnd: .value("Max", high))
                            .foregroundStyle(by: .value("Metric", p.series))
                            .opacity(0.3)
                            .lineStyle(StrokeStyle(lineWidth: compact ? 2 : 3, lineCap: .round))
                    }
                }
                ForEach(points) { p in
                    LineMark(
                        x: .value("Time", p.date),
                        y: .value(metric.unit, p.value),
                        series: .value("Series", "\(p.series)#\(p.segment)")
                    )
                    .foregroundStyle(by: .value("Metric", p.series))
                    .interpolationMethod(p.series == "Negotiated" ? .stepEnd : .monotone)
                    .lineStyle(StrokeStyle(lineWidth: compact ? 1.6 : 2))
                }
                if metric == .power || metric == .current {
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if let selection, let tooltip = tooltip(at: selection, points: points) {
                    RuleMark(x: .value("Selected", tooltip.date))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltipView(tooltip)
                        }
                }
            }
            .chartXScale(domain: start...end)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: compact ? 3 : 6)) {
                    AxisGridLine()
                    AxisValueLabel(format: range == .week
                                   ? .dateTime.month(.defaultDigits).day().hour()
                                   : .dateTime.hour().minute())
                }
            }
            .chartForegroundStyleScale(domain: metric.series.map(\.name), range: metric.series.map(\.color))
            .chartYAxisLabel(metric.unit)
            .chartLegend(metric.series.count > 1 ? .visible : .hidden)
            .chartXSelection(value: $selection)
            .chartYScale(domain: .automatic(includesZero: metric == .power || metric == .current))
        }
    }

    private struct Tooltip {
        let date: Date
        let values: [(String, Double, Color)]
    }

    private func tooltip(at date: Date, points: [ChartPoint]) -> Tooltip? {
        var values: [(String, Double, Color)] = []
        var anchor: Date?
        for s in metric.series {
            let nearest = points.lazy.filter { $0.series == s.name }
                .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
            if let nearest {
                values.append((s.name, nearest.value, s.color))
                anchor = anchor ?? nearest.date
            }
        }
        guard let anchor else { return nil }
        return Tooltip(date: anchor, values: values)
    }

    private func tooltipView(_ t: Tooltip) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(t.date, format: .dateTime.month().day().hour().minute().second())
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(t.values, id: \.0) { name, value, color in
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(name).font(.caption)
                    Spacer(minLength: 8)
                    Text(Format.number(value, digits: metric.digits, unit: metric.unit))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
        }
        .padding(8)
        .frame(minWidth: 140)
        .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}
