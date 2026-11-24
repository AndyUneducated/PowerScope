import Foundation
import Testing
@testable import PowerScope

@Suite("PD event detection")
struct PDEventDetectorTests {
    private func port(_ index: Int, attach: Int = 0, srcCaps: Int = 0, resets: Int = 0, rejects: Int = 0) -> PDPortState {
        let pdos = PDState.decodePDOs(Captured.caps94W, sprCount: 4)
        return PDPortState(index: index, pdos: pdos, rawRDO: Captured.rdo94W,
                           rdoContract: PDContract.decode(rdo: Captured.rdo94W, pdos: pdos),
                           maxPower: 94_000, loserReason: nil, firmware: nil,
                           counters: PDCounters(attach: attach, detach: attach, hardResets: resets,
                                                sourceCapabilities: srcCaps, requestRejects: rejects))
    }

    private func state(_ ports: [PDPortState], contract: PDContract? = nil) -> PDTrackingState {
        PDTrackingState(ports: Dictionary(uniqueKeysWithValues: ports.map { ($0.index, $0) }), contract: contract)
    }

    private var contract20V: PDContract { port(0).rdoContract! }

    /// The failing cable between two readings (values from the captured counters):
    /// one re-attach, two Source_Capabilities (one belongs to the re-attach), one hard reset.
    @Test func countersBecomeEvents() {
        let before = state([port(0, attach: 4699, srcCaps: 4772, resets: 24)], contract: contract20V)
        let after = state([port(0, attach: 4700, srcCaps: 4774, resets: 25)], contract: contract20V)
        let events = PDEventDetector.detect(previous: before, current: after, activePort: 0)
        #expect(events.map(\.kind) == [.reconnected, .renegotiated, .hardReset])
        #expect(events.map(\.count) == [1, 1, 1])
        #expect(events.allSatisfy { $0.voltage == 20000 })
    }

    @Test func steadyLinkProducesNothing() {
        let s = state([port(0, attach: 10, srcCaps: 12)], contract: contract20V)
        #expect(PDEventDetector.detect(previous: s, current: s, activePort: 0).isEmpty)
    }

    /// Counters restart when the port controller resets; that is not a burst of events.
    @Test func counterResetIsIgnored() {
        let before = state([port(0, attach: 5000, srcCaps: 5100, resets: 30)])
        let after = state([port(0, attach: 2, srcCaps: 3, resets: 0)])
        #expect(PDEventDetector.detect(previous: before, current: after, activePort: 0).isEmpty)
    }

    @Test func newPortIsBaselineNotEvent() {
        let before = state([])
        let after = state([port(1, attach: 1051, srcCaps: 1055)])
        #expect(PDEventDetector.detect(previous: before, current: after, activePort: 1).isEmpty)
    }

    @Test func contractTransitions() throws {
        let pdos = PDState.decodePDOs(Captured.caps140W, sprCount: 4)
        let epr = PDContract(pdo: try #require(pdos.first { $0.position == 8 }), rdo: nil, basis: .powerManager)
        let p = port(0)

        let established = PDEventDetector.detect(previous: state([p]), current: state([p], contract: contract20V), activePort: 0)
        #expect(established.map(\.kind) == [.established])

        let changed = PDEventDetector.detect(previous: state([p], contract: contract20V), current: state([p], contract: epr), activePort: 0)
        #expect(changed.map(\.kind) == [.changed])
        #expect(changed.first?.detail.contains("28.00 V") == true)

        let lost = PDEventDetector.detect(previous: state([p], contract: epr), current: state([p]), activePort: 0)
        #expect(lost.map(\.kind) == [.lost])
    }

    /// The RDO catching up adds an operating current to the same contract: not a change.
    @Test func currentAppearingIsNotAChange() throws {
        let pdos = PDState.decodePDOs(Captured.caps140W, sprCount: 4)
        let pdo8 = try #require(pdos.first { $0.position == 8 })
        let before = PDContract(pdo: pdo8, rdo: nil, basis: .powerManager)
        let after = try #require(PDContract.decode(rdo: 0x83C7_59D6, pdos: pdos))
        let p = port(0)
        #expect(PDEventDetector.detect(previous: state([p], contract: before), current: state([p], contract: after), activePort: 0).isEmpty)
    }

    @Test func foldingWindow() {
        let event = DetectedPDEvent(kind: .reconnected, port: 0, count: 1, detail: "", voltage: nil, current: nil)
        let last = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(PDEventDetector.shouldFold(event, at: last.addingTimeInterval(30), intoKind: "reconnected", port: 0, lastDate: last))
        #expect(!PDEventDetector.shouldFold(event, at: last.addingTimeInterval(61), intoKind: "reconnected", port: 0, lastDate: last))
        #expect(!PDEventDetector.shouldFold(event, at: last.addingTimeInterval(5), intoKind: "hardReset", port: 0, lastDate: last))
        #expect(!PDEventDetector.shouldFold(event, at: last.addingTimeInterval(5), intoKind: "reconnected", port: 1, lastDate: last))
    }
}
