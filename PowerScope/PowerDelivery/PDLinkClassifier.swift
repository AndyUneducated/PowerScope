import Foundation

/// Tells a normal plug-in or unplug apart from a flaky link before events are counted.
///
/// Plugging in a charger always walks through an attach, Source_Capabilities, sometimes a
/// rejected first request and a brief contract loss. Those are part of the handshake, not
/// problems. A flaky cable or charger shows the same steps over and over, so:
/// - an isolated re-attach opens a short settling window, and the handshake events inside
///   it fold into one "Charger attached" event that is not counted as an issue;
/// - a second re-attach within `repeatWindow` of the previous one is a problem, and so is
///   everything after it until the link has been quiet for `repeatWindow`;
/// - losing the contract because external power went away is "Charger removed", not a problem.
struct PDLinkClassifier {
    static let settleWindow: TimeInterval = 15
    static let repeatWindow: TimeInterval = 120

    private(set) var lastAttach: Date?
    private(set) var settlingUntil: Date?

    /// Kinds that are expected while a charger is being attached.
    static let handshakeKinds: Set<PDEventKind> = [.reconnected, .renegotiated, .rejected, .hardReset, .lost, .sourceSwitched]

    mutating func classify(_ events: [DetectedPDEvent], at date: Date,
                           externalConnected: Bool, externalJustConnected: Bool) -> [DetectedPDEvent] {
        if externalJustConnected { settlingUntil = date.addingTimeInterval(Self.settleWindow) }

        if events.contains(where: { $0.kind == .reconnected }) {
            if let last = lastAttach, date.timeIntervalSince(last) < Self.repeatWindow {
                settlingUntil = nil   // repeated re-attaches: a flaky link, count everything
            } else if settlingUntil.map({ date >= $0 }) ?? true {
                settlingUntil = date.addingTimeInterval(Self.settleWindow)
            }
            lastAttach = date
        }

        let settling = settlingUntil.map { date < $0 } ?? false
        var result: [DetectedPDEvent] = []
        var handshake: [DetectedPDEvent] = []
        for event in events {
            if event.kind == .lost && !externalConnected {
                result.append(DetectedPDEvent(kind: .unplugged, port: event.port, count: 1,
                                              detail: "External power removed", voltage: nil, current: nil))
            } else if settling && Self.handshakeKinds.contains(event.kind) {
                handshake.append(event)
            } else {
                result.append(event)
            }
        }
        if let first = handshake.first {
            let steps = handshake.map { "\($0.kind.title.lowercased())\($0.count > 1 ? " ×\($0.count)" : "")" }
            result.insert(DetectedPDEvent(kind: .plugIn, port: first.port, count: 1,
                                          detail: "Handshake: " + steps.joined(separator: ", "),
                                          voltage: first.voltage, current: first.current), at: 0)
        }
        return result
    }
}
