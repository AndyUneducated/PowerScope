import Foundation
import IOKit
import Observation
import SwiftData

/// A 1 Hz reading kept in memory for the live charts and stability checks.
struct LiveReading: Identifiable {
    let date: Date
    let systemInput: Double?     // V, power telemetry SystemVoltageIn
    let smcInput: Double?        // V, SMC VD0R
    let contract: Double?        // V, negotiated PD voltage
    let pack: Double?            // V, gauge pack voltage
    let smcPack: Double?         // V, SMC B0AV
    var id: Date { date }
}

/// Polls the battery every second (and immediately on IOKit battery notifications),
/// keeps the latest snapshot for the UI, records 5-second history windows and logs PD events.
@Observable
final class BatteryMonitor {
    static let refreshInterval: Duration = .seconds(1)
    static let sampleInterval: TimeInterval = 5
    static let retention: TimeInterval = 7 * 24 * 3600
    static let liveWindow: TimeInterval = 180

    private(set) var snapshot: BatterySnapshot
    private(set) var history: [HistoryPoint] = []
    private(set) var live: [LiveReading] = []
    private(set) var events: [PDEvent] = []
    /// Chip counter values when issues were last cleared, per port controller index.
    private(set) var counterBaseline: [Int: PDCounters] = [:]
    private(set) var issuesClearedAt: Date?

    @ObservationIgnored private let container: ModelContainer?
    @ObservationIgnored private var window: [BatterySnapshot] = []
    @ObservationIgnored private var windowStart = Date.now
    @ObservationIgnored private var lastPruneDate = Date.distantPast
    @ObservationIgnored private var lastReadDate = Date.distantPast
    @ObservationIgnored private var previousTracking = PDTrackingState()
    @ObservationIgnored private var trackingStarted = false
    @ObservationIgnored private var notificationPort: IONotificationPortRef?
    @ObservationIgnored private var interestNotifier: io_object_t = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Set while the Raw Data page is open; building that list every second is wasted otherwise.
    @ObservationIgnored var includeRawData = false {
        didSet { if includeRawData { lastReadDate = .distantPast; tick() } }
    }

    init() {
        container = Self.makeContainer()
        snapshot = BatteryReader.read()
        loadHistory()
        loadEvents()
        loadIssueBaseline()
        subscribeToBatteryNotifications()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// Path of the history database, shown in the UI.
    static var storeURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "PowerScope", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "history.store")
    }

    private static func makeContainer() -> ModelContainer? {
        let config = ModelConfiguration(url: storeURL)
        return try? ModelContainer(for: PowerSample.self, PDEvent.self, configurations: config)
    }

    // MARK: Sampling

    /// Called by the 1 s timer and by battery notifications; reads at most every 0.3 s.
    func tick() {
        let now = Date.now
        guard now.timeIntervalSince(lastReadDate) >= 0.3 else { return }
        lastReadDate = now
        snapshot = BatteryReader.read(now: now, includeRaw: includeRawData)
        appendLive(snapshot)
        trackPowerDelivery(snapshot)

        guard snapshot.hasBattery else { return }
        window.append(snapshot)
        if now.timeIntervalSince(windowStart) >= Self.sampleInterval - 0.25 {
            flushWindow(endingAt: now)
        }
        if now.timeIntervalSince(lastPruneDate) > 3600 { prune(now: now) }
    }

    /// Seconds since the battery gauge last published new values (`UpdateTime` is a Unix timestamp).
    var gaugeAge: TimeInterval? {
        snapshot.gaugeUpdateTime.map { max(0, snapshot.date.timeIntervalSince1970 - Double($0)) }
    }

    private func appendLive(_ s: BatterySnapshot) {
        live.append(LiveReading(date: s.date, systemInput: s.inputVoltageV, smcInput: s.smc.dcInVoltage,
                                contract: s.pd.contract.map { Double($0.voltage) / 1000 },
                                pack: s.voltageV, smcPack: s.smc.batteryVoltage))
        let cutoff = s.date.addingTimeInterval(-Self.liveWindow)
        if let first = live.first, first.date < cutoff { live.removeAll { $0.date < cutoff } }
    }

    private func flushWindow(endingAt end: Date) {
        defer { window.removeAll(); windowStart = end }
        guard let last = window.last else { return }

        func stats(_ values: [Double]) -> (avg: Double, min: Double, max: Double)? {
            guard let lo = values.min(), let hi = values.max() else { return nil }
            return (values.reduce(0, +) / Double(values.count), lo, hi)
        }
        // SMC B0AV updates every second; the gauge's Voltage only every few seconds, so
        // prefer SMC to catch real sags under load.
        let volts = stats(window.compactMap { $0.smc.batteryVoltage ?? $0.voltageV })
        let input = stats(window.compactMap(\.inputVoltageV))
        let avg = { (key: (BatterySnapshot) -> Double?) in stats(self.window.compactMap(key))?.avg }

        let point = HistoryPoint(
            date: end,
            percent: Double(last.percent),
            voltage: volts?.avg ?? 0,
            current: avg(\.currentA) ?? 0,
            batteryPower: avg(\.batteryPowerW) ?? 0,
            inputPower: avg(\.inputPowerW) ?? 0,
            systemLoad: avg(\.systemLoadW) ?? 0,
            temperature: last.temperature,
            isCharging: last.isCharging,
            onExternalPower: last.externalConnected,
            voltageMin: volts?.min, voltageMax: volts?.max,
            inputVoltage: input?.avg, inputVoltageMin: input?.min, inputVoltageMax: input?.max,
            contractVoltage: last.pd.contract.map { Double($0.voltage) / 1000 },
            contractCurrent: last.pd.contract?.current.map { Double($0) / 1000 }
        )
        history.append(point)
        guard let context = container?.mainContext else { return }
        context.insert(PowerSample(point: point))
        try? context.save()
    }

    // MARK: Power Delivery tracking

    private func trackPowerDelivery(_ s: BatterySnapshot) {
        let current = PDTrackingState(s.pd)
        defer { previousTracking = current }
        guard trackingStarted else {
            trackingStarted = true
            record(PDEventDetector.started(s.pd), at: s.date)
            return
        }
        for event in PDEventDetector.detect(previous: previousTracking, current: current,
                                            activePort: s.pd.activePort?.index ?? -1) {
            record(event, at: s.date)
        }
    }

    /// Folds repeats of the same kind on the same port within the fold window into the latest event.
    private func record(_ event: DetectedPDEvent, at date: Date) {
        if let latest = events.first(where: { $0.kind == event.kind.rawValue && $0.port == event.port }),
           PDEventDetector.shouldFold(event, at: date, intoKind: latest.kind, port: latest.port, lastDate: latest.lastDate) {
            latest.count += event.count
            latest.lastDate = date
            latest.detail = event.detail
            latest.voltage = event.voltage
            latest.current = event.current
            events.sort { $0.lastDate > $1.lastDate }
        } else {
            let model = PDEvent(date: date, kind: event.kind, port: event.port, count: event.count,
                                detail: event.detail, voltage: event.voltage, current: event.current)
            events.insert(model, at: 0)
            container?.mainContext.insert(model)
            if events.count > 300 { events.removeLast(events.count - 300) }
        }
        try? container?.mainContext.save()
    }

    // MARK: Clearing issues

    private static let baselineKey = "pd.counterBaseline.v1"
    private static let clearedAtKey = "pd.issuesClearedAt"

    /// Deletes the PD timeline and resets the issue counts. The chip's own counters cannot be
    /// reset, so their current values become the baseline the app counts from.
    func clearIssues() {
        let now = Date.now
        if let context = container?.mainContext {
            try? context.delete(model: PDEvent.self)
            try? context.save()
        }
        events.removeAll()
        counterBaseline = Dictionary(uniqueKeysWithValues: snapshot.pd.ports.map { ($0.index, $0.counters) })
        issuesClearedAt = now
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: counterBaseline.map { (String($0.key), $0.value) })) {
            UserDefaults.standard.set(data, forKey: Self.baselineKey)
        }
        UserDefaults.standard.set(now, forKey: Self.clearedAtKey)
        record(DetectedPDEvent(kind: .cleared, port: -1, count: 1, detail: "Timeline and issue counts reset",
                               voltage: snapshot.pd.contract?.voltage, current: snapshot.pd.contract?.current), at: now)
    }

    /// A controller's counters since the last clear.
    func countersSinceClear(_ port: PDPortState) -> PDCounters {
        port.counters.since(counterBaseline[port.index])
    }

    private func loadIssueBaseline() {
        issuesClearedAt = UserDefaults.standard.object(forKey: Self.clearedAtKey) as? Date
        guard let data = UserDefaults.standard.data(forKey: Self.baselineKey),
              let stored = try? JSONDecoder().decode([String: PDCounters].self, from: data) else { return }
        counterBaseline = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    /// Total count of link problems (reconnects, resets, rejects, source switches) in the given window.
    func problemCount(within seconds: TimeInterval) -> Int {
        let cutoff = snapshot.date.addingTimeInterval(-seconds)
        return events.filter { $0.eventKind.isProblem && $0.lastDate >= cutoff }.reduce(0) { $0 + $1.count }
    }

    // MARK: Notifications

    /// The battery driver posts general-interest messages when it publishes new data;
    /// reading on those messages catches changes between timer ticks.
    private func subscribeToBatteryNotifications() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { IONotificationPortDestroy(port); return }
        defer { IOObjectRelease(service) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if IOServiceAddInterestNotification(port, service, "IOGeneralInterest", batteryInterestCallback,
                                            refcon, &interestNotifier) == KERN_SUCCESS {
            notificationPort = port
        } else {
            IONotificationPortDestroy(port)
        }
    }

    // MARK: Persistence

    private func loadHistory() {
        guard let context = container?.mainContext else { return }
        let cutoff = Date.now.addingTimeInterval(-Self.retention)
        let descriptor = FetchDescriptor<PowerSample>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        history = (try? context.fetch(descriptor))?.map(\.point) ?? []
        prune(now: .now)
    }

    /// Every stored PD event, for export (the in-memory list keeps only the latest 300).
    func allEvents() -> [PDEvent] {
        guard let context = container?.mainContext else { return events }
        return (try? context.fetch(FetchDescriptor<PDEvent>(sortBy: [SortDescriptor(\.firstDate)]))) ?? events
    }

    private func loadEvents() {
        guard let context = container?.mainContext else { return }
        var descriptor = FetchDescriptor<PDEvent>(sortBy: [SortDescriptor(\.lastDate, order: .reverse)])
        descriptor.fetchLimit = 300
        events = (try? context.fetch(descriptor)) ?? []
    }

    private func prune(now: Date) {
        lastPruneDate = now
        let cutoff = now.addingTimeInterval(-Self.retention)
        history.removeAll { $0.date < cutoff }
        events.removeAll { $0.lastDate < cutoff }
        guard let context = container?.mainContext else { return }
        try? context.delete(model: PowerSample.self, where: #Predicate { $0.timestamp < cutoff })
        try? context.delete(model: PDEvent.self, where: #Predicate { $0.lastDate < cutoff })
        try? context.save()
    }

    func points(since start: Date) -> ArraySlice<HistoryPoint> {
        let index = history.partitioningIndex { $0.date >= start }
        return history[index...]
    }
}

/// C callback for IOServiceAddInterestNotification; delivered on the main queue.
private nonisolated func batteryInterestCallback(refcon: UnsafeMutableRawPointer?, service: io_service_t,
                                                 messageType: UInt32, argument: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    // Pass the address as an integer: a raw pointer is not Sendable.
    let address = UInt(bitPattern: refcon)
    MainActor.assumeIsolated {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<BatteryMonitor>.fromOpaque(pointer).takeUnretainedValue().tick()
    }
}

private extension Array {
    /// Binary search for the first index whose element satisfies a monotonic predicate.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if belongs(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
