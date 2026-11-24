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

    @ObservationIgnored private let container: ModelContainer?
    @ObservationIgnored private var window: [BatterySnapshot] = []
    @ObservationIgnored private var windowStart = Date.now
    @ObservationIgnored private var lastPruneDate = Date.distantPast
    @ObservationIgnored private var lastReadDate = Date.distantPast
    @ObservationIgnored private var previousPorts: [Int: PDPortState] = [:]
    @ObservationIgnored private var previousElected: ElectedSource?
    @ObservationIgnored private var previousContract: PDContract?
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
        defer {
            previousPorts = Dictionary(uniqueKeysWithValues: s.pd.ports.map { ($0.index, $0) })
            previousElected = s.pd.electedPD
            previousContract = s.pd.contract
        }
        guard trackingStarted else {
            trackingStarted = true
            let contract = s.pd.contract
            log(.started, port: s.pd.activePort?.index ?? -1, count: 1,
                detail: contract.map { "Current contract \(describe($0))" } ?? "No PD contract",
                contract: contract, at: s.date)
            return
        }

        // The contract in use (power manager selection + RDO), compared as a whole.
        let activeIndex = s.pd.activePort?.index ?? -1
        switch (previousContract, s.pd.contract) {
        case (nil, let new?):
            log(.established, port: activeIndex, count: 1, detail: describe(new), contract: new, at: s.date)
        case (_?, nil):
            log(.lost, port: activeIndex, count: 1, detail: "No PD profile in use", contract: nil, at: s.date)
        case (let old?, let new?) where old.voltage != new.voltage || old.pdo != new.pdo:
            log(.changed, port: activeIndex, count: 1, detail: "\(describe(old)) → \(describe(new))", contract: new, at: s.date)
        default:
            break
        }

        let contract = s.pd.contract
        for port in s.pd.ports {
            guard let previous = previousPorts[port.index] else { continue }
            let now = port.counters, before = previous.counters
            func delta(_ key: KeyPath<PDCounters, Int>) -> Int { max(0, now[keyPath: key] - before[keyPath: key]) }

            let attaches = delta(\.attach)
            if attaches > 0 {
                log(.reconnected, port: port.index, count: attaches,
                    detail: "Source detached and re-attached", contract: contract, at: s.date)
            }
            let renegotiations = delta(\.sourceCapabilities) - attaches
            if renegotiations > 0 {
                log(.renegotiated, port: port.index, count: renegotiations,
                    detail: "New Source_Capabilities without a reconnect", contract: contract, at: s.date)
            }
            let resets = delta(\.hardResets)
            if resets > 0 {
                log(.hardReset, port: port.index, count: resets, detail: "PD hard reset", contract: contract, at: s.date)
            }
            let rejects = delta(\.requestRejects) + delta(\.psReadyRejects)
            if rejects > 0 {
                log(.rejected, port: port.index, count: rejects, detail: "Source rejected a request", contract: contract, at: s.date)
            }
        }

        if let old = previousElected, let new = s.pd.electedPD,
           old.path != new.path || old.voltage != new.voltage || old.power != new.power {
            log(.sourceSwitched, port: new.portNumber ?? -1, count: 1,
                detail: "\(old.path) \(old.power / 1000) W → \(new.path) \(new.power / 1000) W",
                voltage: new.voltage, current: new.current, at: s.date)
        }
    }

    private func describe(_ c: PDContract) -> String {
        let v = Format.number(Double(c.voltage) / 1000, digits: 2, unit: "V")
        let i = c.current.map { Format.number(Double($0) / 1000, digits: 2, unit: "A") }
            ?? c.currentLimit.map { "≤ " + Format.number(Double($0) / 1000, digits: 2, unit: "A") } ?? "—"
        return "\(v) \(i) (PDO \(c.pdo.position), \(c.pdo.kind.rawValue))"
    }

    private func log(_ kind: PDEventKind, port: Int, count: Int, detail: String, contract: PDContract?, at date: Date) {
        log(kind, port: port, count: count, detail: detail, voltage: contract?.voltage, current: contract?.current, at: date)
    }

    /// Folds repeats of the same kind on the same port within 60 s into the latest event.
    private func log(_ kind: PDEventKind, port: Int, count: Int, detail: String, voltage: Int?, current: Int?, at date: Date) {
        if let latest = events.first(where: { $0.kind == kind.rawValue && $0.port == port }),
           date.timeIntervalSince(latest.lastDate) < 60 {
            latest.count += count
            latest.lastDate = date
            latest.detail = detail
            latest.voltage = voltage
            latest.current = current
            events.sort { $0.lastDate > $1.lastDate }
        } else {
            let event = PDEvent(date: date, kind: kind, port: port, count: count, detail: detail, voltage: voltage, current: current)
            events.insert(event, at: 0)
            container?.mainContext.insert(event)
            if events.count > 300 { events.removeLast(events.count - 300) }
        }
        try? container?.mainContext.save()
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
