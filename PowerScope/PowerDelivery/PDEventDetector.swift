import Foundation

/// A PD link event found by comparing two consecutive readings.
struct DetectedPDEvent: Equatable {
    let kind: PDEventKind
    let port: Int
    let count: Int
    let detail: String
    let voltage: Int?   // mV
    let current: Int?   // mA
}

/// What the detector remembers between readings.
struct PDTrackingState {
    var ports: [Int: PDPortState] = [:]
    var elected: ElectedSource?
    var contract: PDContract?

    init(ports: [Int: PDPortState] = [:], elected: ElectedSource? = nil, contract: PDContract? = nil) {
        self.ports = ports
        self.elected = elected
        self.contract = contract
    }

    init(_ pd: PDState) {
        self.init(ports: Dictionary(uniqueKeysWithValues: pd.ports.map { ($0.index, $0) }),
                  elected: pd.electedPD, contract: pd.contract)
    }
}

/// Turns changes between two readings into PD events. Pure, so it can be tested with
/// captured counter values.
///
/// The port controller's counters keep counting between readings, so their deltas reveal
/// every reconnect and renegotiation even when they happen faster than the polling rate.
enum PDEventDetector {
    /// Repeats of the same kind on the same port within this window fold into one event.
    static let foldWindow: TimeInterval = 60

    static func started(_ pd: PDState) -> DetectedPDEvent {
        let contract = pd.contract
        return DetectedPDEvent(kind: .started, port: pd.activePort?.index ?? -1, count: 1,
                               detail: contract.map { "Current contract \(describe($0))" } ?? "No PD contract",
                               voltage: contract?.voltage, current: contract?.current)
    }

    static func detect(previous: PDTrackingState, current: PDTrackingState, activePort: Int) -> [DetectedPDEvent] {
        var events: [DetectedPDEvent] = []
        let contract = current.contract
        func event(_ kind: PDEventKind, port: Int, count: Int, _ detail: String) {
            events.append(DetectedPDEvent(kind: kind, port: port, count: count, detail: detail,
                                          voltage: contract?.voltage, current: contract?.current))
        }

        // The contract in use, compared by voltage and PDO. The operating current is left
        // out because it appears and disappears as the RDO catches up.
        switch (previous.contract, contract) {
        case (nil, let new?):
            event(.established, port: activePort, count: 1, describe(new))
        case (_?, nil):
            event(.lost, port: activePort, count: 1, "No PD profile in use")
        case (let old?, let new?) where old.voltage != new.voltage || old.pdo != new.pdo:
            event(.changed, port: activePort, count: 1, "\(describe(old)) → \(describe(new))")
        default:
            break
        }

        for (index, port) in current.ports.sorted(by: { $0.key < $1.key }) {
            guard let before = previous.ports[index]?.counters else { continue }
            let now = port.counters
            // Counters reset with the controller; a negative delta is not an event.
            func delta(_ key: KeyPath<PDCounters, Int>) -> Int { max(0, now[keyPath: key] - before[keyPath: key]) }

            let attaches = delta(\.attach)
            if attaches > 0 { event(.reconnected, port: index, count: attaches, "Source detached and re-attached") }
            let renegotiations = delta(\.sourceCapabilities) - attaches
            if renegotiations > 0 {
                event(.renegotiated, port: index, count: renegotiations, "New Source_Capabilities without a reconnect")
            }
            let resets = delta(\.hardResets)
            if resets > 0 { event(.hardReset, port: index, count: resets, "PD hard reset") }
            let rejects = delta(\.requestRejects) + delta(\.psReadyRejects)
            if rejects > 0 { event(.rejected, port: index, count: rejects, "Source rejected a request") }
        }

        if let old = previous.elected, let new = current.elected,
           old.path != new.path || old.voltage != new.voltage || old.power != new.power {
            events.append(DetectedPDEvent(
                kind: .sourceSwitched, port: new.portNumber ?? -1, count: 1,
                detail: "\(old.path) \(old.power / 1000) W → \(new.path) \(new.power / 1000) W",
                voltage: new.voltage, current: new.current))
        }
        return events
    }

    /// Whether a new event should be added to the latest event of the same kind and port.
    static func shouldFold(_ event: DetectedPDEvent, at date: Date,
                           intoKind kind: String, port: Int, lastDate: Date) -> Bool {
        kind == event.kind.rawValue && port == event.port
            && date.timeIntervalSince(lastDate) >= 0 && date.timeIntervalSince(lastDate) < foldWindow
    }

    static func describe(_ c: PDContract) -> String {
        let v = Format.number(Double(c.voltage) / 1000, digits: 2, unit: "V")
        let i = c.current.map { Format.number(Double($0) / 1000, digits: 2, unit: "A") }
            ?? c.currentLimit.map { "≤ " + Format.number(Double($0) / 1000, digits: 2, unit: "A") } ?? "—"
        return "\(v) \(i) (PDO \(c.pdo.position), \(c.pdo.kind.rawValue))"
    }
}
